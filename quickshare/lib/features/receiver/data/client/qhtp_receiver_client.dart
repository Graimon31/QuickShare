import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/core/storage/disk_space.dart';
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/storage/safe_path.dart';
import 'package:quickshare/core/storage/storage_failure.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/file_digest.dart';
import 'package:quickshare/core/utils/streaming_digest.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';
import 'package:quickshare/features/receiver/data/manifest_guard.dart';
import 'package:quickshare/core/security/path_sanitizer.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_receive_result.dart';

class QhtpProgress {
  final String
      phase; // 'connecting' | 'manifest' | 'transferring' | 'verifying' | 'completed' | 'failed'
  final int itemIndex;
  final int itemCount;
  final String itemId;
  final String itemPath;
  final int itemReceived;
  final int itemSize;
  final int sessionReceived;
  final int sessionTotal;
  final int speedBps;

  const QhtpProgress({
    required this.phase,
    required this.itemIndex,
    required this.itemCount,
    required this.itemId,
    required this.itemPath,
    required this.itemReceived,
    required this.itemSize,
    required this.sessionReceived,
    required this.sessionTotal,
    required this.speedBps,
  });
}

class QhtpReceiverClient {
  final Dio dio;
  final SessionStateStore stateStore;
  CancelToken? _cancelToken;

  /// How long to wait for a file request's response headers.
  ///
  /// `receiveTimeout` is disabled for the download itself so a long, healthy
  /// body is never cut off mid-stream, and the guard on the body is the idle
  /// timeout on its stream. But that one cannot start until the headers have
  /// arrived, so without this the wait for *them* was unbounded: a suspended
  /// sender still lets the OS accept the connection and then answers nothing,
  /// and the receiver waited on it forever.
  ///
  /// Overridable only so tests need not spend a minute proving it.
  final Duration responseHeaderTimeout;

  /// Where to write when the requested directory turns out to be unwritable.
  ///
  /// Injectable because the default asks a plugin, and plugins do not answer
  /// in a background isolate — which is where this download now runs. The
  /// caller resolves the path on the main isolate and hands it over.
  final Future<String> Function() fallbackDirectory;

  /// Says how much room the destination has, before anything is requested.
  ///
  /// Injectable for two reasons. A test wants to say "10 MB free" without a
  /// disk that has 10 MB. And the default asks a platform channel, which
  /// answers on the main isolate only — so the worker that runs a session
  /// is handed a probe that asks the main isolate on its behalf.
  final DiskSpaceProbe diskSpace;

  /// Test seam: wraps every partial-file handle as it is opened, so a test can
  /// make the disk fill up at an exact byte. Null in production.
  @visibleForTesting
  final RandomAccessFile Function(RandomAccessFile real)? debugWrapSink;

  QhtpReceiverClient({
    Dio? dioClient,
    SessionStateStore? store,
    this.responseHeaderTimeout = const Duration(seconds: 20),
    Future<String> Function()? fallbackDirectory,
    DiskSpaceProbe? diskSpace,
    this.debugWrapSink,
  })  : dio = dioClient ?? Dio(),
        stateStore = store ?? SessionStateStore(),
        fallbackDirectory = fallbackDirectory ?? _documentsDirectory,
        diskSpace = diskSpace ?? DiskSpaceProbe.forCurrentPlatform();

  static Future<String> _documentsDirectory() async =>
      (await getApplicationDocumentsDirectory()).path;

  /// How often a transfer in flight is allowed to report itself.
  ///
  /// Ten times a second is more than a progress bar can show and far less
  /// than a chunk-by-chunk report costs: every report crosses into the bloc,
  /// emits a state and rebuilds the screen, and at 64 KB a chunk that was
  /// happening hundreds of times a second on the device least able to afford
  /// it.
  static const Duration _progressInterval = Duration(milliseconds: 100);

  /// How much is gathered before it is handed to the disk as one write.
  ///
  /// Big enough that the write is worth making — the chunks arriving off the
  /// socket are 64 KB or less — and small enough that at most two of them are
  /// ever held in memory, which is what keeps a fast network from buffering a
  /// whole session the storage cannot take.
  static const int _writeBlock = 4 * 1024 * 1024;

  /// How heavily the reported speed is smoothed.
  ///
  /// The raw figure is bytes over the last half-second, and it swings wildly
  /// for reasons that have nothing to do with the link: a flush that catches
  /// the disk busy, a file boundary, the OS scheduling something else. The
  /// number on screen jumped between a third and triple the real rate and was
  /// useless for judging whether anything was wrong. Weighting each new
  /// sample at a quarter keeps it responsive to a genuine change over a
  /// couple of seconds while ignoring the noise.
  static const double _speedSmoothing = 0.25;

  void cancel() {
    _cancelToken?.cancel('Transfer cancelled by user');
  }

  String sanitizeSegment(String segment) {
    return PathSanitizer.sanitizeSegment(segment, defaultName: 'item');
  }

  /// Where an item named [relativePath] goes under [baseDir]: cleaned name by
  /// name, and checked against what is already on disk — a link on the way
  /// ends the session ([UnsafePathException]) rather than being followed.
  String materializePath(String relativePath, String baseDir) {
    return SafePath.resolve(relativePath, baseDir, defaultName: 'item');
  }

  /// Uses the directory the caller asked for, when it can actually be
  /// written to.
  ///
  /// This used to ignore [requested] outright on iOS and always write into
  /// Documents, guarding against an older caller passing a `~/Downloads` path
  /// that the sandbox forbids. It also silently overrode every caller with
  /// somewhere better in mind: transfers are staged in the app cache now, and
  /// a Wi-Fi transfer on a phone landed in Documents regardless — so it never
  /// reached the gallery, was never asked about, and was never cleaned up.
  /// The bug was invisible to any test that did not run on a real device,
  /// because `Platform.isIOS` is false everywhere else.
  ///
  /// The guard is kept, as a check rather than an assumption: a path outside
  /// the sandbox fails here instead of part-way through a transfer.
  Future<String> _resolveTargetDir(String requested) async {
    try {
      final dir = Directory(requested);
      if (!await dir.exists()) await dir.create(recursive: true);

      // Proven, not assumed. Creating a directory can succeed where writing
      // into it does not. The scratch file is made exclusively and under a
      // name no one can have prepared, so a link left in the user's folder
      // cannot turn the probe into a write somewhere else.
      SafePath.probeWritable(dir.path);

      return dir.path;
    } on FileSystemException catch (e) {
      final fallback = await fallbackDirectory();
      debugPrint('QHTP: $requested is not writable ($e); '
          'falling back to $fallback');
      return fallback;
    }
  }

  /// What to show for a finished session.
  ///
  /// [placedPaths] is what the session actually wrote, top level only, and
  /// only matters when [targetBaseDir] is a folder that was already the
  /// user's: names here come from the manifest, but a file whose name was
  /// taken lands under a different one, so the caller's own record of where
  /// each item ended up is the only accurate answer.
  QhtpReceiveResult deriveReceiveResult(
    QhtpManifest manifest,
    String targetBaseDir, {
    Iterable<String> placedPaths = const [],
  }) {
    final topLevelNames = <String>{};

    for (final item in manifest.items) {
      final segments = item.path.split('/').where(
          (segment) => segment.isNotEmpty && segment != '.' && segment != '..');
      final root = segments.isEmpty ? null : sanitizeSegment(segments.first);
      if (root != null) {
        topLevelNames.add(root);
      }
    }

    final placed = placedPaths.toList(growable: false);
    final sortedTopLevelNames = topLevelNames.toList()..sort();
    if (sortedTopLevelNames.length == 1) {
      final rootName = sortedTopLevelNames.single;
      return QhtpReceiveResult(
        preferredResultPath: placed.length == 1
            ? placed.single
            : p.join(targetBaseDir, rootName),
        displayName: placed.length == 1 ? p.basename(placed.single) : rootName,
        placedPaths: placed,
      );
    }

    return QhtpReceiveResult(
      preferredResultPath: targetBaseDir,
      displayName: sortedTopLevelNames.isEmpty
          ? 'Received files'
          : '${sortedTopLevelNames.length} items',
      placedPaths: placed,
    );
  }

  /// The top-level entries [finalPaths] created under [baseDir], in the order
  /// they first appear.
  ///
  /// A folder of four hundred photos is one entry here, not four hundred:
  /// what the sender chose to send is what the completion screen has a
  /// decision to offer about.
  static List<String> topLevelEntries(
      Iterable<String> finalPaths, String baseDir) {
    final seen = <String>{};
    final entries = <String>[];
    for (final path in finalPaths) {
      final relative = p.relative(path, from: baseDir);
      final first = p.split(relative).first;
      if (first.isEmpty || first == '.' || first == '..') continue;
      final absolute = p.join(baseDir, first);
      if (seen.add(absolute)) entries.add(absolute);
    }
    return entries;
  }

  /// The item's SHA-256 from the sender's per-item digest endpoint, or null
  /// when the session carries no digests (over the checksum budget, or a
  /// sender build that predates the endpoint) or the answer never came.
  ///
  /// Null means the caller verifies by byte count — hashing is best-effort
  /// everywhere else in this protocol, and a digest that fails to arrive
  /// must degrade the same way rather than fail an otherwise sound transfer.
  Future<String?> _fetchItemDigest({
    required String host,
    required int port,
    required String token,
    required String itemId,
  }) async {
    try {
      final res = await dio
          .get(
            'https://$host:$port/v2/files/$itemId/digest',
            options: Options(headers: {'Authorization': 'Bearer $token'}),
            cancelToken: _cancelToken,
          )
          // The server holds this answer until the item's hash is ready.
          // Hashing outruns the transfer by an order of magnitude, so the
          // hold is theoretical; the bound exists for a sender whose disk
          // has stalled mid-hash.
          .timeout(const Duration(seconds: 60));
      if (res.statusCode == 200 && res.data is Map) {
        return (res.data as Map)['sha256'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Why a 206 is not the continuation that was asked for, or null when it is.
  ///
  /// `Content-Range: bytes <first>-<last>/<total>` has to begin at [from] and
  /// name a file of [total] bytes. Missing, unreadable, starting elsewhere or
  /// describing another length: all the same answer — not appended.
  static String? _contentRangeMismatch(String? header,
      {required int from, required int total}) {
    if (header == null || header.trim().isEmpty) {
      return 'no Content-Range';
    }
    final match =
        RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$').firstMatch(header);
    if (match == null) return 'unreadable Content-Range "$header"';
    final first = int.parse(match.group(1)!);
    if (first != from) return 'Content-Range starts at $first';
    final length = match.group(3)!;
    if (length == '*' || int.parse(length) != total) {
      return 'Content-Range describes a file of $length bytes, not $total';
    }
    return null;
  }

  /// Gives up on a response body that is not going to be read, so the
  /// connection behind it is not held open for the rest of it.
  static void _dropBody(Response<ResponseBody> response) {
    try {
      response.data?.stream.listen(null).cancel();
    } catch (_) {}
  }

  /// Checks a finished `.qs.partial` against the manifest before it is
  /// published under its real name, and returns the digest to record.
  ///
  /// Deletes the partial on any mismatch, so the retry starts from zero rather
  /// than resuming onto bytes already known to be wrong. Throws to signal the
  /// caller's retry loop.
  ///
  /// [streamedSha256] is the digest computed over the bytes as they were
  /// written, which is the ordinary case and costs nothing: the alternative
  /// is reading the whole file back off the disk a second time, immediately
  /// after writing it, before the next file may start. On a session of any
  /// size that halves the throughput the user sees — the transfer stops dead
  /// for the length of a full re-read, once per file — and it buys nothing,
  /// because the same bytes are being hashed either way.
  ///
  /// It is null only when this attempt did not write the whole file: a
  /// resumed download appends to a partial from an earlier run, whose bytes
  /// were never in this process's hands. Then, and only then, the file is
  /// read back.
  Future<String?> _verifyPartial({
    required File partial,
    required QhtpItem item,
    String? expectedSha256,
    String? streamedSha256,
  }) async {
    final writtenBytes = await partial.length();
    // Every item has a size, an empty file's being 0: a partial of any other
    // length is not that file, and with no digest the length is all there is.
    if (writtenBytes != item.size) {
      await partial.delete();
      throw Exception(
          'size mismatch for ${item.path}: received $writtenBytes bytes, '
          'manifest declares ${item.size}');
    }

    final expected = expectedSha256;
    // The read-back, when there is one, happens on a worker: a resumed
    // multi-gigabyte file is a minute of hashing that must not freeze the
    // isolate that also answers Cancel.
    final actual = streamedSha256 ??
        await FileDigest.sha256Of(partial.path,
            cancelled: _cancelToken?.whenCancel);

    if (expected != null && expected.isNotEmpty && actual != expected) {
      await partial.delete();
      throw Exception('checksum mismatch for ${item.path}: '
          'expected $expected, computed $actual');
    }
    return actual;
  }

  /// What the file recorded for an item looks like on disk now.
  ///
  /// The resume state is a claim made by an earlier run. This is the check
  /// that turns it into a fact, and it errs toward receiving again: the cost
  /// of a needless transfer is time, the cost of a wrongly trusted file is a
  /// "received" file that is missing or is not what the sender sent.
  Future<({_Recorded verdict, String? sha256})> _checkRecordedFile({
    required QhtpItem item,
    required QhtpItemState recorded,
    required String base,
    required String host,
    required int port,
    required String token,
    required bool adoptingUnrecorded,
  }) async {
    final path = recorded.finalPath;
    if (path == null) return (verdict: _Recorded.gone, sha256: null);

    try {
      SafePath.assertNoLinksBelow(base, path);
    } on UnsafePathException catch (e) {
      AppLogger.warning('Recorded file ${item.path} is not trusted: $e',
          tag: 'QHTP');
      return (verdict: _Recorded.blocked, sha256: null);
    }
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      case FileSystemEntityType.notFound:
        return (verdict: _Recorded.gone, sha256: null);
      case FileSystemEntityType.file:
        break;
      default:
        // A link, a folder, anything but a regular file: not ours, and not
        // to be touched.
        return (verdict: _Recorded.blocked, sha256: null);
    }

    final stat = File(path).statSync();
    if (stat.size != item.size) {
      return (verdict: _Recorded.differs, sha256: null);
    }

    // The sender's own digest outranks the one this receiver stored: it is
    // what the file is supposed to be, not what an earlier run saw.
    var expected = item.sha256;
    if (expected == null || expected.isEmpty) expected = recorded.sha256;
    if (expected == null || expected.isEmpty) {
      expected = await _fetchItemDigest(
          host: host, port: port, token: token, itemId: item.id);
    }

    if (expected == null || expected.isEmpty) {
      // Nothing to compare the bytes with. A file that is still the size the
      // manifest says and still has the modification time it was given when
      // it was recorded is the best evidence left, and it is only evidence:
      // say so in the log instead of calling it verified.
      final recordedTime = recorded.modifiedMs;
      if (adoptingUnrecorded ||
          recordedTime == null ||
          stat.modified.millisecondsSinceEpoch != recordedTime) {
        return (verdict: _Recorded.differs, sha256: null);
      }
      AppLogger.warning(
          'Keeping ${item.path} unverified: no digest anywhere, but its size '
          'and modification time are unchanged since it was received',
          tag: 'QHTP');
      return (verdict: _Recorded.intact, sha256: null);
    }

    try {
      final actual =
          await FileDigest.sha256Of(path, cancelled: _cancelToken?.whenCancel);
      return actual == expected
          ? (verdict: _Recorded.intact, sha256: actual)
          : (verdict: _Recorded.differs, sha256: null);
    } on FileSystemException {
      return (verdict: _Recorded.differs, sha256: null);
    }
  }

  /// Settles what the state file says about every item before any byte is
  /// counted or skipped, and writes the corrections back into [state].
  ///
  ///  * An item recorded complete that is intact stays complete.
  ///  * One that is gone goes back to pending and keeps its pinned name — the
  ///    name is free again, and a user who deleted a file gets it back where
  ///    it was.
  ///  * One that is there but different (another size, another content), or is
  ///    not a regular file, or is reached through a link, goes back to
  ///    pending with no name pinned. It is never deleted or overwritten: it
  ///    may be the user's own edit. The sender's file arrives beside it.
  ///  * One recorded as still in flight whose pinned file is already whole
  ///    (a crash between the rename and the state save) is adopted rather
  ///    than received a second time as `name (1)` — but only when a digest
  ///    proves it; otherwise the safe duplicate stays.
  ///
  /// Returns whether [state] changed.
  Future<bool> _reverifyRecordedItems({
    required QhtpManifest manifest,
    required Map<String, QhtpItemState> state,
    required String base,
    required String host,
    required int port,
    required String token,
    void Function(QhtpProgress progress)? onProgress,
  }) async {
    var changed = false;
    var announced = false;

    for (final item in manifest.items) {
      if (_cancelToken?.isCancelled ?? false) return changed;
      final recorded = state[item.id];
      if (recorded == null) continue;

      // A record under this id for some other file is nobody's record.
      if (recorded.path != item.path || recorded.size != item.size) {
        state.remove(item.id);
        changed = true;
        continue;
      }

      // Nor is one that points outside the destination: a record is a file on
      // disk the user can edit, and nothing it says is a reason to touch, or
      // trust, a path that is not under the folder this session writes to.
      final pinned = recorded.finalPath;
      if (pinned != null && !p.isWithin(base, pinned)) {
        AppLogger.warning(
            'Ignoring a saved name for ${item.path} that is outside the '
            'destination',
            tag: 'QHTP');
        state[item.id] = QhtpItemState(
            id: item.id, path: item.path, size: item.size, status: 'pending');
        changed = true;
        continue;
      }

      final completed = recorded.status == 'completed';
      if (!completed) {
        // Only a pinned name that is already a regular file of the right size
        // is worth a look; everything else resumes or restarts as before.
        if (pinned == null ||
            FileSystemEntity.typeSync(pinned, followLinks: false) !=
                FileSystemEntityType.file ||
            File(pinned).lengthSync() != item.size) {
          continue;
        }
      }

      if (!announced) {
        announced = true;
        // Hashing finished files is a phase of its own: it can take a while,
        // and a screen frozen on "connecting" while it does is a hang.
        onProgress?.call(QhtpProgress(
          phase: 'verifying',
          itemIndex: manifest.itemCount,
          itemCount: manifest.itemCount,
          itemId: '',
          itemPath: '',
          itemReceived: 0,
          itemSize: 0,
          sessionReceived: 0,
          sessionTotal: manifest.totalBytes,
          speedBps: 0,
        ));
      }

      final checked = await _checkRecordedFile(
        item: item,
        recorded: recorded,
        base: base,
        host: host,
        port: port,
        token: token,
        adoptingUnrecorded: !completed,
      );
      final verdict = checked.verdict;
      if (_cancelToken?.isCancelled ?? false) return changed;

      if (completed) {
        switch (verdict) {
          case _Recorded.intact:
            break;
          case _Recorded.gone:
            AppLogger.warning(
                '${item.path} was recorded as received but is no longer '
                'there; receiving it again',
                tag: 'QHTP');
            state[item.id] = QhtpItemState(
                id: item.id,
                path: item.path,
                size: item.size,
                status: 'pending',
                finalPath: recorded.finalPath);
            changed = true;
          case _Recorded.differs:
          case _Recorded.blocked:
            AppLogger.warning(
                '${item.path} was recorded as received but what is on disk '
                'is not that file; receiving it again beside it',
                tag: 'QHTP');
            state[item.id] = QhtpItemState(
                id: item.id,
                path: item.path,
                size: item.size,
                status: 'pending');
            changed = true;
        }
      } else if (verdict == _Recorded.intact) {
        final path = recorded.finalPath!;
        AppLogger.info(
            '${item.path} was already whole under its pinned name; '
            'adopting it instead of receiving it twice',
            tag: 'QHTP');
        state[item.id] = recorded.copyWith(
          status: 'completed',
          partialBytes: item.size,
          sha256: checked.sha256,
          modifiedMs: File(path).statSync().modified.millisecondsSinceEpoch,
        );
        changed = true;
      }
    }
    return changed;
  }

  /// What, of what is still to come, the disk has to hold.
  ///
  /// Finished items cost nothing, and bytes already in a resumable partial are
  /// already on the disk — counting either again would turn a nearly complete
  /// resume away for want of room it has already used.
  int _bytesStillToReceive(
    QhtpManifest manifest,
    Map<String, QhtpItemState> state,
    String base,
  ) {
    var remaining = 0;
    for (final item in manifest.items) {
      final recorded = state[item.id];
      if (recorded?.status == 'completed') continue;
      var onDisk = 0;
      try {
        // Lexical on purpose: this runs once per item, up front, and only
        // needs to find a partial that is already there — one `lstat` each.
        final planned = recorded?.finalPath ??
            PathSanitizer.resolveSafePath(item.path, base, defaultName: 'item');
        final partial = '$planned$kPartialSuffix';
        if (FileSystemEntity.typeSync(partial, followLinks: false) ==
            FileSystemEntityType.file) {
          onDisk = File(partial).lengthSync();
        }
      } catch (_) {
        // A path that cannot be planned is refused for real when its turn
        // comes; here it just reuses nothing.
      }
      // Oversized partials are discarded when the item starts, so none of
      // their bytes can be reused by this download.
      remaining += item.size - (onDisk > item.size ? 0 : onDisk);
    }
    return remaining;
  }

  /// Every item the session says it delivered, looked at once more.
  ///
  /// Cheap on purpose — a file type and a length, no hashing: each item was
  /// verified when it landed or when this run began. What this catches is the
  /// file that went missing, or was swapped, in between: reporting "complete"
  /// to the sender and the user over a hole is the one outcome worse than an
  /// error. Returns the paths of the items that no longer stand.
  List<String> _itemsNoLongerWhole(
    QhtpManifest manifest,
    Map<String, QhtpItemState> state,
    String base,
  ) {
    final missing = <String>[];
    // A folder is checked once however many files it holds.
    final folderIsSafe = <String, bool>{};
    for (final item in manifest.items) {
      final path = state[item.id]?.finalPath;
      var whole = false;
      if (path != null) {
        try {
          final safe = folderIsSafe.putIfAbsent(p.dirname(path), () {
            try {
              SafePath.assertNoLinksBelow(base, path);
              return true;
            } on UnsafePathException {
              return false;
            }
          });
          whole = safe &&
              FileSystemEntity.typeSync(path, followLinks: false) ==
                  FileSystemEntityType.file &&
              File(path).lengthSync() == item.size;
        } catch (_) {
          whole = false;
        }
      }
      if (!whole) missing.add(item.path);
    }
    return missing;
  }

  Future<Either<Failure, QhtpReceiveResult>> downloadSession({
    required QRPayload payload,
    required String targetBaseDir,
    void Function(QhtpProgress progress)? onProgress,
  }) async {
    _cancelToken = CancelToken();

    try {
      final host = payload.ip;
      final port = payload.port;
      final token = payload.token;

      // HTTPS with a per-session self-signed certificate, pinned to the
      // fingerprint the QR carried. No fingerprint means the QR is from a
      // build that served the file in the clear — refused rather than
      // silently downgraded.
      final fingerprint = payload.tlsFingerprint;
      if (fingerprint.isEmpty) {
        return const Left(NetworkFailure(
            'This code is from an older version that sends files unencrypted. '
            'Update the sending device.'));
      }
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client =
              HttpClient(context: SecurityContext(withTrustedRoots: false));
          client.badCertificateCallback =
              (cert, h, p) => SessionTlsIdentity.matches(cert, fingerprint);
          return client;
        },
      );
      final sessionId = payload.sessionId ??
          'session_${DateTime.now().millisecondsSinceEpoch}';

      onProgress?.call(const QhtpProgress(
        phase: 'connecting',
        itemIndex: 0,
        itemCount: 0,
        itemId: '',
        itemPath: '',
        itemReceived: 0,
        itemSize: 0,
        sessionReceived: 0,
        sessionTotal: 0,
        speedBps: 0,
      ));

      // Longer connect timeout: iOS may show the Local Network permission
      // dialog on the first LAN request and block until the user answers.
      final options = Options(
        headers: {'Authorization': 'Bearer $token'},
        connectTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
      );

      // 1. GET /v2/session
      final sessionRes =
          await dio.get('https://$host:$port/v2/session', options: options);
      if (sessionRes.statusCode != 200) {
        return Left(NetworkFailure(
            'Failed to connect to QHTP session (status ${sessionRes.statusCode})'));
      }

      final sessionData = sessionRes.data as Map<String, dynamic>;
      final totalBytes = sessionData['totalBytes'] as int? ?? 0;
      final itemCount = sessionData['itemCount'] as int? ?? 0;

      // 2. Preflight Limits & Disk Check
      if (itemCount > AppConstants.qhtpMaxFileCount) {
        return Left(FileFailure(
            'Session file count ($itemCount) exceeds max limit of ${AppConstants.qhtpMaxFileCount}'));
      }
      if (totalBytes > AppConstants.qhtpMaxSessionBytes) {
        return const Left(
            FileFailure('Session size exceeds max limit of 500 GB'));
      }

      final resolvedTargetBaseDir = await _resolveTargetDir(targetBaseDir);

      // 3. GET /v2/manifest
      onProgress?.call(QhtpProgress(
        phase: 'manifest',
        itemIndex: 0,
        itemCount: itemCount,
        itemId: '',
        itemPath: '',
        itemReceived: 0,
        itemSize: 0,
        sessionReceived: 0,
        sessionTotal: totalBytes,
        speedBps: 0,
      ));

      final manifestRes = await dio.get<ResponseBody>(
        'https://$host:$port/v2/manifest',
        // Stream the manifest so a multi-gigabyte hostile response cannot OOM the receiver.
        options: options.copyWith(responseType: ResponseType.stream),
      );
      if (manifestRes.statusCode != 200) {
        return const Left(NetworkFailure('Failed to fetch session manifest'));
      }

      final responseBody = manifestRes.data;
      if (responseBody == null) {
        return const Left(NetworkFailure('Failed to fetch session manifest'));
      }

      final builder = BytesBuilder(copy: false);
      int downloadedBytes = 0;
      const guard = ManifestGuard();
      try {
        await for (final chunk in responseBody.stream) {
          downloadedBytes += chunk.length;
          if (downloadedBytes > AppConstants.qhtpManifestMaxBytes) {
            guard.checkSize(downloadedBytes);
          }
          builder.add(chunk);
        }
      } on ManifestRejected catch (e) {
        return Left(FileFailure(e.message));
      }

      final manifestBytes = builder.takeBytes();
      final QhtpManifest manifest;
      try {
        guard.checkSize(manifestBytes.length);
        final manifestBody = utf8.decode(manifestBytes);
        manifest = QhtpManifest.fromJson(
            jsonDecode(manifestBody) as Map<String, dynamic>);
        // Check actual items against count and size ceilings (DD-21), not just
        // the unverified self-reported session header.
        guard.checkLimits(manifest);
        guard.checkPaths(manifest);
      } on ManifestRejected catch (e) {
        return Left(FileFailure(e.message));
      } on FormatException {
        return const Left(
            NetworkFailure('The session manifest was unreadable.'));
      }

      // Windows will not open a path past MAX_PATH; better to say so before
      // the first byte than to write files Explorer cannot open.
      if (SafePath.enforcesPathLength) {
        for (final item in manifest.items) {
          SafePath.assertPathLength(
              '${PathSanitizer.resolveSafePath(item.path, resolvedTargetBaseDir, defaultName: 'item')}'
              '$kPartialSuffix');
        }
      }

      // Load or initialize state store for resume. A record is only used for
      // the session and destination it was made for.
      final saved = await stateStore.loadSession(sessionId);
      var localState = <String, QhtpItemState>{};
      if (saved != null) {
        if (saved.sessionId != null && saved.sessionId != sessionId) {
          AppLogger.warning(
              'Ignoring a saved record that belongs to another session',
              tag: 'QHTP');
        } else if (saved.baseDir != null &&
            saved.baseDir != resolvedTargetBaseDir) {
          AppLogger.info(
              'Ignoring a saved record made for ${saved.baseDir}; this '
              'session is going to $resolvedTargetBaseDir',
              tag: 'QHTP');
        } else {
          localState = saved.items;
        }
      }

      Future<void> saveRecord() => stateStore.saveState(
            sessionId: sessionId,
            host: host,
            port: port,
            token: token,
            baseDir: resolvedTargetBaseDir,
            items: localState,
          );

      // What the record says is finished is only a claim until the disk
      // agrees. This comes before any byte is counted as received or skipped.
      final corrected = await _reverifyRecordedItems(
        manifest: manifest,
        state: localState,
        base: resolvedTargetBaseDir,
        host: host,
        port: port,
        token: token,
        onProgress: onProgress,
      );
      if (_cancelToken?.isCancelled ?? false) {
        return const Left(FileFailure('Transfer cancelled by user'));
      }
      if (corrected) await saveRecord();

      // Room for what is left, not for what is already here.
      final stillToReceive =
          _bytesStillToReceive(manifest, localState, resolvedTargetBaseDir);
      if (stillToReceive > 0) {
        try {
          await requireFreeSpace(diskSpace, resolvedTargetBaseDir,
              remainingBytes: stillToReceive, tag: 'QHTP');
        } on NotEnoughSpaceException catch (e) {
          return Left(FileFailure(e.message, code: e.failureCode));
        }
      }

      int sessionReceivedBytes = 0;
      for (final item in manifest.items) {
        final state = localState[item.id];
        if (state != null && state.status == 'completed') {
          sessionReceivedBytes += item.size;
        }
      }

      DateTime lastSpeedUpdate = DateTime.now();
      DateTime lastProgressReport = DateTime.now().subtract(_progressInterval);
      int lastBytesReceived = sessionReceivedBytes;
      int currentSpeedBps = 0;

      // 4. Transfer each item in order with per-file 3x retry
      for (int i = 0; i < manifest.items.length; i++) {
        if (_cancelToken?.isCancelled ?? false) {
          return const Left(FileFailure('Transfer cancelled by user'));
        }

        final item = manifest.items[i];
        final itemIndex = i + 1;

        var itemState = localState[item.id] ??
            QhtpItemState(
                id: item.id,
                path: item.path,
                size: item.size,
                status: 'pending');

        if (itemState.status == 'completed') {
          continue;
        }

        // Never write over a file the user already has. A sender that names
        // its file to match one in the destination folder would otherwise
        // replace it silently — the WebRTC receiver already sidesteps this
        // with `name (1).ext`, and this brings the two into line.
        //
        // The resolved name is pinned into the session state as soon as it is
        // chosen, so a resumed transfer continues the same `.qs.partial`
        // rather than picking a fresh name beside the half-written one. If the
        // pinned name has since been taken by something else, the item starts
        // over under a new name rather than deleting whatever is now there.
        String finalPath;
        try {
          var chosen = itemState.finalPath;
          // `exists` here looks without following links: a dangling link is
          // a taken name, not a free one.
          if (chosen == null || SafePath.exists(chosen)) {
            chosen = SafePath.uniquePath(
                materializePath(item.path, resolvedTargetBaseDir));
          } else {
            // A name pinned by an earlier run: it was free then, and the
            // folders above it are checked again now.
            SafePath.assertNoLinksBelow(resolvedTargetBaseDir, chosen);
          }
          finalPath = chosen;
        } on Object catch (e) {
          final problem = classifyStorageError(e);
          if (problem == null) rethrow;
          return Left(FileFailure(problem.message, code: problem.code));
        }
        final partialPath = '$finalPath$kPartialSuffix';

        if (itemState.finalPath != finalPath) {
          itemState = itemState.copyWith(finalPath: finalPath);
          localState[item.id] = itemState;
          await saveRecord();
        }

        // Per-file retry up to 3 attempts
        bool itemSuccess = false;
        Object? itemError;
        final sessionReceivedBeforeItem = sessionReceivedBytes;

        for (int attempt = 1;
            attempt <= AppConstants.maxRetryAttempts;
            attempt++) {
          if (_cancelToken?.isCancelled ?? false) {
            return const Left(FileFailure('Transfer cancelled by user'));
          }

          RandomAccessFile? sink;
          // Hoisted so a failed attempt can still shut the worker down: an
          // isolate left running per retry is a leak that outlives the
          // transfer.
          StreamingDigest? digestWorker;
          try {
            final partialFile = File(partialPath);
            // Looked at without following links; a link standing where the
            // partial goes is removed (never its target) and counts as no
            // partial at all.
            var existingBytes =
                SafePath.partialLength(resolvedTargetBaseDir, partialPath);

            if (existingBytes > item.size) {
              // A previous attempt wrote past the declared end — a 200 answered
              // to a Range request appends a whole second copy. Clamping the
              // counter used to hide that and rename an oversized file as
              // complete; start the item over instead. For an empty file that
              // is any partial at all: bytes beside a file that has none are
              // somebody else's.
              await partialFile.delete();
              existingBytes = 0;
            }

            // A raw handle rather than an `IOSink`.
            //
            // A sink queues everything handed to it and writes when it gets
            // round to it, so a network faster than the disk grows a buffer
            // in memory with nothing to stop it — gigabytes of it on a
            // session this size. Flushing it periodically bounds that, but a
            // sink refuses `add` while a flush is running, so the only shape
            // available was: stop reading, drain to empty, read again. That
            // is stop-and-wait — the disk idle while bytes arrive, the socket
            // idle while the disk catches up — and it is a large part of why
            // the rate sawtoothed instead of settling at what the link could
            // carry. Writing through a handle lets one write be in flight
            // while the next block is still being read.
            //
            // Opened by [SafePath.openPartial]: created exclusively, never
            // through a link, and emptied only after the path has been
            // checked again — a fresh item starts from zero, a resumed one
            // appends.
            final opened = SafePath.openPartial(
              resolvedTargetBaseDir,
              partialPath,
              truncate: existingBytes == 0,
            );
            sink = debugWrapSink?.call(opened) ?? opened;

            int itemReceivedBytes = existingBytes;
            sessionReceivedBytes = sessionReceivedBeforeItem + existingBytes;
            lastBytesReceived = sessionReceivedBytes;
            String? streamedSha256;

            if (existingBytes < item.size) {
              final downloadOptions = Options(
                headers: {
                  'Authorization': 'Bearer $token',
                  if (existingBytes > 0) 'Range': 'bytes=$existingBytes-',
                },
                responseType: ResponseType.stream,
                connectTimeout: const Duration(seconds: 15),
                sendTimeout: const Duration(seconds: 10),
                // dio's own receiveTimeout only covers waiting for the
                // response headers, not a streamed body — a dead bridge
                // keeps the socket open and simply stops sending, and the
                // transfer used to sit on its last percentage forever. The
                // idle timeout on the stream below is the actual guard.
                receiveTimeout: null,
              );

              final fileUrl = 'https://$host:$port/v2/files/${item.id}';
              // Bounded on the headers only — see [responseHeaderTimeout].
              // Without it a suspended sender left this await with no way to
              // end, and the receiver sat on its last screen forever, most
              // visibly "verifying" when the break fell between two files.
              final response = await dio
                  .get<ResponseBody>(
                    fileUrl,
                    options: downloadOptions,
                    cancelToken: _cancelToken,
                  )
                  .timeout(
                    responseHeaderTimeout,
                    onTimeout: () => throw TimeoutException(
                        'The sender did not answer within '
                        '${responseHeaderTimeout.inSeconds}s'),
                  );

              final status = response.statusCode;
              if (existingBytes > 0 && status == 200) {
                // 200 means the server ignored the Range header and is sending
                // from byte zero. Appending that to a partial file silently
                // corrupts it, which is how resumed downloads used to break.
                // So the item starts again: the partial is emptied through the
                // same guarded open that created it (never through a link that
                // has appeared since) and this response — the whole file — is
                // what fills it.
                AppLogger.warning(
                    'The sender ignored the Range request for ${item.path}; '
                    'starting the item again from zero',
                    tag: 'QHTP');
                try {
                  await sink.flush();
                } finally {
                  await sink.close();
                }
                sink = null;
                final reopened = SafePath.openPartial(
                    resolvedTargetBaseDir, partialPath,
                    truncate: true);
                sink = debugWrapSink?.call(reopened) ?? reopened;
                existingBytes = 0;
                itemReceivedBytes = 0;
                sessionReceivedBytes = sessionReceivedBeforeItem;
                lastBytesReceived = sessionReceivedBytes;
              } else if (existingBytes > 0) {
                // The one answer that continues a partial: 206, saying it is
                // the rest of this file, from here. The bytes of anything else
                // are not ours to append — and where the item has no digest,
                // nothing later can tell them apart from the right ones.
                final mismatch = status != 206
                    ? 'status $status'
                    : _contentRangeMismatch(
                        response.headers.value('content-range'),
                        from: existingBytes,
                        total: item.size);
                if (mismatch != null) {
                  _dropBody(response);
                  throw Exception('The sender did not answer the resume '
                      'request for ${item.path} with the rest of the file '
                      'from byte $existingBytes ($mismatch)');
                }
              } else if (status != 200) {
                _dropBody(response);
                throw Exception('Server returned status $status');
              }

              // Thirty seconds without a single chunk is a dead link, not a
              // slow one; the timeout errors the attempt so the retry loop
              // resumes from the partial file instead of hanging forever.
              final stream = response.data!.stream.timeout(
                const Duration(seconds: 30),
              );

              // One write in flight, one buffer filling behind it: the disk
              // and the socket both stay busy, and what is held in memory is
              // bounded at two blocks however fast either of them is.
              final pending = BytesBuilder(copy: false);
              Future<void>? writeInFlight;

              Future<void> handOff() async {
                if (pending.isEmpty) return;
                final block = pending.takeBytes();
                await writeInFlight;
                final future = sink!.writeFrom(block);
                future.ignore();
                writeInFlight = future;
              }

              // Hashed as the bytes go past, rather than by reading the
              // finished file back off the disk — see [_verifyPartial]. On a
              // worker isolate once the file is big enough to be worth one:
              // this loop is already driving TLS and the disk, and Dart's
              // SHA-256 wants a core to itself, so doing it here costs about
              // a third of the throughput.
              final hashedWholeFile = existingBytes == 0;
              final inlineSink =
                  hashedWholeFile && item.size < StreamingDigest.worthAnIsolate
                      ? AccumulatorSink<Digest>()
                      : null;
              final inline = inlineSink == null
                  ? null
                  : sha256.startChunkedConversion(inlineSink);
              final worker = digestWorker =
                  hashedWholeFile && item.size >= StreamingDigest.worthAnIsolate
                      ? await StreamingDigest.start()
                      : null;

              await for (final Uint8List chunk in stream) {
                pending.add(chunk);
                inline?.add(chunk);
                if (worker != null) await worker.add(chunk);
                itemReceivedBytes += chunk.length;
                sessionReceivedBytes += chunk.length;

                // Waiting here — and only here — is what makes the disk push
                // back on the socket: the read loop stops until the previous
                // write is done, the TCP window closes, and the sender slows
                // to the speed the receiver can actually write.
                if (pending.length >= _writeBlock) await handOff();

                final now = DateTime.now();
                final deltaSec =
                    now.difference(lastSpeedUpdate).inMilliseconds / 1000.0;
                if (deltaSec >= 0.5) {
                  final deltaBytes = sessionReceivedBytes - lastBytesReceived;
                  final sample = deltaBytes / deltaSec;
                  currentSpeedBps = currentSpeedBps == 0
                      ? sample.round()
                      : (currentSpeedBps * (1 - _speedSmoothing) +
                              sample * _speedSmoothing)
                          .round();
                  lastSpeedUpdate = now;
                  lastBytesReceived = sessionReceivedBytes;
                }

                // Not once per chunk.
                //
                // A chunk is 64 KB, so at any real speed this fired hundreds
                // of times a second, and each one became a bloc event, a new
                // state and a rebuilt screen on the receiving device. On a
                // phone that is enough to saturate the isolate that also has
                // to run this very loop: the reads fall behind, the sender
                // stalls waiting on a window that never opens, and the taps
                // that would cancel it are queued behind a thousand progress
                // updates. A bar that moves ten times a second looks exactly
                // as smooth and costs a thousandth as much.
                if (now.difference(lastProgressReport) >= _progressInterval) {
                  lastProgressReport = now;
                  onProgress?.call(QhtpProgress(
                    phase: 'transferring',
                    itemIndex: itemIndex,
                    itemCount: manifest.itemCount,
                    itemId: item.id,
                    itemPath: item.path,
                    itemReceived: itemReceivedBytes,
                    itemSize: item.size,
                    sessionReceived: sessionReceivedBytes,
                    sessionTotal: manifest.totalBytes,
                    speedBps: currentSpeedBps,
                  ));
                }
              }

              await handOff();
              await writeInFlight;
              if (inline != null && inlineSink != null) {
                inline.close();
                streamedSha256 = 'sha256:${inlineSink.events.single}';
              } else if (worker != null) {
                streamedSha256 = await worker.finish();
              }
              digestWorker = null;
            }

            await sink.flush();
            await sink.close();
            sink = null;

            // The bytes are on disk; before anything reads them back or
            // renames them, make sure the folder they are in is still the
            // folder they were written to. A path that now goes through a link
            // ends the session — nothing below should even look through it.
            SafePath.assertNoLinksBelow(resolvedTargetBaseDir, partialPath);

            // 5. Verify, then rename. In that order: the old code renamed
            // first and hashed afterwards without comparing to anything, so a
            // truncated or corrupted file was published as complete.
            onProgress?.call(QhtpProgress(
              phase: 'verifying',
              itemIndex: itemIndex,
              itemCount: manifest.itemCount,
              itemId: item.id,
              itemPath: item.path,
              itemReceived: itemReceivedBytes,
              itemSize: item.size,
              sessionReceived: sessionReceivedBytes,
              sessionTotal: manifest.totalBytes,
              speedBps: currentSpeedBps,
            ));

            // The manifest carries the hash inline when the sender indexed
            // with checksums; otherwise it arrives out of band — the
            // sender's manifest no longer waits on hashing, so the digest
            // comes from the per-item endpoint, where it has long been
            // ready: hashing outruns the transfer by an order of magnitude.
            var expectedSha256 = item.sha256;
            if (expectedSha256 == null || expectedSha256.isEmpty) {
              expectedSha256 = await _fetchItemDigest(
                host: host,
                port: port,
                token: token,
                itemId: item.id,
              );
            }
            final checksumStr = await _verifyPartial(
              partial: partialFile,
              item: item,
              expectedSha256: expectedSha256,
              streamedSha256: streamedSha256,
            );

            // Durability parity with the WebRTC and BLE channels: fsync the
            // bytes before the rename, fsync the directory after it, so a
            // power cut leaves either the whole file under its real name or a
            // `.qs.partial` the next run resumes — never a real name over a
            // half-written body.
            final fsyncHandle = await partialFile.open(mode: FileMode.append);
            try {
              await fsyncHandle.flush();
            } finally {
              await fsyncHandle.close();
            }

            // No delete-then-rename, and no plain rename either: `rename`
            // replaces whatever is at the target without a word, and the name
            // was only free when it was chosen — possibly minutes ago. The
            // commit looks at the folder chain once more, then moves the file
            // without replacing; if the name was taken meanwhile it takes the
            // next free `name (n).ext` and tells us which, so the record and
            // the result name the file that is really there.
            final committedPath = SafePath.commitFile(
                resolvedTargetBaseDir, partialPath, finalPath);
            await syncDirectory(p.dirname(committedPath));
            finalPath = committedPath;

            itemState = itemState.copyWith(
              status: 'completed',
              partialBytes: item.size,
              sha256: checksumStr,
              finalPath: finalPath,
              modifiedMs:
                  File(finalPath).statSync().modified.millisecondsSinceEpoch,
            );

            localState[item.id] = itemState;
            await saveRecord();

            itemSuccess = true;
            break; // Success, break retry loop
          } catch (e) {
            itemError = e;
            if (e is DigestCancelled) {
              return const Left(FileFailure('Transfer cancelled by user'));
            }
            // A full disk, a link in the way, a path Windows cannot open:
            // retrying changes nothing, so the first one ends the session.
            // The partial and the record stay where they are — a full disk in
            // particular is the one failure a user can fix and then resume
            // from, and the bytes already written are the point of resuming.
            final problem = classifyStorageError(e);
            if (problem != null) {
              return Left(FileFailure(
                  problem.code == FailureCode.diskFull
                      ? 'Not enough disk space to write ${item.path}: '
                          '${problem.message}'
                      : problem.message,
                  code: problem.code));
            }
            if (attempt < AppConstants.maxRetryAttempts) {
              await Future.delayed(Duration(seconds: attempt));
            }
          } finally {
            // The sink used to be left open on every failed attempt, leaking a
            // handle per retry and — worse — letting buffered bytes land in the
            // file after the next attempt had already measured its length.
            if (sink != null) {
              try {
                await sink.flush();
              } catch (_) {}
              try {
                await sink.close();
              } catch (_) {}
            }
            try {
              await digestWorker?.abort();
            } catch (_) {}
          }
        }

        if (!itemSuccess) {
          return Left(NetworkFailure(
              'Failed to download ${item.path} after ${AppConstants.maxRetryAttempts} retries: $itemError',
              code: _connectionLossCode(itemError)));
        }
      }

      // Every item is looked at once more before anyone is told it arrived.
      // Each was verified when it landed (or when this run began), so this is
      // only a type and a length — but a file that went missing since is a
      // hole in what the user is about to be told is complete.
      final gone =
          _itemsNoLongerWhole(manifest, localState, resolvedTargetBaseDir);
      if (gone.isNotEmpty) {
        AppLogger.error(
            '${gone.length} received item(s) are no longer whole at the end '
            'of the session: ${gone.take(5).join(', ')}',
            tag: 'QHTP');
        // No completion POST: the sender treats any POST as "all delivered",
        // so sending one for a receive with holes in it would be a false
        // success on that side as well. The record is kept; a retry verifies
        // it and fetches only what is missing.
        return Left(FileFailure(
            '${gone.length} received file(s) are missing or changed since '
            'they were saved (${gone.take(3).join(', ')}'
            '${gone.length > 3 ? ', …' : ''})',
            code: FailureCode.receivedFilesNotIntact));
      }
      final deliveredBytes =
          manifest.items.fold<int>(0, (sum, item) => sum + item.size);

      // 6. Signal completion to the sender. This POST is the sender's only
      // authoritative completion signal, so best-effort is not enough: a POST
      // lost to a tearing-down bridge used to leave the sender sitting on
      // 99% until the session timed out, with the receiver looking finished.
      // The counts are what was checked above, not constants.
      Object? completeError;
      for (var attempt = 1;
          attempt <= AppConstants.maxRetryAttempts;
          attempt++) {
        try {
          await dio.post(
            'https://$host:$port/v2/session/complete',
            data: {
              'sessionId': sessionId,
              'receivedItems': manifest.items.length - gone.length,
              'receivedBytes': deliveredBytes,
              'failedItems': gone.length,
            },
            options: options,
          );
          completeError = null;
          break;
        } catch (e) {
          completeError = e;
          if (attempt < AppConstants.maxRetryAttempts) {
            await Future.delayed(Duration(seconds: attempt));
          }
        }
      }
      if (completeError != null) {
        // The files are complete on disk; only the sender's bookkeeping is
        // missing. Log it rather than failing a receive that succeeded.
        debugPrint('Completion signal never reached the sender: '
            '$completeError');
      }

      await stateStore.deleteState(sessionId);

      onProgress?.call(QhtpProgress(
        phase: 'completed',
        itemIndex: manifest.itemCount,
        itemCount: manifest.itemCount,
        itemId: '',
        itemPath: '',
        itemReceived: 0,
        itemSize: 0,
        sessionReceived: manifest.totalBytes,
        sessionTotal: manifest.totalBytes,
        speedBps: 0,
      ));

      // Read off what each item was actually written as, not off the
      // manifest: a name already taken in the destination lands under
      // another one, and a destination that is the user's own folder is
      // full of files this session did not put there.
      return Right(deriveReceiveResult(
        manifest,
        resolvedTargetBaseDir,
        placedPaths: topLevelEntries(
          [
            for (final item in manifest.items)
              if (localState[item.id]?.finalPath case final path?) path,
          ],
          resolvedTargetBaseDir,
        ),
      ));
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        return const Left(FileFailure('Transfer cancelled'));
      }
      final storage = classifyStorageError(e);
      if (storage != null) {
        AppLogger.error('QHTP receive stopped: ${storage.message}',
            tag: 'QHTP');
        return Left(FileFailure(storage.message, code: storage.code));
      }
      debugPrint('QHTP Client download error: $e');
      final isTimeout = e is DioException &&
          (e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout ||
              e.type == DioExceptionType.connectionError);
      final msg = isTimeout
          ? 'Cannot reach sender (${payload.ip}:${payload.port}). Make sure both your iPhone and Mac are connected to the SAME Wi-Fi network (and not using LTE).'
          : 'QHTP download failed: ${e.toString()}';
      return Left(NetworkFailure(msg,
          code: isTimeout ? FailureCode.senderUnreachable : null));
    }
  }

  /// Whether [error] is the shape a dead link takes on a plain HTTP pull —
  /// worth naming for the user as "the sender is gone" rather than repeating
  /// verbatim, whatever the exact wording underneath happens to be.
  ///
  /// This cannot tell a deliberate cancel from a crash or a radio going out
  /// of range — a one-way GET carries no signal that would say which — so it
  /// does not try to. All three end a connection the same way, and the name
  /// is honest about all three.
  String? _connectionLossCode(Object? error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return FailureCode.senderUnreachable;
        default:
          return null;
      }
    }
    if (error is SocketException || error is TimeoutException) {
      return FailureCode.senderUnreachable;
    }
    return null;
  }
}

/// What a recorded file turned out to be.
enum _Recorded {
  /// There, regular, the right size, and (where it can be told) the right
  /// bytes.
  intact,

  /// Not there. Its name is free.
  gone,

  /// There, but not the file the sender described.
  differs,

  /// There, but not something to touch: a link, a folder, a path through a
  /// link.
  blocked,
}

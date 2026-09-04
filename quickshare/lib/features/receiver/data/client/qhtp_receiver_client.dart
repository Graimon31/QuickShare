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
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/utils/streaming_digest.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';
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

  QhtpReceiverClient({
    Dio? dioClient,
    SessionStateStore? store,
    this.responseHeaderTimeout = const Duration(seconds: 20),
    Future<String> Function()? fallbackDirectory,
  })  : dio = dioClient ?? Dio(),
        stateStore = store ?? SessionStateStore(),
        fallbackDirectory = fallbackDirectory ?? _documentsDirectory;

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
    var clean =
        segment.replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_').trim();
    if (clean.isEmpty || clean.replaceAll('.', '').isEmpty) {
      clean = 'item';
    }
    return _fitToNameLimit(clean);
  }

  /// Shortens a name that no filesystem would accept, keeping its extension.
  ///
  /// Refusing the item instead would mean the user does not get their file at
  /// all because its name was long — the wrong trade. The extension is kept
  /// because it is what decides whether the file opens afterwards, and the
  /// middle is what gets dropped.
  ///
  /// Counted in UTF-8 bytes, and cut on a character boundary so the result is
  /// never mojibake.
  String _fitToNameLimit(String name) {
    const limit = AppConstants.qhtpMaxNameBytes;
    if (utf8.encode(name).length <= limit) return name;

    final extension = p.extension(name);
    // An "extension" longer than the budget is not an extension, it is a name
    // with a dot in it.
    final keptExtension =
        utf8.encode(extension).length <= limit ~/ 4 ? extension : '';
    final stem = name.substring(0, name.length - extension.length);
    final stemBudget = limit - utf8.encode(keptExtension).length;

    final buffer = StringBuffer();
    var used = 0;
    for (final rune in stem.runes) {
      final encoded = utf8.encode(String.fromCharCode(rune)).length;
      if (used + encoded > stemBudget) break;
      buffer.writeCharCode(rune);
      used += encoded;
    }
    final shortened = '$buffer$keptExtension';
    return shortened.isEmpty ? 'item' : shortened;
  }

  String materializePath(String relativePath, String baseDir) {
    final segments = relativePath.split('/');
    final safeSegments = <String>[];

    for (final seg in segments) {
      if (seg == '.' || seg == '..' || seg.isEmpty) continue;
      safeSegments.add(sanitizeSegment(seg));
    }

    final resolvedPath = p.normalize(p.joinAll([baseDir, ...safeSegments]));
    if (!p.isWithin(baseDir, resolvedPath) && resolvedPath != baseDir) {
      throw Exception('Path traversal detected: $relativePath');
    }
    return resolvedPath;
  }

  /// [path] if it is free, otherwise `stem (1).ext`, `stem (2).ext`, … — the
  /// same `name (n).ext` convention the WebRTC receiver uses.
  ///
  /// Only the final name is checked, not the `.qs.partial`: a leftover partial
  /// is either this session's to resume or stale debris the sweep will clear,
  /// and neither is a reason to rename the file the user asked for.
  String _uniquePath(String path) {
    var candidate = path;
    var counter = 1;
    while (File(candidate).existsSync()) {
      final ext = p.extension(path);
      final stem = p.basenameWithoutExtension(path);
      candidate = p.join(p.dirname(path), '$stem ($counter)$ext');
      counter++;
    }
    return candidate;
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
      // into it does not.
      final probe = File(p.join(dir.path, '.qs_write_probe'));
      await probe.writeAsBytes(const [0]);
      await probe.delete();

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
        preferredResultPath:
            placed.length == 1 ? placed.single : p.join(targetBaseDir, rootName),
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
    if (item.size > 0 && writtenBytes != item.size) {
      await partial.delete();
      throw Exception(
          'size mismatch for ${item.path}: received $writtenBytes bytes, '
          'manifest declares ${item.size}');
    }

    final expected = expectedSha256;
    final actual = streamedSha256 ??
        'sha256:${await sha256.bind(partial.openRead()).first}';

    if (expected != null && expected.isNotEmpty && actual != expected) {
      await partial.delete();
      throw Exception('checksum mismatch for ${item.path}: '
          'expected $expected, computed $actual');
    }
    return actual;
  }

  Future<int?> _getAvailableDiskSpace(String dirPath) async {
    // The disk_space_2 iOS plugin crashes while registering on iOS 18.4.1.
    // This check is advisory; transfers remain safe because the file is
    // written incrementally and all I/O errors are handled by the caller.
    debugPrint('Disk space preflight skipped for $dirPath.');
    return null;
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

      final freeDiskBytes = await _getAvailableDiskSpace(resolvedTargetBaseDir);
      final requiredBytes =
          totalBytes + 64 * 1024 * 1024; // totalBytes + 64MB margin
      if (freeDiskBytes != null && freeDiskBytes < requiredBytes) {
        return Left(FileFailure(
            'Not enough disk space. Required: ${(requiredBytes / (1024 * 1024)).toStringAsFixed(0)} MB'));
      }

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

      final manifestRes =
          await dio.get('https://$host:$port/v2/manifest', options: options);
      if (manifestRes.statusCode != 200) {
        return const Left(NetworkFailure('Failed to fetch session manifest'));
      }

      final manifestMap = manifestRes.data is String
          ? jsonDecode(manifestRes.data as String)
          : manifestRes.data;
      final manifest =
          QhtpManifest.fromJson(manifestMap as Map<String, dynamic>);

      // Load or initialize state store for resume
      final localState = await stateStore.loadState(sessionId) ?? {};

      int sessionReceivedBytes = 0;
      for (final item in manifest.items) {
        final state = localState[item.id];
        if (state != null && state.status == 'completed') {
          sessionReceivedBytes += item.size;
        }
      }

      DateTime lastSpeedUpdate = DateTime.now();
      DateTime lastProgressReport =
          DateTime.now().subtract(_progressInterval);
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
        var finalPath = itemState.finalPath;
        if (finalPath == null || File(finalPath).existsSync()) {
          finalPath =
              _uniquePath(materializePath(item.path, resolvedTargetBaseDir));
        }
        final partialPath = '$finalPath.qs.partial';

        if (itemState.finalPath != finalPath) {
          itemState = itemState.copyWith(finalPath: finalPath);
          localState[item.id] = itemState;
          await stateStore.saveState(
            sessionId: sessionId,
            host: host,
            port: port,
            token: token,
            baseDir: resolvedTargetBaseDir,
            items: localState,
          );
        }

        final parentDir = Directory(p.dirname(finalPath));
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
        }

        // Per-file retry up to 3 attempts
        bool itemSuccess = false;
        Object? itemError;

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
            int existingBytes = 0;
            if (await partialFile.exists()) {
              existingBytes = await partialFile.length();
            }

            if (item.size > 0 && existingBytes > item.size) {
              // A previous attempt wrote past the declared end — a 200 answered
              // to a Range request appends a whole second copy. Clamping the
              // counter used to hide that and rename an oversized file as
              // complete; start the item over instead.
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
            sink = await partialFile.open(
              mode: existingBytes > 0 ? FileMode.append : FileMode.write,
            );

            int itemReceivedBytes = existingBytes;
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

              if (existingBytes > 0 && response.statusCode == 200) {
                // 200 means the server ignored the Range header and is sending
                // from byte zero. Appending that to a partial file silently
                // corrupts it, which is how resumed downloads used to break.
                throw Exception(
                    'Server ignored the Range request (200 instead of 206)');
              }
              if (response.statusCode != 200 && response.statusCode != 206) {
                throw Exception(
                    'Server returned status ${response.statusCode}');
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
                writeInFlight = sink!.writeFrom(block);
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

            // No delete-then-rename: `finalPath` was resolved to a free name
            // above, so there is nothing here to overwrite. If something has
            // taken the name in the meantime the rename throws, the item
            // fails, and the next run picks a new name — it never removes a
            // file it did not write.
            await partialFile.rename(finalPath);
            await syncDirectory(p.dirname(finalPath));

            itemState = itemState.copyWith(
              status: 'completed',
              partialBytes: item.size,
              sha256: checksumStr,
              finalPath: finalPath,
            );

            localState[item.id] = itemState;
            await stateStore.saveState(
              sessionId: sessionId,
              host: host,
              port: port,
              token: token,
              baseDir: resolvedTargetBaseDir,
              items: localState,
            );

            itemSuccess = true;
            break; // Success, break retry loop
          } catch (e) {
            itemError = e;
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

      // 6. Signal completion to the sender. This POST is the sender's only
      // authoritative completion signal, so best-effort is not enough: a POST
      // lost to a tearing-down bridge used to leave the sender sitting on
      // 99% until the session timed out, with the receiver looking finished.
      Object? completeError;
      for (var attempt = 1;
          attempt <= AppConstants.maxRetryAttempts;
          attempt++) {
        try {
          await dio.post(
            'https://$host:$port/v2/session/complete',
            data: {
              'sessionId': sessionId,
              'receivedItems': manifest.itemCount,
              'receivedBytes': manifest.totalBytes,
              'failedItems': 0,
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

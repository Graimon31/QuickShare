import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/utils/wakelock_guard.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';
import 'package:quickshare/core/webrtc/idle_watchdog.dart';
import 'package:quickshare/core/webrtc/sdp_compressor.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/core/webrtc/turn_credential_refresher.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Raised when the sender deliberately stopped the transfer.
///
/// Separate from a generic failure so the screen can say "the sender
/// cancelled" instead of "connection error" — the two are the same silence on
/// the wire but mean opposite things to whoever is watching.
class TransferCancelledBySender implements Exception {
  const TransferCancelledBySender();

  @override
  String toString() => 'the sender cancelled the transfer';
}

/// Progress for a link-based (WebRTC) receive.
class WebRtcReceiveProgress {
  final String phase; // 'connecting' | 'transferring' | 'completed' | 'failed'
  final String fileName;
  final int received;
  final int total;
  final int speedBps;
  final String? detail;

  const WebRtcReceiveProgress({
    required this.phase,
    required this.fileName,
    required this.received,
    required this.total,
    required this.speedBps,
    this.detail,
  });
}

/// Receives a file over a WebRTC DataChannel, negotiated serverlessly: the
/// offer arrives in the QR code and the answer goes back through a sealed
/// out-of-band channel.
class WebRtcReceiverTransport {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;

  final _progressController =
      StreamController<WebRtcReceiveProgress>.broadcast();
  final _statusController = StreamController<TransferStatus>.broadcast();

  Stream<WebRtcReceiveProgress> get progressStream =>
      _progressController.stream;
  Stream<TransferStatus> get statusStream => _statusController.stream;

  final _completion = Completer<String>();

  DurableFile? _currentFile;
  String _fileName = 'received_file';
  String? _targetPath;

  /// Folder sessions land under `<baseDir>/<name>.qs.partial/` and become real
  /// in one atomic directory rename once every file is on disk — a folder
  /// opened half-populated is worse than one that is not there yet. Off unless
  /// the manifest is a single folder and its final name is still free; when
  /// that name is already taken, files are merged into it individually instead.
  bool _folderMode = false;
  String? _stagedRoot;
  String? _finalRoot;


  DateTime _lastTick = DateTime.now();
  int _lastBytes = 0;
  int _speedBps = 0;
  String _baseDir = '';
  final _gathering = IceGatheringTracker();

  /// Watches for the peer going silent mid-transfer — the serverless path has
  /// no signaling channel to report a disconnect through, so ICE state and a
  /// lack of incoming bytes are the only signals available.
  IdleWatchdog? _idleWatchdog;
  static const _idleTimeout = Duration(seconds: 30);

  /// How long ICE may sit in `disconnected` before giving up — matches the
  /// sender's grace period ([WebRtcTransferTransport._iceRecoveryGrace]) for
  /// the same reason: routine on a relay path under a VPN, not fatal on its
  /// own.
  static const _iceRecoveryGrace = Duration(seconds: 20);
  Timer? _iceRecoveryTimer;

  /// §8 — whether the incoming binary stream is gzip-compressed.
  bool _isCompressed = false;

  /// Set when the sender announced it was stopping, so the ICE teardown that
  /// follows is not reported a second time as a connection error.
  bool _cancelledBySender = false;

  /// Set once the session's outcome is decided, so a late `complete` frame
  /// or the teardown's own ICE events cannot fail an already-finished
  /// session.
  bool _sessionFinished = false;

  /// Holds the connection open briefly after a byte-counted completion, so
  /// the sender's trailing `complete` frame still has somewhere to arrive —
  /// closing immediately would turn the sender's final drain into a stall.
  Timer? _teardownTimer;

  /// The manifest for a multi-file session, and where we are inside it.
  ///
  /// Empty for a legacy single-file sender, which opens with `file-meta` and
  /// never sends a manifest — that path is kept working rather than treated as
  /// a protocol error, because an older build is not a broken peer.
  List<TransferItem> _manifest = const [];

  /// Absolute paths of everything written so far, in manifest order.
  final List<String> _writtenPaths = [];

  /// A manifest still arriving in parts, and how many parts it owes.
  ///
  /// A folder of thousands of files cannot be announced in one frame, so the
  /// sender splits it. Nothing is opened until every part is in: a session
  /// that started from half a manifest would write files to the wrong places
  /// and mis-report its own size the whole way through.
  List<TransferItem>? _partialManifest;
  int _manifestPartsExpected = 0;
  int _manifestPartsSeen = 0;

  /// Bytes across the entire session, so progress does not snap back to zero
  /// once per file.
  int _sessionTotalBytes = 0;
  int _sessionReceivedBytes = 0;

  List<String> get receivedPaths => List.unmodifiable(_writtenPaths);

  /// §6 — keeps CPU/display alive during the transfer.
  final _wakelockGuard = WakelockGuard();

  /// §9 — refreshes TURN credentials before they expire.
  TurnCredentialRefresher? _turnRefresher;


  String sanitizeFileName(String name) {
    final base = p
        .basename(name)
        .replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_')
        .trim();
    if (base.isEmpty || base.replaceAll('.', '').isEmpty) {
      return 'received_file';
    }
    return base;
  }

  /// The relative path an item is written to, cleaned segment by segment.
  ///
  /// A folder arrives as files carrying paths like `Trip/Day 1/IMG_0042.HEIC`,
  /// and rebuilding that tree is the entire point — but every segment of it
  /// came off the wire, so every segment is treated as hostile. `..` and `.`
  /// are dropped rather than resolved, separators inside a segment cannot
  /// smuggle a level in because each segment is put through the same filename
  /// sanitizer as a flat name, and an absolute path loses its root. What is
  /// left is always relative and always downward; [resolveTargetPath] still
  /// checks the result against the destination afterwards, because one guard
  /// in front of the filesystem is not enough.
  String sanitizeRelativePath(String rawPath) {
    final segments = rawPath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .map(sanitizeFileName)
        .toList();
    if (segments.isEmpty) return 'received_file';
    return p.joinAll(segments);
  }

  String resolveTargetPath(String fileName, String baseDir) {
    // An empty base makes p.isWithin('', 'photo.jpg') return true and the
    // guard below wave through a relative path, which lands the file in the
    // process working directory. Reject it outright rather than trusting every
    // caller to have set the destination.
    if (baseDir.isEmpty || !p.isAbsolute(baseDir)) {
      throw Exception('Receive directory is not set (got "$baseDir")');
    }
    final resolved =
        p.normalize(p.join(baseDir, sanitizeRelativePath(fileName)));
    if (!p.isWithin(baseDir, resolved)) {
      throw Exception('Path traversal detected in "$fileName"');
    }
    return resolved;
  }

  Future<Map<String, dynamic>> _buildIceConfiguration() =>
      IceServers.configurationDynamic();

  /// Starts the TURN credential refresh timer (§9).
  Future<void> _startTurnRefresher({DateTime? expiresAt}) async {
    _turnRefresher?.cancel();
    final workerUrl = AppConstants.workerBaseUrl.trim();
    if (workerUrl.isEmpty || _peerConnection == null) return;

    _turnRefresher = TurnCredentialRefresher(
      peerConnection: _peerConnection!,
      workerBaseUrl: workerUrl,
      expiresAt: expiresAt,
    );
    _turnRefresher!.start();
  }

  /// Connects serverlessly using an [sdpOffer] carried in the QR code.
  ///
  /// The answer goes back through [deliverAnswer] — a sealed drop through
  /// public infrastructure. An earlier version posted it straight to an
  /// address in the QR code instead, which could only ever work when the
  /// sender was reachable from the internet; the measurements in
  /// natfilter_result.txt showed a port-restricted NAT where that request
  /// never arrives, so both halves of that path are gone.
  Future<String> receiveWithSdpOffer(
    String sdpOffer, {
    String? targetDir,
    Future<void> Function(String answerSdp)? deliverAnswer,
  }) async {
    try {
      _emit('connecting', detail: 'Processing serverless SDP offer…');
      _statusController.add(TransferStatus.connecting);
      await _wakelockGuard.acquire(); // §6

      // This path returns a completer of its own; `_completion` belongs to the
      // room-based path this replaced. Nothing here awaits it; _fail() still
      // completes it, so without a handler every serverless failure surfaces
      // as an unhandled async error alongside the real one.
      unawaited(_completion.future.then((_) {}, onError: (Object _) {}));

      // Resolve the destination before anything can arrive. Leaving this unset
      // used to make resolveTargetPath() return a bare relative name, which
      // put the incoming file in the process working directory — read-only
      // inside the iOS sandbox, and a surprise on desktop.
      _baseDir = targetDir ?? (await getApplicationDocumentsDirectory()).path;
      final baseDirectory = Directory(_baseDir);
      if (!baseDirectory.existsSync()) {
        baseDirectory.createSync(recursive: true);
      }

      final rawSdp = SdpCompressor.decompress(sdpOffer);

      _peerConnection =
          await createPeerConnection(await _buildIceConfiguration());
      await _startTurnRefresher(); // §9

      _peerConnection!.onDataChannel = (RTCDataChannel channel) {
        debugPrint('WebRTC receiver serverless: data channel received');
        _dataChannel = channel;
        channel.onMessage = _handleMessage;
      };

      // The answer is sealed and published once; like the offer, it has no
      // trickle path, so gathering has to finish before it is encoded.
      _peerConnection!.onIceCandidate = _gathering.observe;

      // This path previously had no ICE-state reaction whatsoever — a dead
      // connection here produced no error until the flat 120s timeout further
      // down expired, and that timeout counted the whole transfer, not just
      // the time since the connection actually died.
      _peerConnection!.onIceConnectionState = _onIceStateChanged;

      AppLogger.info('Receiver: decompressed offer, ${rawSdp.length} chars',
          tag: 'WEBRTC_RECEIVER');

      try {
        await _peerConnection!
            .setRemoteDescription(RTCSessionDescription(rawSdp, 'offer'));
      } catch (e, st) {
        AppLogger.error(
            'Receiver setRemoteDescription failed for SDP length ${rawSdp.length}',
            error: e,
            stackTrace: st,
            tag: 'WEBRTC_RECEIVER');
        rethrow;
      }
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      await waitForUsableCandidates(_peerConnection!, _gathering,
          tag: 'WEBRTC_RECEIVER');

      final fullLocalDesc = await _peerConnection!.getLocalDescription();
      final finalAnswerSdp = fullLocalDesc?.sdp ?? answer.sdp;

      if (deliverAnswer != null) {
        AppLogger.info(
            'Receiver: delivering SDP answer through the signaling channel '
            '(${finalAnswerSdp?.length ?? 0} chars)',
            tag: 'WEBRTC_RECEIVER');
        await deliverAnswer(finalAnswerSdp ?? '');
      }

      final completer = Completer<String>();

      late StreamSubscription sub;
      sub = _statusController.stream.listen((status) {
        if (status == TransferStatus.completed) {
          sub.cancel();
          if (!completer.isCompleted) {
            completer.complete(_resultPath());
          }
        } else if (status == TransferStatus.failed) {
          sub.cancel();
          if (!completer.isCompleted) {
            // This is what the caller actually awaits, so the distinction
            // between a deliberate stop and a broken connection has to survive
            // here too — `_completion` carries it, but nothing awaits that one.
            completer.completeError(_cancelledBySender
                ? const TransferCancelledBySender()
                : Exception('Serverless WebRTC transfer failed'));
          }
        }
      });

      // Real failure detection is _onIceStateChanged + the idle watchdog now;
      // this is only a backstop against a Future that never resolves for some
      // other reason. It used to be 120s counted across the *entire* transfer
      // rather than just connection setup, which would have killed any file
      // that took longer than two minutes over a relay even while healthy.
      return completer.future.timeout(
        const Duration(minutes: 30),
        onTimeout: () {
          sub.cancel();
          throw Exception(
              'Serverless transfer timed out (30 min backstop) without '
              'reaching a completed or failed state');
        },
      );
    } on TransferCancelledBySender {
      // Deliberate, and already reported. Re-wrapping it as a generic failure
      // here would undo the distinction the whole message exists to make.
      await _wakelockGuard.release(); // §6
      rethrow;
    } catch (e) {
      await _wakelockGuard.release(); // §6
      _statusController.add(TransferStatus.failed);
      throw Exception('receiveWithSdpOffer failed: $e');
    }
  }


  /// Serialises message handling.
  ///
  /// `onMessage` is a `void` callback, so an async handler assigned to it is
  /// invoked without ever being awaited: the next message starts running while
  /// the previous one is parked on a flush or a close. With per-file framing
  /// that is immediately fatal — `file-end` closes the sink while a chunk of
  /// the same file is still being written, and the write lands on a closed
  /// StreamSink. Chaining every message onto one future restores the ordering
  /// the wire protocol already guarantees.
  Future<void> _handlerChain = Future<void>.value();

  void _handleMessage(RTCDataChannelMessage message) {
    _handlerChain = _handlerChain.then((_) => _processMessage(message));
  }

  /// §8 — handles incoming DataChannel messages.
  ///
  /// Binary messages are decompressed if the sender advertised
  /// `"compressed": true` in the `file-meta` JSON.
  Future<void> _processMessage(RTCDataChannelMessage message) async {
    try {
      if (message.isBinary) {
        if (_currentFile == null) return;

        // §8: decompress if the sender said so.
        final bytes = _isCompressed
            ? GZipDecoder().decodeBytes(message.binary)
            : message.binary;

        _idleWatchdog?.kick();
        await _currentFile!.add(bytes);
        // Progress is reported across the whole session, so a ten-photo
        // transfer does not snap back to 0% ten times.
        _sessionReceivedBytes += bytes.length;

        final now = DateTime.now();
        final delta = now.difference(_lastTick).inMilliseconds / 1000.0;
        if (delta >= 0.5) {
          _speedBps = ((_sessionReceivedBytes - _lastBytes) / delta).round();
          _lastTick = now;
          _lastBytes = _sessionReceivedBytes;
        }
        _emit('transferring');
        return;
      }

      final data = jsonDecode(message.text) as Map<String, dynamic>;
      final type = data['type'] as String?;

      switch (type) {
        case TransferProtocol.manifest:
          _openSession(TransferProtocol.parseManifest(data));

        case TransferProtocol.manifestBegin:
          // Only the promise of a manifest so far. Sessions large enough to
          // need this are folders, and a folder half-announced is worse than
          // none: nothing opens until the last part lands.
          final parts = data['parts'] as int?;
          if (parts == null || parts <= 0) {
            _fail('manifest-begin announced $parts parts');
            return;
          }
          _partialManifest = <TransferItem>[];
          _manifestPartsExpected = parts;
          _manifestPartsSeen = 0;
          _armIdleWatchdog();

        case TransferProtocol.manifestPart:
          final pending = _partialManifest;
          if (pending == null) {
            _fail('a manifest part arrived before the manifest it belongs to');
            return;
          }
          pending.addAll(TransferProtocol.parseManifest(data));
          _manifestPartsSeen++;
          _armIdleWatchdog();
          if (_manifestPartsSeen >= _manifestPartsExpected) {
            _partialManifest = null;
            _openSession(pending);
          }

        case TransferProtocol.fileStart:
          final index = data['index'] as int?;
          if (index == null || index < 0 || index >= _manifest.length) {
            _fail('file-start referred to item $index, '
                'which is not in a manifest of ${_manifest.length}');
            return;
          }
          final item = _manifest[index];
          _isCompressed = item.compressed;
          _currentFile = _openIncoming(item.path);
          await _currentFile!.open();
          _emit('transferring');

        case TransferProtocol.fileEnd:
          await _sealCurrentFile();
          // A full byte count is completion in its own right: the sender's
          // trailing `complete` frame can die in its closing channel over a
          // relay, and waiting for it is what left receivers hanging on
          // 98-100% forever.
          if (_sessionTotalBytes > 0 &&
              _sessionReceivedBytes >= _sessionTotalBytes) {
            await _completeSession(holdConnection: true);
          }

        case TransferProtocol.legacyFileMeta:
        case TransferProtocol.legacyMetadata:
          // Single-file sender on an older build: synthesise a one-item
          // manifest so everything downstream sees one shape.
          final item = TransferItem(
            name: data['name'] as String? ?? 'received_file',
            size: data['size'] as int? ?? 0,
            mimeType: data['mime'] as String? ?? 'application/octet-stream',
            compressed: (data['compressed'] as bool?) ?? false,
          );
          _manifest = [item];
          _sessionTotalBytes = item.size;
          _sessionReceivedBytes = 0;
          _writtenPaths.clear();
          _fileName = sanitizeFileName(item.name);
          _isCompressed = item.compressed;
          _lastBytes = 0;
          _lastTick = DateTime.now();
          _currentFile = _openIncoming(_fileName);
          await _currentFile!.open();
          _statusController.add(TransferStatus.transferring);
          _emit('transferring');
          _armIdleWatchdog();

        case TransferProtocol.cancelled:
          // Deliberate stop: react now rather than waiting out the disconnect
          // grace period, and say what actually happened. Nothing half-written
          // is kept — a cancelled transfer leaves no debris.
          AppLogger.info('Sender cancelled the transfer',
              tag: 'WEBRTC_RECEIVER');
          await _discardInFlight();
          _cancelledBySender = true;
          _idleWatchdog?.cancel();
          _fail('The sender cancelled the transfer');

        case TransferProtocol.complete:
        case TransferProtocol.legacyFileComplete:
          // A legacy sender closes the only file here rather than with
          // file-end, so flush whatever is still open.
          await _sealCurrentFile();
          _idleWatchdog?.cancel();

          if (_sessionTotalBytes > 0 &&
              _sessionReceivedBytes < _sessionTotalBytes) {
            _fail('Transfer completed prematurely: received '
                '$_sessionReceivedBytes of $_sessionTotalBytes bytes');
          } else {
            await _completeSession();
          }
      }
    } catch (e) {
      _fail('Failed to write incoming file: $e');
    }
  }

  void _armIdleWatchdog() {
    _idleWatchdog ??= IdleWatchdog(
      timeout: _idleTimeout,
      onTimeout: () =>
          _fail('No data received for ${_idleTimeout.inSeconds}s — the '
              'connection appears to have died'),
    );
    _idleWatchdog!.kick();
  }

  /// Starts a session from the manifest it opened with, however many frames
  /// that manifest took to arrive.
  void _openSession(List<TransferItem> items) {
    _manifest = items;
    _sessionTotalBytes = items.fold<int>(0, (sum, i) => sum + i.size);
    _sessionReceivedBytes = 0;
    _writtenPaths.clear();
    _lastBytes = 0;
    _lastTick = DateTime.now();
    // A folder is named after the folder, not after the first photo in it and
    // not "412 files": that is what the sender picked and what the progress
    // screen should be counting down.
    final folderRoot = _commonRootFolder(items);
    _fileName = folderRoot ??
        (items.length == 1
            ? sanitizeFileName(items.first.name)
            : '${items.length} files');
    _armFolderStaging(folderRoot);
    _statusController.add(TransferStatus.transferring);
    _emit('transferring');
    _armIdleWatchdog();
    AppLogger.info(
        'Receiving ${items.length} file(s), $_sessionTotalBytes bytes total'
        '${folderRoot != null ? ' under "$folderRoot"' : ''}'
        '${_folderMode ? ', staged as ${p.basename(_stagedRoot!)}' : ''}',
        tag: 'WEBRTC_RECEIVER');
  }

  /// Decides whether this session writes into a staged `<name>.qs.partial/`
  /// directory that is renamed whole at the end (folder mode), or straight
  /// into the destination.
  ///
  /// Folder mode needs a single common root *and* a final name that is still
  /// free — a directory rename is atomic only onto a name that does not exist.
  /// When `<baseDir>/<root>` is already there, [_folderMode] stays off and the
  /// incoming files are merged into it one at a time instead.
  void _armFolderStaging(String? folderRoot) {
    _folderMode = false;
    _stagedRoot = null;
    _finalRoot = null;
    if (folderRoot == null || _baseDir.isEmpty) return;

    final finalRoot = p.normalize(p.join(_baseDir, folderRoot));
    if (!p.isWithin(_baseDir, finalRoot)) return;
    if (Directory(finalRoot).existsSync() || File(finalRoot).existsSync()) {
      return;
    }

    _folderMode = true;
    _finalRoot = finalRoot;
    _stagedRoot = '$finalRoot$kPartialSuffix';
    final staged = Directory(_stagedRoot!);
    if (staged.existsSync()) {
      try {
        staged.deleteSync(recursive: true);
      } catch (_) {
        // A leftover we could not clear; open() will still write into it and
        // the sweep gets it next launch.
      }
    }
  }

  /// A [DurableFile] for an incoming item announced with [manifestPath].
  ///
  /// In folder mode the file goes straight into the staged directory (the
  /// directory rename is the atomic step, a per-file one would be redundant);
  /// otherwise it is a staged single file with its own `.qs.partial`.
  DurableFile _openIncoming(String manifestPath) {
    if (_folderMode) {
      final within = _pathBelowRoot(manifestPath);
      final target = p.normalize(p.join(_stagedRoot!, within));
      if (!p.isWithin(_stagedRoot!, target)) {
        throw Exception('Path traversal detected in "$manifestPath"');
      }
      _targetPath = target;
      return DurableFile(target, staged: false);
    }
    _targetPath = _uniquePath(resolveTargetPath(manifestPath, _baseDir));
    return DurableFile(_targetPath!);
  }

  /// The part of a manifest path below its top folder, every segment cleaned.
  /// `Trip/Day 1/IMG_0042.HEIC` → `Day 1/IMG_0042.HEIC`.
  String _pathBelowRoot(String rawPath) {
    final segments = p.split(sanitizeRelativePath(rawPath));
    if (segments.length <= 1) {
      return segments.isEmpty ? 'received_file' : segments.last;
    }
    return p.joinAll(segments.sublist(1));
  }

  /// Aborts whatever file is mid-write and clears every trace of the session
  /// from disk — the in-flight partial, and a staged folder directory whole.
  Future<void> _discardInFlight() async {
    await _currentFile?.abort();
    _currentFile = null;
    if (_folderMode && _stagedRoot != null) {
      final staged = Directory(_stagedRoot!);
      if (staged.existsSync()) {
        try {
          await staged.delete(recursive: true);
        } catch (_) {}
      }
    } else if (_targetPath != null) {
      for (final path in [_targetPath!, '$_targetPath$kPartialSuffix']) {
        final f = File(path);
        if (f.existsSync()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    }
  }

  /// The single folder every item in [items] sits under, if there is one.
  ///
  /// Null when the session is a flat set of files, or a mix of folders — both
  /// of which are better described by a count than by a name.
  String? _commonRootFolder(List<TransferItem> items) {
    String? root;
    for (final item in items) {
      final segments = p.posix.split(item.path);
      if (segments.length < 2) return null;
      final first = sanitizeFileName(segments.first);
      if (root == null) {
        root = first;
      } else if (root != first) {
        return null;
      }
    }
    return root;
  }

  /// fsyncs, closes and (outside folder mode) atomically renames the file
  /// currently being written, if any, and records its committed path once.
  Future<void> _sealCurrentFile() async {
    final file = _currentFile;
    _currentFile = null;
    if (file == null) return;
    final path = await file.commit();
    if (!_writtenPaths.contains(path)) _writtenPaths.add(path);
  }

  /// Declares the session received: every byte the manifest announced is on
  /// disk. Runs once; later calls only get a chance to tear down immediately
  /// whatever an earlier call deliberately kept open.
  ///
  /// [holdConnection] keeps the channel alive for the sender's trailing
  /// `complete` frame — the sender drains its send buffer before reporting
  /// completion, and closing under that drain turns its success into a
  /// stall. The frame (or the timer) then finishes the teardown.
  Future<void> _completeSession({bool holdConnection = false}) async {
    if (!_sessionFinished) {
      _sessionFinished = true;
      _idleWatchdog?.cancel();
      await _sealCurrentFile();
      await _commitFolderIfStaged();
      _statusController.add(TransferStatus.completed);
      _emit('completed');
      if (!_completion.isCompleted) {
        _completion.complete(_resultPath());
      }
    }
    if (holdConnection && _teardownTimer == null) {
      _teardownTimer =
          Timer(const Duration(seconds: 5), () => unawaited(_cleanup()));
    } else if (!holdConnection) {
      _teardownTimer?.cancel();
      _teardownTimer = null;
      await _cleanup();
    }
  }

  /// What the session resolves to: the folder in folder mode, otherwise the
  /// first file written (or, before anything landed, the last target).
  String _resultPath() {
    if (_folderMode) return _finalRoot ?? '';
    if (_writtenPaths.isNotEmpty) return _writtenPaths.first;
    return _targetPath ?? p.join(_baseDir, 'received_file');
  }

  /// Renames a staged folder onto its real name in one atomic step, once every
  /// file inside it is on disk. The session result then points at the folder,
  /// not at some photo three levels down inside it.
  Future<void> _commitFolderIfStaged() async {
    if (!_folderMode || _stagedRoot == null || _finalRoot == null) return;
    try {
      await commitDirectory(_stagedRoot!, _finalRoot!);
      _writtenPaths
        ..clear()
        ..add(_finalRoot!);
    } catch (e) {
      // The name was free when the session opened; if the rename still fails
      // the staged directory stays for the sweep, and the result path below
      // will not resolve — logged rather than silently dropped.
      AppLogger.error('Could not commit the received folder "$_finalRoot": $e',
          tag: 'WEBRTC_RECEIVER');
    }
  }

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

  void _emit(String phase, {String? detail}) {
    if (_progressController.isClosed) return;
    _progressController.add(WebRtcReceiveProgress(
      phase: phase,
      fileName: _fileName,
      received: _sessionReceivedBytes,
      total: _sessionTotalBytes,
      speedBps: _speedBps,
      detail: detail,
    ));
  }

  /// Reacts to ICE state changes. There is no signaling channel to carry a
  /// `peer-disconnected` message — the answer travelled out of band and the
  /// channel is gone — so this and the idle watchdog are the only ways a
  /// dead connection is ever noticed.
  ///
  /// `disconnected` gets a grace period rather than an immediate failure: it
  /// is routine on a relayed path under a VPN and usually recovers within
  /// seconds. Failing on the first blip would abort transfers that were never
  /// actually broken.
  void _onIceStateChanged(RTCIceConnectionState state) {
    AppLogger.info('Receiver ICE state: $state', tag: 'WEBRTC_RECEIVER');

    // A cancelled session tears its connection down by design; reporting that
    // as a fault would overwrite the real reason with a misleading one.
    if (_cancelledBySender) return;

    // A finished session's own teardown surfaces here as closed/failed, and
    // the sender leaving right after its last frame looks the same — neither
    // may overwrite a completed status.
    if (_sessionFinished) return;

    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = Timer(_iceRecoveryGrace, () {
          _fail('ICE stayed disconnected for '
              '${_iceRecoveryGrace.inSeconds}s — giving up on this session');
        });
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
        // A dead peer with every announced byte already on disk is a finished
        // transfer, not a failed one: the sender closes as soon as its last
        // frame leaves, which can win the race against its `complete` frame.
        if (_sessionTotalBytes > 0 &&
            _sessionReceivedBytes >= _sessionTotalBytes) {
          unawaited(_completeSession());
        } else {
          _fail('Peer connection failed (ICE $state)');
        }
      default:
        break;
    }
  }

  void _fail(String reason) {
    debugPrint('WebRTC receive failed: $reason');
    _statusController.add(TransferStatus.failed);
    _emit('failed', detail: reason);
    if (!_completion.isCompleted) {
      _completion.completeError(_cancelledBySender
          ? const TransferCancelledBySender()
          : Exception(reason));
    }
    _cleanup();
  }

  Future<void> _cleanup() async {
    _idleWatchdog?.cancel();
    _teardownTimer?.cancel();
    _teardownTimer = null;
    _iceRecoveryTimer?.cancel();
    _iceRecoveryTimer = null;
    _turnRefresher?.cancel(); // §9
    _turnRefresher = null;
    await _wakelockGuard.release(); // §6
    await _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    _peerConnection = null;
  }

  Future<void> cancel() async {
    await _discardInFlight();
    _statusController.add(TransferStatus.cancelled);
    if (!_completion.isCompleted) {
      _completion.completeError(Exception('Cancelled by user'));
    }
    await _cleanup();
  }
}

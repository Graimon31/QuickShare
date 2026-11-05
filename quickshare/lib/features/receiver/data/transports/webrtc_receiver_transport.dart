import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/security/path_sanitizer.dart';
import 'package:quickshare/core/storage/disk_space.dart';
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/storage/safe_path.dart';
import 'package:quickshare/core/storage/storage_failure.dart';
import 'package:quickshare/core/utils/wakelock_guard.dart';
import 'package:quickshare/core/webrtc/ice_connect_deadline.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';
import 'package:quickshare/core/webrtc/idle_watchdog.dart';
import 'package:quickshare/core/webrtc/relay_availability.dart';
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
  WebRtcReceiverTransport({
    DiskSpaceProbe? diskSpace,
    this.debugFileFactory,
    this.iceConnectBudget = IceConnectDeadline.defaultBudget,
  }) : _diskSpace = diskSpace ?? DiskSpaceProbe.forCurrentPlatform();

  /// How long a negotiation may take once the answer is delivered.
  /// Overridable only so a test need not spend a minute to see the deadline
  /// act.
  final Duration iceConnectBudget;

  /// Says how much room the destination has; see [DiskSpaceProbe].
  final DiskSpaceProbe _diskSpace;

  /// Test seam: builds the file an incoming item is written to, so a test can
  /// fill the disk or change the filesystem at an exact moment. Null in
  /// production.
  @visibleForTesting
  final DurableFile Function(String path,
      {required bool staged, required String base})? debugFileFactory;

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

  /// Progress crosses into the bloc, emits a state and rebuilds the receiving
  /// screen. A chunk is 64 KB, so unthrottled that fired hundreds of times a
  /// second on the same isolate that runs the write loop — the same shape as
  /// a Desktop→iOS transfer "hanging". Same cadence as the QHTP client, and
  /// for the same reason.
  static const Duration _progressInterval = Duration(milliseconds: 100);
  DateTime _lastProgressReport =
      DateTime.now().subtract(_progressInterval);

  /// How large the item now open is meant to be, from the manifest. The seal
  /// checks the file against it before the name goes on: a truncated item
  /// from the middle of a folder must not land under its real name with the
  /// rest of the transfer looking fine.
  int _currentItemExpectedBytes = -1;

  /// Which manifest item is open, and how many of its bytes have arrived.
  int _currentItemIndex = -1;
  int _currentItemReceived = 0;

  /// The manifest items that have been sealed — closed at exactly their
  /// announced size. A session is received when every item is in here, not
  /// when the running byte total happens to add up.
  final Set<int> _sealedItems = <int>{};

  /// A complete staged folder whose rename onto its real name failed. It is
  /// the only copy of what was received, so nothing deletes it: not the
  /// failure's own cleanup, and (by the `.qs.kept` mark inside it) not the
  /// startup sweep either.
  String? _keptStagedRoot;
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

  /// Set by the first [_fail] (and by [cancel]), before anything else about
  /// the failure is done. From then on frames still queued in
  /// [_handlerChain] are ignored — they would write into, or seal, a file
  /// that is being thrown away — and a second failure, which is only the
  /// first one seen again from the other side, does not replace the reason
  /// the person is shown.
  bool _failed = false;

  /// Whether the session has ended, in either direction. A failure is
  /// reported only once its file has been put down (see [_fail]), so
  /// `_completion` being settled is no longer the first sign of one.
  bool get _ended => _failed || _completion.isCompleted;

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

  /// Why this session has no relay, from the Worker fetch that opened the peer
  /// connection; null when it has one. Kept so a negotiation that fails can
  /// say whether the relay was missing from the start.
  RelayUnavailable? _relayUnavailable;

  /// Bounds the wait for a connection once the answer has been delivered;
  /// expiry is treated exactly like ICE reporting `failed`.
  late final IceConnectDeadline _connectDeadline = IceConnectDeadline(
    budget: iceConnectBudget,
    tag: 'WEBRTC_RECEIVER',
    onExpired: () => unawaited(_failNegotiation()),
  );

  /// Whether the connect deadline is running right now. For a test that has to
  /// see it stop once the connection is up.
  @visibleForTesting
  bool get iceDeadlineArmed => _connectDeadline.isArmed;

  /// True once ICE has connected at least once. Before that, an ICE failure is
  /// "no path between the devices"; after it, an interruption.
  bool _iceEstablished = false;

  /// Set when the connection never came up, so the caller awaiting the
  /// transfer gets the typed reason rather than a bare `Exception`.
  IceNegotiationFailed? _iceFailure;

  /// Set when the session stopped on a storage problem — a full disk, a link
  /// in the destination — so the screen can say which in the user's language
  /// instead of repeating an exception's text.
  FileException? _storageFailure;

  /// A negotiation failure is being worked out (it reads the stats before it
  /// tears anything down), so a second trigger — ICE `failed` right behind the
  /// deadline, say — must not start another.
  bool _negotiationFailing = false;

  String sanitizeFileName(String name) {
    return PathSanitizer.sanitizeSegment(p.basename(name),
        defaultName: 'received_file');
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
    return PathSanitizer.sanitizeRelativePath(rawPath,
        defaultName: 'received_file');
  }

  String resolveTargetPath(String fileName, String baseDir) {
    // An empty base makes p.isWithin('', 'photo.jpg') return true and the
    // guard below wave through a relative path, which lands the file in the
    // process working directory. Reject it outright rather than trusting every
    // caller to have set the destination. A link already sitting on the way
    // to the name ends the transfer too: see [SafePath].
    return SafePath.resolve(fileName, baseDir, defaultName: 'received_file');
  }

  Future<IceSetup> _buildIceConfiguration() => IceServers.configurationDynamic();

  /// Starts the TURN credential refresh timer (§9).
  Future<void> _startTurnRefresher({DateTime? expiresAt}) async {
    _turnRefresher?.cancel();
    final workerUrl = AppConstants.workerBaseUrl.trim();
    if (workerUrl.isEmpty || _peerConnection == null) return;
    // Switched off or never configured will still be so in 25 minutes.
    if (_relayUnavailable?.reason.isTerminal ?? false) return;

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

      final setup = await _buildIceConfiguration();
      final ice = setup.configuration;
      final expectingRelay = IceServers.containsTurn(ice);
      _relayUnavailable = setup.relayUnavailable;
      AppLogger.info(
          'Receiver: creating peer connection '
          '(expectingRelay=$expectingRelay, '
          'relay=${_relayUnavailable?.reason.name ?? 'available'}, '
          'policy=${ice['iceTransportPolicy']})',
          tag: 'WEBRTC_RECEIVER');
      _peerConnection = await createPeerConnection(ice);
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
          expectingRelay: expectingRelay, tag: 'WEBRTC_RECEIVER');

      final fullLocalDesc = await _peerConnection!.getLocalDescription();
      final finalAnswerSdp = fullLocalDesc?.sdp ?? answer.sdp;

      if (deliverAnswer != null) {
        AppLogger.info(
            'Receiver: delivering SDP answer through the signaling channel '
            '(${finalAnswerSdp?.length ?? 0} chars)',
            tag: 'WEBRTC_RECEIVER');
        await deliverAnswer(finalAnswerSdp ?? '');
      }

      // Both descriptions are in and the sender has (or is about to have) the
      // answer: from here a connection comes up or the session is written off,
      // whether or not libwebrtc ever says `failed`.
      _connectDeadline.arm();

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
                : _iceFailure ??
                    _storageFailure ??
                    Exception('Serverless WebRTC transfer failed'));
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

  /// Feeds one frame the way `onMessage` would, and resolves when the handler
  /// chain has drained it. The chained model means a caller cannot otherwise
  /// know when a message has finished being processed.
  @visibleForTesting
  Future<void> deliverForTest(RTCDataChannelMessage message, {String? baseDir}) {
    if (baseDir != null) _baseDir = baseDir;
    _handleMessage(message);
    return _handlerChain;
  }

  /// The completion future the real receive path returns, so a test can see
  /// how it settles without standing up a peer connection.
  @visibleForTesting
  Future<String> get completionForTest => _completion.future;

  /// §8 — handles incoming DataChannel messages.
  ///
  /// Binary messages are decompressed if the sender advertised
  /// `"compressed": true` in the `file-meta` JSON.
  Future<void> _processMessage(RTCDataChannelMessage message) async {
    // Whatever was queued behind a failure belongs to a session that is being
    // taken apart. Handling it is not harmless: a `file-end` would try to seal
    // the very file that is being closed and deleted, and what that raised
    // was then reported as a second, unrelated failure.
    if (_failed) return;
    try {
      if (message.isBinary) {
        if (_currentFile == null) return;

        // §8: decompress if the sender said so.
        final bytes = _isCompressed
            ? GZipDecoder().decodeBytes(message.binary)
            : message.binary;

        // More than the item announced is a broken sender (or a hostile one):
        // the bytes would land in a file whose size the manifest already
        // promised, and a count that happens to add up later hides it.
        if (_currentItemExpectedBytes >= 0 &&
            _currentItemReceived + bytes.length > _currentItemExpectedBytes) {
          final name = p.basename(_currentFile!.finalPath);
          _fail('"$name" sent more than the $_currentItemExpectedBytes bytes '
              'it announced');
          return;
        }

        _idleWatchdog?.kick();
        await _currentFile!.add(bytes);
        _currentItemReceived += bytes.length;
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
        final sinceReport = now.difference(_lastProgressReport);
        if (sinceReport >= _progressInterval) {
          _lastProgressReport = now;
          _emit('transferring');
        }
        return;
      }

      final data = jsonDecode(message.text) as Map<String, dynamic>;
      final type = data['type'] as String?;

      if (_sessionFinished && type != TransferProtocol.complete) return;

      switch (type) {
        case TransferProtocol.manifest:
          await _openSession(TransferProtocol.parseManifest(data));

        case TransferProtocol.manifestBegin:
          // Only the promise of a manifest so far. Sessions large enough to
          // need this are folders, and a folder half-announced is worse than
          // none: nothing opens until the last part lands.
          final parts = data['parts'] as int?;
          if (parts == null ||
              parts <= 0 ||
              parts * TransferProtocol.maxManifestFrameBytes >
                  AppConstants.qhtpManifestMaxBytes) {
            _fail('manifest-begin announced $parts parts (limit exceeded)');
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
          final parsed = TransferProtocol.parseManifest(data);
          if (pending.length + parsed.length >
              AppConstants.qhtpMaxFileCount) {
            _fail(
                'Manifest item count exceeds the limit of ${AppConstants.qhtpMaxFileCount}');
            return;
          }
          pending.addAll(parsed);
          _manifestPartsSeen++;
          _armIdleWatchdog();
          if (_manifestPartsSeen >= _manifestPartsExpected) {
            _partialManifest = null;
            await _openSession(pending);
          }

        case TransferProtocol.fileStart:
          final index = data['index'] as int?;
          if (index == null || index < 0 || index >= _manifest.length) {
            _fail('file-start referred to item $index, '
                'which is not in a manifest of ${_manifest.length}');
            return;
          }
          // One item at a time, each closed before the next opens. A
          // file-start over an open file used to replace it without sealing
          // it: its bytes still counted, the file was never committed, and
          // the running total could add up regardless.
          if (_currentFile != null) {
            _fail('file-start for item $index arrived while item '
                '$_currentItemIndex was still open');
            return;
          }
          if (_sealedItems.contains(index)) {
            _fail('item $index was announced twice');
            return;
          }
          final item = _manifest[index];
          _isCompressed = item.compressed;
          _currentItemExpectedBytes = item.size;
          _currentItemIndex = index;
          _currentItemReceived = 0;
          _currentFile = _openIncoming(item.path);
          await _currentFile!.open();
          _lastProgressReport =
              DateTime.now().subtract(_progressInterval);
          _emit('transferring');

        case TransferProtocol.fileEnd:
          await _sealCurrentFile();
          // The seal fails the whole transfer when the item came up short;
          // do not then turn around and declare it delivered on the running
          // total.
          if (_ended) return;
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
          if (!await _hasRoomFor(item.size)) return;
          _manifest = [item];
          _sessionTotalBytes = item.size;
          _sessionReceivedBytes = 0;
          _writtenPaths.clear();
          _fileName = sanitizeFileName(item.name);
          _isCompressed = item.compressed;
          _lastBytes = 0;
          _lastTick = DateTime.now();
          _currentItemExpectedBytes = item.size;
          _currentItemIndex = 0;
          _currentItemReceived = 0;
          _sealedItems.clear();
          _currentFile = _openIncoming(_fileName);
          await _currentFile!.open();
          _lastProgressReport =
              DateTime.now().subtract(_progressInterval);
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
          if (_ended) return;

          if (_sessionTotalBytes > 0 &&
              _sessionReceivedBytes < _sessionTotalBytes) {
            _fail('Transfer completed prematurely: received '
                '$_sessionReceivedBytes of $_sessionTotalBytes bytes');
          } else {
            await _completeSession();
          }
      }
    } catch (e) {
      final problem = classifyStorageError(e);
      _fail(problem?.message ?? 'Failed to write incoming file: $e',
          problem: problem);
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
  Future<void> _openSession(List<TransferItem> items) async {
    if (items.length > AppConstants.qhtpMaxFileCount) {
      _fail(
          'Manifest item count (${items.length}) exceeds the limit of ${AppConstants.qhtpMaxFileCount}');
      return;
    }
    final totalBytes = items.fold<int>(0, (sum, i) => sum + i.size);
    if (totalBytes > AppConstants.qhtpMaxSessionBytes) {
      _fail('Manifest total size exceeds the maximum session limit');
      return;
    }
    // Before a file is opened: a session that cannot fit is refused here, in
    // words, rather than discovered at the end of the transfer.
    if (!await _hasRoomFor(totalBytes)) return;
    _manifest = items;
    _sessionTotalBytes = totalBytes;
    _sessionReceivedBytes = 0;
    _writtenPaths.clear();
    _sealedItems.clear();
    _currentItemIndex = -1;
    _currentItemReceived = 0;
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

  /// Whether the destination has room for [bytes] more, failing the session
  /// with the sizes when it is known not to. An answer of "unknown" lets the
  /// transfer run and says so in the log.
  Future<bool> _hasRoomFor(int bytes) async {
    if (_baseDir.isEmpty || bytes <= 0) return true;
    try {
      await requireFreeSpace(_diskSpace, _baseDir,
          remainingBytes: bytes, tag: 'WEBRTC_RECEIVER');
      return true;
    } on NotEnoughSpaceException catch (e) {
      _fail(e.message, problem: classifyStorageError(e));
      return false;
    }
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

    final String finalRoot;
    try {
      finalRoot =
          SafePath.resolve(folderRoot, _baseDir, defaultName: 'received_file');
    } on UnsafePathException {
      // Not staged; the files are written one at a time instead, and the
      // first of them reports what is wrong with the path, with its code.
      return;
    }
    // Looked at without following links: a link named like the folder is a
    // taken name, and so is a dangling one.
    if (SafePath.exists(finalRoot)) return;

    _folderMode = true;
    _finalRoot = finalRoot;
    _stagedRoot = '$finalRoot$kPartialSuffix';
    final stagedType =
        FileSystemEntity.typeSync(_stagedRoot!, followLinks: false);
    if (stagedType != FileSystemEntityType.notFound) {
      try {
        // Debris from an earlier attempt. A link there is removed as a link:
        // a recursive delete would be the one place this receiver went
        // *through* it.
        if (stagedType == FileSystemEntityType.link) {
          Link(_stagedRoot!).deleteSync();
        } else if (stagedType == FileSystemEntityType.directory) {
          Directory(_stagedRoot!).deleteSync(recursive: true);
        } else {
          File(_stagedRoot!).deleteSync();
        }
      } catch (_) {
        // A leftover we could not clear; open() will report it if it is in the
        // way, and the sweep gets it next launch.
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
        throw UnsafePathException(target, 'it leaves the staging folder');
      }
      // The staging folder is ours, but everything between it and the
      // destination — and every folder inside it — is checked as well.
      SafePath.assertNoLinksBelow(_baseDir, target);
      // Two items can land on one name: paths that clean to the same thing,
      // or names that differ only in case on a volume that folds it. The file
      // is written straight into the staged folder with no partial of its own,
      // so opening it truncates whatever is there — the second item would
      // erase the first, and both would be counted as received. Looked at
      // without following links, like every other check here.
      final unique = SafePath.uniquePath(target);
      _targetPath = unique;
      return _newFile(unique, staged: false);
    }
    _targetPath =
        SafePath.uniquePath(resolveTargetPath(manifestPath, _baseDir));
    return _newFile(_targetPath!, staged: true);
  }

  DurableFile _newFile(String path, {required bool staged}) =>
      debugFileFactory?.call(path, staged: staged, base: _baseDir) ??
      DurableFile(path, staged: staged, base: _baseDir);

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
  Future<void> _discardInFlight() => _discarding ??=
      _discardNow().whenComplete(() => _discarding = null);

  /// The discard in progress, so that a second caller — [cancel] while a
  /// failure is still putting the file down, say — waits for the same work
  /// instead of racing it: two closes of one handle, two deletes of one path.
  Future<void>? _discarding;

  Future<void> _discardNow() async {
    // Taken out of the way first. Anything that looks for the open file while
    // it is being closed finds none, rather than a handle that is shutting.
    final file = _currentFile;
    _currentFile = null;
    await file?.abort();
    if (_folderMode && _stagedRoot != null) {
      if (_keptStagedRoot == _stagedRoot) {
        // Complete, and the only copy: see [_keptStagedRoot].
        return;
      }
      await _discardStagedRoot(_stagedRoot!);
    } else if (_targetPath != null) {
      // Not `File(...).existsSync()` and `delete()`: both follow a link in any
      // folder above the file, and a folder swapped for one while the transfer
      // ran made this remove a same-named file from wherever it pointed.
      SafePath.discard(_baseDir, '$_targetPath$kPartialSuffix');
    }
  }

  /// Removes the staging folder of a folder session that did not finish.
  ///
  /// Looked at without following links, and every folder between the
  /// destination and it checked first. A link standing where the staging folder
  /// was is removed as a link, and nothing is deleted through it; a folder
  /// inside the staging folder that became a link is unlinked by the recursive
  /// delete, not entered. When the chain above it is not what it should be the
  /// folder stays and the log says why — it is debris, and stays until the
  /// startup sweep (which does not enter a link either) or the person removes
  /// it.
  ///
  /// Never throws: the failure being reported is the one the person sees.
  Future<void> _discardStagedRoot(String staged) async {
    try {
      SafePath.assertNoLinksBelow(
          _baseDir.isEmpty ? p.dirname(staged) : _baseDir, staged);
      final type = FileSystemEntity.typeSync(staged, followLinks: false);
      if (type == FileSystemEntityType.link) {
        await Link(staged).delete();
      } else if (type == FileSystemEntityType.directory) {
        await Directory(staged).delete(recursive: true);
      }
    } on UnsafePathException catch (e) {
      AppLogger.warning(
          'Left the staging folder "$staged" in place instead of deleting '
          'it: ${e.reason}. Nothing outside the destination was touched',
          tag: 'DISK');
    } catch (e) {
      AppLogger.warning(
          'Could not remove the staging folder "$staged": $e — it stays '
          'where it is',
          tag: 'DISK');
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
  ///
  /// The length is checked against the manifest before `commit()` renames the
  /// partial into place. QHTP verifies every item this way; this channel only
  /// checked the session total at the end, so a file truncated in the middle
  /// of a folder — a `file-end` that arrived early, a channel that dropped a
  /// chunk — landed under its real name and nothing downstream knew it was
  /// short.
  Future<void> _sealCurrentFile() async {
    final file = _currentFile;
    _currentFile = null;
    final expected = _currentItemExpectedBytes;
    _currentItemExpectedBytes = -1;
    if (file == null) return;

    if (expected >= 0 && file.length != expected) {
      // Discard the partial rather than rename it: half a file under the
      // right name is worse than no file, because nobody goes looking for
      // what is missing.
      final short = file.length;
      await file.abort();
      _fail('"${p.basename(file.finalPath)}" arrived with $short of '
          '$expected bytes');
      return;
    }

    final path = await file.commit();
    if (!_writtenPaths.contains(path)) _writtenPaths.add(path);
    if (_currentItemIndex >= 0) _sealedItems.add(_currentItemIndex);
  }

  /// Whether every item the manifest announced has been sealed.
  bool get _everyItemSealed =>
      _manifest.isNotEmpty && _sealedItems.length == _manifest.length;

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
      // A short final item fails inside the seal. Nothing below should run:
      // no folder commit, no "completed", no successful completion.
      if (_ended) return;
      // The bytes add up; that is not the same as every item being here. An
      // item that was skipped, or one that was replaced before it was sealed,
      // is a hole the running total can paper over.
      if (!_everyItemSealed) {
        final missing = [
          for (var i = 0; i < _manifest.length; i++)
            if (!_sealedItems.contains(i)) i,
        ];
        _fail(missing.isEmpty
            ? 'the session ended without announcing any item'
            : '${missing.length} of ${_manifest.length} items never arrived '
                'complete (first: "${_manifest[missing.first].path}")');
        return;
      }
      if (!await _commitFolderIfStaged()) return;
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

  /// How long to wait between attempts at the rename onto the real name. The
  /// first failure is often not the last word: antivirus and the indexer hold
  /// a freshly written tree open for a moment on Windows, and a rename of a
  /// folder with open files in it is refused for exactly that moment.
  static const List<Duration> _commitRetryDelays = [
    Duration(milliseconds: 200),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
  ];

  /// Renames a staged folder onto its real name in one atomic step, once every
  /// file inside it is on disk. The session result then points at the folder,
  /// not at some photo three levels down inside it.
  ///
  /// Never replaces: a folder (even an empty one), file or link that took the
  /// name while the transfer ran leaves the session's folder to land as
  /// `Name (1)`. Returns false when the commit failed and the session has been
  /// failed with it — a folder that was not committed is not "received".
  ///
  /// A failure is not the end of the folder. Every file in it is whole, and it
  /// is the only copy: the rename is tried again after a short wait, and if it
  /// still fails the folder is kept where it is — marked so the startup sweep
  /// leaves it alone — and the failure names the path, so the person can
  /// recover it by hand.
  Future<bool> _commitFolderIfStaged() async {
    if (!_folderMode || _stagedRoot == null || _finalRoot == null) return true;
    Object? failure;
    for (var attempt = 0; attempt <= _commitRetryDelays.length; attempt++) {
      try {
        final landed =
            await commitDirectory(_stagedRoot!, _finalRoot!, base: _baseDir);
        _finalRoot = landed;
        _writtenPaths
          ..clear()
          ..add(landed);
        return true;
      } catch (e) {
        failure = e;
        // Only an operating-system refusal can be transient. A link in the
        // chain or a name that cannot be had will not change by waiting.
        if (e is! FileSystemException || attempt == _commitRetryDelays.length) {
          break;
        }
        AppLogger.warning(
            'Could not commit the received folder "$_finalRoot" '
            '(attempt ${attempt + 1}): $e; trying again',
            tag: 'WEBRTC_RECEIVER');
        await Future<void>.delayed(_commitRetryDelays[attempt]);
      }
    }

    final staged = _stagedRoot!;
    _keptStagedRoot = staged;
    _markKept(staged, failure);
    AppLogger.error(
        'Could not commit the received folder "$_finalRoot": $failure. It is '
        'complete and has been kept at "$staged"',
        tag: 'WEBRTC_RECEIVER');
    final problem = classifyStorageError(failure);
    final kept = 'The folder "${p.basename(_finalRoot!)}" was received in '
        'full but could not be saved under its name '
        '(${problem?.message ?? failure}). It was kept at "$staged" — '
        'rename it to keep it.';
    _fail(kept,
        problem: problem == null ? null : StorageProblem(kept, problem.code));
    return false;
  }

  /// Puts the mark that tells the startup sweep this `.qs.partial` folder is
  /// not debris. Written inside the folder: creating a file is far less likely
  /// to be refused than the rename that just was.
  void _markKept(String staged, Object? cause) {
    try {
      final marker = p.join(staged, kKeptMarker);
      // The chain is checked first: if the staging folder has been swapped for
      // a link, the mark would be written into whatever it points at.
      SafePath.assertNoLinksBelow(_baseDir, marker);
      SafePath.createExclusive(marker);
      File(marker).writeAsStringSync(
          'This folder was received in full but could not be renamed to '
          'its real name ($cause). Rename it to keep it, then delete this '
          'file.\n');
    } catch (e) {
      AppLogger.warning(
          'Could not mark "$staged" as kept; the startup sweep may remove it: '
          '$e',
          tag: 'WEBRTC_RECEIVER');
    }
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
        _iceEstablished = true;
        _connectDeadline.connected();
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
        } else if (!_iceEstablished) {
          // Never connected: not an interruption but an absent route, and the
          // useful thing to say is why there was no relay to fall back on.
          unawaited(_failNegotiation());
        } else {
          _fail('Peer connection failed (ICE $state)');
        }
      default:
        break;
    }
  }

  /// The connection never came up. Reads what is known about why — relay
  /// availability, what was gathered, which pair (if any) was chosen — before
  /// anything is torn down, and fails the session with it.
  Future<void> _failNegotiation() async {
    // `_completion` settled means the session already ended some other way —
    // the person cancelled, and closing the connection is what made ICE report
    // `closed` — and that is not a missing route.
    if (_negotiationFailing ||
        _ended ||
        _sessionFinished ||
        _cancelledBySender) {
      return;
    }
    _negotiationFailing = true;
    _connectDeadline.cancel();

    final diagnosis = await diagnoseNoPath(
      relayUnavailable: _relayUnavailable,
      gathering: _gathering,
      connection: _peerConnection,
    );
    AppLogger.error(diagnosis.summary, tag: 'WEBRTC_RECEIVER');
    if (_ended || _sessionFinished || _cancelledBySender) {
      return;
    }

    _iceFailure = IceNegotiationFailed(diagnosis);
    _fail(diagnosis.summary);
  }

  /// How long a failure waits for the file to be put down before it is
  /// reported anyway. Closing and deleting take milliseconds; they take long
  /// only on a destination that has stopped answering (a share that went
  /// away), and the person should still be told.
  static const Duration _discardGrace = Duration(seconds: 5);

  /// Ends the session with [reason].
  ///
  /// The failure reaches everyone who is waiting — the status stream, the
  /// progress stream, the completion — only once the file being written is
  /// closed and its partial is gone. Reporting first and cleaning up
  /// alongside it let the caller act on a destination that was still in use:
  /// on Windows a folder with an open file in it cannot be renamed or
  /// deleted, so whoever reacted to the failure by clearing the destination
  /// got a sharing violation, and a partial was left behind.
  void _fail(String reason, {StorageProblem? problem}) {
    if (_failed) {
      debugPrint('WebRTC receive failed again, after it already had: $reason');
      return;
    }
    _failed = true;
    debugPrint('WebRTC receive failed: $reason');
    if (problem != null) _storageFailure ??= problem.toException();
    // Decided now, not when the file is down: a later event must not change
    // what this failure was.
    final Object error = _cancelledBySender
        ? const TransferCancelledBySender()
        : _iceFailure ?? _storageFailure ?? Exception(reason);
    unawaited(_report(reason, error));
    _cleanup();
  }

  Future<void> _report(String reason, Object error) async {
    try {
      await _discardInFlight().timeout(_discardGrace);
    } catch (e) {
      AppLogger.warning(
          'The partial file was not put down before the failure was '
          'reported: $e',
          tag: 'WEBRTC_RECEIVER');
    }
    _statusController.add(TransferStatus.failed);
    _emit('failed', detail: reason);
    if (!_completion.isCompleted) _completion.completeError(error);
  }

  Future<void> _cleanup() async {
    _connectDeadline.cancel();
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
    _failed = true;
    await _discardInFlight();
    _statusController.add(TransferStatus.cancelled);
    if (!_completion.isCompleted) {
      _completion.completeError(Exception('Cancelled by user'));
    }
    await _cleanup();
  }

  @visibleForTesting
  Future<void> discardInFlightForTesting() => _discardInFlight();

  @visibleForTesting
  void setTargetPathForTesting(String? path) {
    _targetPath = path;
  }

  @visibleForTesting
  void setSessionFinishedForTesting(bool finished) {
    _sessionFinished = finished;
  }

  @visibleForTesting
  bool get isSessionFinishedForTesting => _sessionFinished;

  @visibleForTesting
  void handleMessageForTesting(RTCDataChannelMessage message) =>
      _processMessage(message);
}

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
import 'package:quickshare/core/webrtc/resume/item_digest.dart';
import 'package:quickshare/core/webrtc/resume/receiver_link.dart';
import 'package:quickshare/core/webrtc/resume/reconnect_policy.dart';
import 'package:quickshare/core/webrtc/resume/resume_signaling.dart';
import 'package:quickshare/core/webrtc/resume/webrtc_links.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/core/webrtc/transfer_stats_sampler.dart';
import 'package:quickshare/core/webrtc/turn_credential_refresher.dart';
import 'package:quickshare/core/signaling/code_mailbox_factory.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
import 'package:quickshare/core/errors/failures.dart';
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
    this.stall = const StallPolicy(),
    this.reconnectPolicy = const ReconnectPolicy(),
    this.completionGrace = const Duration(seconds: 30),
    this.debugLinkOpener,
    this.forceInlineDigest = false,
  }) : _diskSpace = diskSpace ?? DiskSpaceProbe.forCurrentPlatform();

  /// How long the connection may be silent before it is called dead; see
  /// [StallPolicy] for why these numbers.
  final StallPolicy stall;

  /// How hard a dead connection is waited out; see [ReconnectPolicy].
  final ReconnectPolicy reconnectPolicy;

  /// After a transfer is complete the receiver stays reachable this long, so
  /// that a sender that never heard `done` can find it and be told. The
  /// transfer is reported complete at once; only the listening goes on.
  final Duration completionGrace;

  /// Test seam: answers an offer for a replacement link without a real peer
  /// connection. Null in production.
  @visibleForTesting
  final ReceiverLinkOpener? debugLinkOpener;

  /// Hashes in the calling isolate whatever the size (a test under a fake
  /// clock never gets a worker's reply).
  @visibleForTesting
  final bool forceInlineDigest;

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
  DateTime _lastProgressReport = DateTime.now().subtract(_progressInterval);

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

  /// What a sender that cannot resume is given before it is written off: it
  /// has no way to say it is still there except by sending.
  static const _idleTimeout = Duration(seconds: 30);

  // ─── Reconnection ──────────────────────────────────────────────────────

  /// What the sender said it speaks: 1 for every build that predates
  /// reconnection (which cannot resume and is spoken to as it always was), 2
  /// from a manifest that names a session.
  int _peerVersion = 1;

  /// The session the manifest opened, as the sender named it.
  String? _sid;

  ResumeSetup? _resumeSetup;
  ResumeReceiverSignaling? _signaling;
  StreamSubscription<ResumeOffer>? _offers;
  WebRtcReceiverLink? _firstLink;

  /// The link bytes are being taken from, and the number frames must carry to
  /// be believed: a frame from a link that has been replaced is the old
  /// connection's, and the sender will send it again on the new one.
  ReceiverLink? _link;
  int _linkId = 0;
  int _linkGeneration = 0;

  /// New arrivals from the current link are being turned away while a
  /// replacement is made ready, so that what the receiver reports as held is
  /// exactly what it holds.
  bool _quiescing = false;

  /// Quiet for [StallPolicy.suspectAfter]: listening for an offer, not yet
  /// calling the connection dead.
  bool _suspect = false;

  /// The connection is dead and a replacement is awaited.
  bool _reconnecting = false;
  IdleWatchdog? _suspectWatchdog;
  Timer? _pingTimer;
  Timer? _waitForSenderTimer;
  ResumeOffer? _pendingOffer;
  bool _handlingOffer = false;
  bool _cleanedUp = false;
  final Completer<void> _shutdown = Completer<void>();
  final Map<int, IceSetup> _replacementIceSetups = {};
  Completer<void>? _newerOffer;
  late final ReconnectLedger _ledger = ReconnectLedger(reconnectPolicy);

  /// The SHA-256 of the item now open, over what has been written to it, and
  /// the one the sender says the original has.
  ItemDigest? _digest;
  String? _expectedSha;

  /// Set when a failure carries a [FailureCode] the screen says in the
  /// person's language.
  NetworkException? _codedFailure;

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

  Future<IceSetup> _buildIceConfiguration() =>
      IceServers.configurationDynamic();

  /// Starts the TURN credential refresh timer (§9).
  Future<void> _startTurnRefresher({DateTime? expiresAt}) async {
    _turnRefresher?.cancel();
    _turnRefresher = null;
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
    ResumeSetup? resume,
  }) async {
    try {
      _resumeSetup = resume;
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
      final firstConnection = await createPeerConnection(ice);
      _peerConnection = firstConnection;
      await _startTurnRefresher(); // §9

      firstConnection.onDataChannel = (RTCDataChannel channel) {
        if (_cleanedUp || !identical(_peerConnection, firstConnection)) {
          unawaited(channel.close());
          return;
        }
        debugPrint('WebRTC receiver serverless: data channel received');
        _dataChannel = channel;
        final link = WebRtcReceiverLink(
          generation: 1,
          connection: firstConnection,
          channel: channel,
          stall: stall,
        );
        _firstLink = link;
        _adoptLink(link);
      };

      // The answer is sealed and published once; like the offer, it has no
      // trickle path, so gathering has to finish before it is encoded.
      _peerConnection!.onIceCandidate = _gathering.observe;

      // This path previously had no ICE-state reaction whatsoever — a dead
      // connection here produced no error until the flat 120s timeout further
      // down expired, and that timeout counted the whole transfer, not just
      // the time since the connection actually died.
      firstConnection.onIceConnectionState = (state) {
        if (identical(_peerConnection, firstConnection)) {
          _onIceStateChanged(state);
        }
      };

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
                    _codedFailure ??
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

  void _handleMessage(RTCDataChannelMessage message, {int? linkId}) {
    // A frame from a link that has since been replaced is the old
    // connection's: the sender will send what it carried again on the new one.
    if (linkId != null && (linkId != _linkId || _quiescing)) return;
    _noteLife();
    _handlerChain =
        _handlerChain.then((_) => _processMessage(message, linkId: linkId));
  }

  /// Anything at all arriving from the current link is proof that it is alive:
  /// the silence clocks start again, and a connection that was being given up
  /// on is taken back.
  void _noteLife() {
    _idleWatchdog?.kick();
    _suspectWatchdog?.kick();
    if (_reconnecting || _suspect) {
      final wasReconnecting = _reconnecting;
      _reconnecting = false;
      _suspect = false;
      _waitForSenderTimer?.cancel();
      _waitForSenderTimer = null;
      if (wasReconnecting) {
        _ledger.recovered();
        AppLogger.info('Receiver: the connection came back by itself',
            tag: 'WEBRTC_RECEIVER');
        _statusController.add(TransferStatus.transferring);
        _emit('transferring');
      }
    }
  }

  /// Feeds one frame the way `onMessage` would, and resolves when the handler
  /// chain has drained it. The chained model means a caller cannot otherwise
  /// know when a message has finished being processed.
  @visibleForTesting
  Future<void> deliverForTest(RTCDataChannelMessage message,
      {String? baseDir}) {
    if (baseDir != null) _baseDir = baseDir;
    _handleMessage(message);
    return _handlerChain;
  }

  /// The completion future the real receive path returns, so a test can see
  /// how it settles without standing up a peer connection.
  @visibleForTesting
  Future<String> get completionForTest => _completion.future;

  /// Exercises the same link, signaling and file handlers without native ICE.
  @visibleForTesting
  void attachLinkForTest(ReceiverLink link,
      {required String baseDir, required ResumeSetup resume}) {
    _baseDir = baseDir;
    _resumeSetup = resume;
    _adoptLink(link);
  }

  /// §8 — handles incoming DataChannel messages.
  ///
  /// Binary messages are decompressed if the sender advertised
  /// `"compressed": true` in the `file-meta` JSON.
  Future<void> _processMessage(RTCDataChannelMessage message,
      {int? linkId}) async {
    // Whatever was queued behind a failure belongs to a session that is being
    // taken apart. Handling it is not harmless: a `file-end` would try to seal
    // the very file that is being closed and deleted, and what that raised
    // was then reported as a second, unrelated failure.
    if (_failed) return;
    if (linkId != null && linkId != _linkId) return;
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

        await _currentFile!.add(bytes);
        await _digest?.add(bytes);
        _currentItemReceived += bytes.length;
        _ledger.moved(bytes.length);
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

      if (type == TransferProtocol.bye) {
        // The sender has heard `done` and is leaving: nothing more will come,
        // and there is no reason to stay reachable.
        if (_sessionFinished && !_failed) {
          _teardownTimer?.cancel();
          _teardownTimer = null;
          unawaited(_cleanup());
        }
        return;
      }
      if (_sessionFinished && type != TransferProtocol.complete) {
        return;
      }

      switch (type) {
        case TransferProtocol.ping:
          break;

        case TransferProtocol.resume:
          _checkResume(data);

        case TransferProtocol.manifest:
          if (!_acceptSessionHeader(data)) return;
          await _openSession(TransferProtocol.parseManifest(data));

        case TransferProtocol.manifestBegin:
          if (!_acceptSessionHeader(data)) return;
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
          if (pending.length + parsed.length > AppConstants.qhtpMaxFileCount) {
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
          final offset = data['offset'] is int ? data['offset'] as int : 0;
          // The item that was open when the link died, continued on the new
          // one: the file, its digest and the count are all as they were, and
          // the sender has been told exactly how far they got.
          if (_currentFile != null &&
              _peerVersion >= 2 &&
              index == _currentItemIndex &&
              offset == _currentItemReceived) {
            _emit('transferring');
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
          if (offset != 0) {
            _fail('file-start asked to continue item $index at byte $offset, '
                'but no partial of it is open here');
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
          _expectedSha = null;
          _currentFile = _openIncoming(item.path);
          await _currentFile!.open();
          _digest = _peerVersion >= 2
              ? await ItemDigest.start(item.size,
                  forceInline: forceInlineDigest)
              : null;
          _lastProgressReport = DateTime.now().subtract(_progressInterval);
          _emit('transferring');

        case TransferProtocol.fileEnd:
          final claimed = data['sha256'];
          _expectedSha = claimed is String ? claimed.toLowerCase() : null;
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
              _sessionReceivedBytes >= _sessionTotalBytes &&
              _everyItemSealed) {
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
          _lastProgressReport = DateTime.now().subtract(_progressInterval);
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
          // A sender asking again after the session was finished has not
          // heard `done`: say it again.
          if (_sessionFinished) {
            if (_peerVersion >= 2) _sendDone(ok: true);
            return;
          }
          // A legacy sender closes the only file here rather than with
          // file-end, so flush whatever is still open.
          await _sealCurrentFile();
          if (_peerVersion < 2) _idleWatchdog?.cancel();
          if (_ended) return;

          if (_sessionTotalBytes > 0 &&
              _sessionReceivedBytes < _sessionTotalBytes) {
            _fail('Transfer completed prematurely: received '
                '$_sessionReceivedBytes of $_sessionTotalBytes bytes');
          } else {
            await _completeSession(holdConnection: _peerVersion >= 2);
          }
      }
    } catch (e) {
      final problem = classifyStorageError(e);
      _fail(problem?.message ?? 'Failed to write incoming file: $e',
          problem: problem);
    }
  }

  void _armIdleWatchdog() {
    final resumable = _peerVersion >= 2;
    _idleWatchdog ??= IdleWatchdog(
      timeout: resumable ? stall.receiveSilence : _idleTimeout,
      onTimeout: _onSilence,
    );
    _idleWatchdog!.kick();
    if (resumable) {
      _suspectWatchdog ??=
          IdleWatchdog(timeout: stall.suspectAfter, onTimeout: _onSuspect);
      _suspectWatchdog!.kick();
    }
  }

  /// Nothing has arrived for as long as the policy allows.
  void _onSilence() {
    if (_sessionFinished || _ended) return;
    if (_peerVersion >= 2) {
      _linkLost('nothing arrived for ${stall.receiveSilence.inSeconds}s');
    } else {
      _fail(
          'No data received for ${_idleTimeout.inSeconds}s — the '
          'connection appears to have died',
          code: FailureCode.connectionLostPeerTooOld);
    }
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
  Future<void> _discardInFlight() =>
      _discarding ??= _discardNow().whenComplete(() => _discarding = null);

  /// The discard in progress, so that a second caller — [cancel] while a
  /// failure is still putting the file down, say — waits for the same work
  /// instead of racing it: two closes of one handle, two deletes of one path.
  Future<void>? _discarding;

  Future<void> _discardNow() async {
    // Taken out of the way first. Anything that looks for the open file while
    // it is being closed finds none, rather than a handle that is shutting.
    final file = _currentFile;
    _currentFile = null;
    final digest = _digest;
    _digest = null;
    await digest?.abort();
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

    final digest = _digest;
    _digest = null;
    final claimed = _expectedSha;
    _expectedSha = null;

    if (expected >= 0 && file.length != expected) {
      // Discard the partial rather than rename it: half a file under the
      // right name is worse than no file, because nobody goes looking for
      // what is missing.
      final short = file.length;
      await digest?.abort();
      await file.abort();
      _fail('"${p.basename(file.finalPath)}" arrived with $short of '
          '$expected bytes');
      return;
    }

    // The right size is not the right file, least of all after a splice. The
    // sender took a SHA-256 of the whole original as it read it, and this end
    // took one of everything it wrote: the file is committed under its name
    // only if they are the same.
    if (digest != null) {
      final actual = await digest.finish();
      final name = p.basename(file.finalPath);
      if (claimed == null) {
        await file.abort();
        _fail('"$name" ended without the checksum the sender promised',
            code: FailureCode.integrityMismatch);
        return;
      }
      if (actual != claimed) {
        await file.abort();
        _fail(
            '"$name" does not match the checksum the sender took of the '
            'original (arrived as $actual, the sender had $claimed)',
            code: FailureCode.integrityMismatch);
        return;
      }
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
    final resumable = _peerVersion >= 2;
    if (!_sessionFinished) {
      _sessionFinished = true;
      _idleWatchdog?.cancel();
      _suspectWatchdog?.cancel();
      _waitForSenderTimer?.cancel();
      _waitForSenderTimer = null;
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
      // Said only now, when every item has been checked and is in place. A
      // sender that is told this has nothing left to wonder about.
      if (resumable) _sendDone(ok: true);
    }
    if (resumable) {
      // Reachable for a while longer. If `done` is lost on a dying link the
      // sender will look for this device again, and must be told.
      unawaited(_ensureSignaling());
      _teardownTimer ??= Timer(completionGrace, () => unawaited(_cleanup()));
      return;
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

  // ─── Links, and getting one back ───────────────────────────────────────

  /// Takes [link] as the one frames come from, tells the sender what is held
  /// here, and lets the link it replaces go.
  void _adoptLink(ReceiverLink link) {
    final previous = _link;
    if (link is WebRtcReceiverLink &&
        !identical(_peerConnection, link.connection)) {
      _peerConnection = link.connection;
      _dataChannel = link.channel;
      _relayUnavailable =
          _replacementIceSetups.remove(link.generation)?.relayUnavailable;
      _statsProbe?.stop();
      _statsProbe = null;
      unawaited(_startTurnRefresher());
      _startStatsProbe();
      unawaited(_recordSelectedPath());
    }
    final id = ++_linkId;
    _link = link;
    _linkGeneration = link.generation;
    _quiescing = false;
    link.bind(
      onFrame: (m) => _handleMessage(m, linkId: id),
      // A close event can follow a manifest or file-end already delivered to
      // Dart while that frame is still being written. Decide what was received
      // only after the ordered message handlers have finished.
      onClosed: (reason) {
        _handlerChain = _handlerChain.then((_) => _onLinkClosed(id, reason));
      },
    );
    link.sendText(_helloFrame(link.generation));
    // A sender that is asking after the session was finished is told at once.
    if (_sessionFinished && !_failed && _peerVersion >= 2) {
      link.sendText(TransferProtocol.buildDone(ok: true));
    }
    _startPings();
    if (previous != null && !identical(previous, link)) {
      unawaited(previous.close());
    }
  }

  /// The first item that is not whole here. Items are sealed in order, so
  /// this is also how many are.
  int _firstUnsealed() {
    var i = 0;
    while (_sealedItems.contains(i)) {
      i++;
    }
    return i;
  }

  /// How far into the first unsealed item the file on disk goes.
  int _heldOfNext() {
    final next = _firstUnsealed();
    return _currentFile != null && _currentItemIndex == next
        ? _currentItemReceived
        : 0;
  }

  /// The receiver's first word on a link: what it holds, so that the sender
  /// can go on from exactly there.
  String _helloFrame(int generation) => TransferProtocol.buildHello(
        generation: generation,
        sessionId: _manifest.isEmpty ? null : _sid,
        next: _manifest.isEmpty ? 0 : _firstUnsealed(),
        offset: _manifest.isEmpty ? 0 : _heldOfNext(),
      );

  void _sendDone({required bool ok, String? code}) {
    try {
      _link?.sendText(TransferProtocol.buildDone(ok: ok, code: code));
    } catch (_) {}
  }

  void _startPings() {
    _pingTimer ??= Timer.periodic(stall.pingEvery, (_) {
      final link = _link;
      if (_peerVersion < 2 || link == null || !link.isOpen || _failed) return;
      link.sendText(TransferProtocol.buildPing());
    });
  }

  /// What a manifest says about its sender. False when the frame is not to be
  /// acted on: the same session announced again.
  bool _acceptSessionHeader(Map<String, dynamic> data) {
    final session = TransferProtocol.sessionOf(data);
    if (_manifest.isNotEmpty) {
      if (session.sessionId != null && session.sessionId == _sid) return false;
      _fail('a second manifest arrived for a session that is already open');
      return false;
    }
    // Nothing is open yet, so a manifest again (the link died before the first
    // finished, and the sender began again) simply starts over.
    _partialManifest = null;
    _peerVersion = session.version >= 2 && session.sessionId != null ? 2 : 1;
    _sid = session.sessionId;
    return true;
  }

  /// The sender's answer to a `hello` on a replacement link: where it will
  /// continue. It has to be where this end said it was.
  void _checkResume(Map<String, dynamic> data) {
    final next = data['next'];
    final offset = data['offset'];
    if (data['sid'] != _sid ||
        next is! int ||
        offset is! int ||
        next != _firstUnsealed() ||
        offset != _heldOfNext()) {
      _fail(
          'the sender asked to resume at item $next, byte $offset, but this '
          'device holds item ${_firstUnsealed()}, byte ${_heldOfNext()}',
          code: FailureCode.connectionLostNotRecovered);
      return;
    }
    _emit('transferring');
  }

  void _onLinkClosed(int id, String reason) {
    if (id != _linkId || _failed || _sessionFinished || _cancelledBySender) {
      return;
    }
    // A dead peer with every announced byte already on disk is a finished
    // transfer, not a failed one: a sender that cannot resume closes as soon
    // as its last frame leaves, which can win the race against its `complete`
    // frame.
    if (_peerVersion < 2 &&
        _sessionTotalBytes > 0 &&
        _sessionReceivedBytes >= _sessionTotalBytes) {
      unawaited(_completeSession());
      return;
    }
    _linkLost(reason);
  }

  /// The connection is dead. A sender that can resume is waited for; one that
  /// cannot is not, and the failure says so.
  void _linkLost(String reason) {
    if (_failed || _sessionFinished || _cancelledBySender) return;
    if (_peerVersion < 2 || _sid == null) {
      _fail('Peer connection failed ($reason)',
          code: _manifest.isNotEmpty
              ? FailureCode.connectionLostPeerTooOld
              : null);
      return;
    }
    if (_reconnecting) return;
    _reconnecting = true;
    _suspect = true;
    _ledger.lost();
    AppLogger.warning(
        'Receiver: the connection is lost ($reason); waiting '
        'for the sender to reconnect',
        tag: 'WEBRTC_RECEIVER');
    _idleWatchdog?.cancel();
    _suspectWatchdog?.cancel();
    _statusController.add(TransferStatus.reconnecting);
    _emit('reconnecting', detail: reason);
    unawaited(_ensureSignaling());
    _armWaitForSender();
  }

  /// How long the receiver waits for a sender to come back: as long as the
  /// sender's own attempts can take, and no longer than the budget has left.
  void _armWaitForSender() {
    _waitForSenderTimer?.cancel();
    final theirs =
        reconnectPolicy.attemptTimeout * reconnectPolicy.maxAttempts +
            const Duration(seconds: 30);
    final left = reconnectPolicy.totalBudget - _ledger.spent;
    final wait = left < theirs ? left : theirs;
    _waitForSenderTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (!_reconnecting || _failed || _sessionFinished) return;
      _fail(
          'The connection was lost and the sender did not reconnect within '
          '${wait.inSeconds}s',
          code: FailureCode.connectionLostNotRecovered);
    });
  }

  /// Quiet for a while: listen for an offer, in case the sender noticed first.
  void _onSuspect() {
    if (_peerVersion < 2 || _sessionFinished || _failed) return;
    _suspect = true;
    unawaited(_ensureSignaling());
  }

  /// Starts listening for the sender's offers. Tried again every few seconds
  /// while it is needed: the public mailbox may be out of reach for a minute
  /// behind the same tunnel that just dropped the connection.
  Future<void> _ensureSignaling() async {
    final setup = _resumeSetup;
    if (_signaling != null || setup == null || _failed || _cleanedUp) return;
    ResumeReceiverSignaling? signaling;
    try {
      signaling = ResumeReceiverSignaling(
        mailbox: (setup.mailboxFactory ?? buildCodeMailbox)(),
        keys: setup.keys,
      );
      _signaling = signaling;
      signaling.startFrom(_linkGeneration);
      _offers = signaling.offers.listen(_onOffer);
      await signaling.open();
      if (_cleanedUp) {
        await signaling.close();
        return;
      }
      AppLogger.info('Receiver: listening for a reconnection offer',
          tag: 'WEBRTC_RECEIVER');
    } catch (e) {
      AppLogger.warning(
          'Receiver: the mailbox is out of reach (${e.runtimeType}); will '
          'try again',
          tag: 'WEBRTC_RECEIVER');
      if (identical(_signaling, signaling)) {
        _signaling = null;
        unawaited(_offers?.cancel());
        _offers = null;
      }
      await signaling?.close();
      await Future.any<void>([
        Future<void>.delayed(const Duration(seconds: 5)),
        _shutdown.future,
      ]);
      if (!_failed &&
          !_cleanedUp &&
          (_reconnecting || _suspect || _sessionFinished)) {
        unawaited(_ensureSignaling());
      }
    }
  }

  void _onOffer(ResumeOffer offer) {
    if (_failed || _cleanedUp || _peerVersion < 2) return;
    _pendingOffer = offer;
    // A newer offer means the sender gave up on the attempt it was making.
    final newer = _newerOffer;
    if (newer != null && !newer.isCompleted) newer.complete();
    if (!_handlingOffer) unawaited(_drainOffers());
  }

  Future<void> _drainOffers() async {
    _handlingOffer = true;
    try {
      while (_pendingOffer != null && !_failed) {
        final offer = _pendingOffer!;
        _pendingOffer = null;
        await _acceptOffer(offer);
      }
    } finally {
      _handlingOffer = false;
    }
  }

  /// Answers an authenticated offer for a replacement link and, when the
  /// channel on it opens, makes it the link frames are taken from.
  ///
  /// Everything that had already arrived on the old link is handled first and
  /// put on the device, so that what is reported as held is exactly what is
  /// held. Frames that arrive on the old link after that are turned away; the
  /// sender sends them again on the new one.
  Future<void> _acceptOffer(ResumeOffer offer) async {
    final counted = !_sessionFinished;
    if (counted) {
      if (_ledger.isReconnecting == false) _ledger.lost();
      final over = _ledger.exhausted;
      if (over != null) {
        _fail('The reconnection limit was reached (${over.name})',
            code: FailureCode.connectionLostNotRecovered);
        return;
      }
      _ledger.startAttempt();
    }
    AppLogger.info('Receiver: an offer for link ${offer.generation}',
        tag: 'WEBRTC_RECEIVER');
    final newer = _newerOffer = Completer<void>();
    final abort = Completer<void>();
    void abortAttempt() {
      if (!abort.isCompleted) abort.complete();
    }

    unawaited(newer.future.then((_) => abortAttempt()));
    unawaited(_shutdown.future.then((_) => abortAttempt()));
    final timeout = Timer(reconnectPolicy.attemptTimeout, abortAttempt);
    Future<T> interrupted<T>() => abort.future.then<T>(
        (_) => throw StateError('the reconnection attempt was interrupted'));
    _quiescing = true;
    ReceiverLinkAttempt? attempt;
    Future<ReceiverLinkAttempt>? opening;
    ResumeAnswerPublication? publication;
    var adopted = false;
    void abandonLater(Future<void> Function() abandon) {
      unawaited(Future<void>.sync(abandon).catchError((Object _) {}));
    }

    try {
      await _handlerChain;
      await _currentFile?.sync();
      if (abort.isCompleted) throw StateError('attempt interrupted');
      opening = debugLinkOpener != null
          ? debugLinkOpener!(offer)
          : _openWebRtcReplacement(offer, abort.future);
      final openedAttempt = await Future.any<ReceiverLinkAttempt>(
          [opening, interrupted<ReceiverLinkAttempt>()]);
      attempt = openedAttempt;
      final signaling = _signaling;
      if (signaling == null) throw StateError('the mailbox was closed');
      publication = signaling.answer(
        generation: offer.generation,
        answerSdp: openedAttempt.answerSdp,
        forAtMost: reconnectPolicy.attemptTimeout,
      );
      final link = await Future.any<ReceiverLink>([
        openedAttempt.ready,
        interrupted<ReceiverLink>(),
      ]);
      publication.stop();
      if (_failed || _cleanedUp) {
        await link.close();
        return;
      }
      _waitForSenderTimer?.cancel();
      _waitForSenderTimer = null;
      final wasReconnecting = _reconnecting || _suspect;
      _reconnecting = false;
      _suspect = false;
      _adoptLink(link);
      adopted = true;
      if (counted && wasReconnecting) _ledger.recovered();
      _lastBytes = _sessionReceivedBytes;
      _lastTick = DateTime.now();
      if (_manifest.isNotEmpty && !_sessionFinished) {
        _armIdleWatchdog();
        _statusController.add(TransferStatus.transferring);
        _emit('transferring');
      }
      AppLogger.info('Receiver: link ${offer.generation} is up',
          tag: 'WEBRTC_RECEIVER');
    } catch (e) {
      AppLogger.warning(
          'Receiver: the attempt for link ${offer.generation} failed: $e',
          tag: 'WEBRTC_RECEIVER');
      publication?.stop();
      if (attempt != null) {
        abandonLater(attempt.abandon);
      } else if (opening != null) {
        unawaited(opening.then((lateAttempt) {
          abandonLater(lateAttempt.abandon);
        }, onError: (Object _) {}));
      }
      // The old link, if it comes back by itself, is taken again.
      _quiescing = false;
    } finally {
      timeout.cancel();
      if (!adopted) abortAttempt();
      _replacementIceSetups.remove(offer.generation);
      if (identical(_newerOffer, newer)) _newerOffer = null;
    }
  }

  /// Production: a new peer connection that answers [offer].
  Future<ReceiverLinkAttempt> _openWebRtcReplacement(
      ResumeOffer offer, Future<void> abort) async {
    var aborted = false;
    Future<void> Function()? closePending;
    unawaited(abort.then((_) {
      aborted = true;
      final close = closePending;
      if (close != null) unawaited(close());
    }));
    void checkAbort() {
      if (aborted || _cleanedUp) throw StateError('attempt interrupted');
    }

    final setup = await _buildIceConfiguration();
    checkAbort();
    final ice = setup.configuration;
    final connection = await createPeerConnection(ice);
    Future<void>? closing;
    Future<void> closeConnection() =>
        closing ??= connection.close().catchError((Object _) {});
    closePending = closeConnection;
    final gathering = IceGatheringTracker();
    final ready = Completer<ReceiverLink>();
    unawaited(ready.future.then((_) {}, onError: (Object _) {}));
    WebRtcReceiverLink? link;
    connection.onIceCandidate = gathering.observe;
    connection.onIceConnectionState = (state) => link?.iceState(state);
    connection.onDataChannel = (channel) {
      final made = WebRtcReceiverLink(
        generation: offer.generation,
        connection: connection,
        channel: channel,
        stall: stall,
      );
      link = made;
      made.opened.then((_) {
        if (!ready.isCompleted) ready.complete(made);
      }, onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
      });
    };
    try {
      checkAbort();
      await connection.setRemoteDescription(RTCSessionDescription(
          CompactSdp.fromBytes(offer.sdp).toSdp(isOffer: true), 'offer'));
      checkAbort();
      final answer = await connection.createAnswer();
      checkAbort();
      await connection.setLocalDescription(answer);
      checkAbort();
      await waitForUsableCandidates(connection, gathering,
          expectingRelay: IceServers.containsTurn(ice), tag: 'WEBRTC_RECEIVER');
      checkAbort();
      final local = await connection.getLocalDescription();
      checkAbort();
      final sdp = local?.sdp ?? answer.sdp;
      if (sdp == null || sdp.isEmpty) {
        throw StateError('WebRTC produced no answer');
      }
      _replacementIceSetups[offer.generation] = setup;
      closePending = null;
      return ReceiverLinkAttempt(
        answerSdp: ServerlessQr.trimForQr(CompactSdp.fromSdp(sdp)).toBytes(),
        ready: ready.future,
        abandon: () async {
          if (link != null) {
            await link!.close();
          } else {
            await connection.close();
          }
        },
      );
    } catch (_) {
      await closeConnection();
      rethrow;
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
        _firstLink?.iceState(state);
        _startStatsProbe();
        unawaited(_recordSelectedPath());
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        // Once the connection has been up, what ICE says about it is the
        // link's to weigh (see [WebRtcReceiverLink]): `disconnected` is a
        // grace, not a verdict.
        if (_iceEstablished) _firstLink?.iceState(state);
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        if (_iceEstablished) {
          _firstLink?.iceState(state);
        } else {
          // Never connected: not an interruption but an absent route, and the
          // useful thing to say is why there was no relay to fall back on.
          unawaited(_failNegotiation());
        }
      default:
        break;
    }
  }

  /// How the last session's bytes travelled, and the candidate types on each
  /// end of the pair that carried them — `local=relay remote=srflx` — as this
  /// side saw them. The receiver's half of what the sender keeps as
  /// `lastIcePath`; null until ICE has come up.
  IcePathKind? lastIcePath;
  String? lastIcePair;
  bool _readingPath = false;
  TransferStatsSampler? _statsProbe;

  void _startStatsProbe() {
    final connection = _peerConnection;
    if (!kDebugMode ||
        !AppConstants.statsProbe ||
        connection == null ||
        _statsProbe != null) {
      return;
    }
    _statsProbe = TransferStatsSampler(
      label: 'receiver',
      connection: connection,
      withLivenessProbe: true,
      extra: () => {'received_session': _sessionReceivedBytes},
    )..start();
  }

  /// Reads the chosen pair once ICE is up, and again when it settles. Only
  /// reads and remembers: nothing here decides anything about the transfer.
  Future<void> _recordSelectedPath() async {
    final connection = _peerConnection;
    if (connection == null || _readingPath) return;
    _readingPath = true;
    try {
      final path = await selectedPathKind(connection);
      final pair = await selectedPairDescription(connection);
      if (!identical(connection, _peerConnection)) return;
      // A read that finds no pair — the connection is already going away —
      // must not erase one that did.
      if (path == IcePathKind.unknown && lastIcePath != null) return;
      lastIcePath = path;
      lastIcePair = pair;
      AppLogger.info('Receiver selected path: ${path.name} ($pair)',
          tag: 'WEBRTC_RECEIVER');
    } finally {
      _readingPath = false;
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
  void _fail(String reason, {StorageProblem? problem, String? code}) {
    if (_failed) {
      debugPrint('WebRTC receive failed again, after it already had: $reason');
      return;
    }
    _failed = true;
    debugPrint('WebRTC receive failed: $reason');
    if (problem != null) _storageFailure ??= problem.toException();
    if (code != null && problem == null) {
      _codedFailure ??= NetworkException(reason, code);
    }
    // Decided now, not when the file is down: a later event must not change
    // what this failure was.
    final Object error = _cancelledBySender
        ? const TransferCancelledBySender()
        : _iceFailure ?? _storageFailure ?? _codedFailure ?? Exception(reason);
    unawaited(_report(reason, error));

    // The sender is told why it is not getting a `done`, so that it does not
    // spend minutes looking for a receiver that has deliberately stopped. The
    // channel is kept a moment so that the frame can leave.
    var told = false;
    if (_peerVersion >= 2 && !_cancelledBySender && (_link?.isOpen ?? false)) {
      final wire = code == FailureCode.integrityMismatch
          ? 'integrity'
          : problem != null
              ? 'disk'
              : 'error';
      _sendDone(ok: false, code: wire);
      told = true;
    }
    if (told) {
      unawaited(Future<void>.delayed(const Duration(milliseconds: 400))
          .then((_) => _cleanup()));
    } else {
      _cleanup();
    }
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
    if (_cleanedUp) return;
    _cleanedUp = true;
    if (!_shutdown.isCompleted) _shutdown.complete();
    _connectDeadline.cancel();
    _idleWatchdog?.cancel();
    _suspectWatchdog?.cancel();
    _pingTimer?.cancel();
    _pingTimer = null;
    _waitForSenderTimer?.cancel();
    _waitForSenderTimer = null;
    _teardownTimer?.cancel();
    _teardownTimer = null;
    _statsProbe?.stop();
    _statsProbe = null;
    _turnRefresher?.cancel(); // §9
    _turnRefresher = null;
    unawaited(_offers?.cancel());
    _offers = null;
    final signaling = _signaling;
    _signaling = null;
    unawaited(signaling?.close());
    await _wakelockGuard.release(); // §6
    final link = _link;
    _link = null;
    await link?.close();
    if (link is! WebRtcReceiverLink || !identical(link.channel, _dataChannel)) {
      await _dataChannel?.close();
    }
    _dataChannel = null;
    if (link is! WebRtcReceiverLink ||
        !identical(link.connection, _peerConnection)) {
      await _peerConnection?.close();
    }
    _peerConnection = null;
  }

  Future<void> cancel() async {
    // Tell the sender before anything is torn down, so that it stops at once
    // instead of spending minutes looking for a receiver that has left.
    final link = _link;
    if (!_failed && link != null && link.isOpen) {
      link.sendText(TransferProtocol.buildCancelled());
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
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

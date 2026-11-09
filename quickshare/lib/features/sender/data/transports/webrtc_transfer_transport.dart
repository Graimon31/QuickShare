import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/mime_compression.dart';
import 'package:quickshare/core/utils/wakelock_guard.dart';
import 'package:quickshare/core/webrtc/ice_connect_deadline.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
import 'package:quickshare/core/webrtc/resume/receiver_link.dart';
import 'package:quickshare/core/webrtc/resume/resumable_sender.dart';
import 'package:quickshare/core/webrtc/resume/resume_signaling.dart';
import 'package:quickshare/core/webrtc/resume/webrtc_links.dart';
import 'package:quickshare/core/signaling/code_mailbox_factory.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';
import 'package:quickshare/core/webrtc/relay_availability.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/core/webrtc/transfer_stats_sampler.dart';
import 'package:quickshare/core/webrtc/turn_credential_refresher.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/progress_throttle.dart';

/// Raised instead of starting a transfer that would run through a relay and
/// blow past [AppConstants.maxRelayTransferBytes].
class RelayLimitExceeded implements Exception {
  final int sessionBytes;
  final int limitBytes;
  const RelayLimitExceeded(this.sessionBytes, this.limitBytes);

  @override
  String toString() => 'session of $sessionBytes bytes exceeds the '
      '$limitBytes byte relay ceiling';
}

class WebRtcTransferTransport implements TransferTransport {
  ResumeSetup? _resumeSetup;
  ResumeSenderSignaling? _resumeSignaling;
  WebRtcSenderLink? _senderLink;
  ResumableSender? _sender;
  bool _sendEnded = false;
  String? lastFailureCode;
  int _transferBytes = 0;
  bool _resumeRelayBlocked = false;

  void configureResume(ResumeSetup setup) => _resumeSetup = setup;

  /// Cuts the active native link to exercise recovery in integration tests.
  @visibleForTesting
  Future<void> interruptLinkForTest() async {
    final link = _senderLink;
    if (link == null || _sender == null || !link.isOpen) {
      throw StateError('No active sender link to interrupt');
    }
    await link.close();
  }

  RTCPeerConnection? _peerConnection;
  RTCPeerConnection? _connectingPeer;
  final Completer<void> _stopped = Completer<void>();
  RTCDataChannel? _dataChannel;

  final StreamController<double> _progressController =
      StreamController<double>.broadcast();
  final StreamController<TransferStatus> _statusController =
      StreamController<TransferStatus>.broadcast();

  // Only the LAN/room flow uses this. The serverless flow never constructs a
  // signaling client, so every use must stay null-safe.

  final _gathering = IceGatheringTracker();

  /// How long ICE may sit in `disconnected` before the session is written off.
  /// Long enough for the routine blips a relayed path produces, short enough
  /// that a dead transfer does not look alive indefinitely.
  static const _iceRecoveryGrace = Duration(seconds: 20);
  Timer? _iceRecoveryTimer;

  /// Every file in this session.
  ///
  /// The transport used to take a single [FileMetadata] because the wire
  /// protocol could only express one; it now carries a manifest, so the list
  /// is the real unit of work. Single-file callers still pass one item.
  List<FileMetadata>? _sessionFiles;

  /// DD-25: the listing can still be walking when the QR goes up. Bytes
  /// wait on this; ICE gathering does not.
  Future<List<FileMetadata>>? _filesReady;

  final _degradationController =
      StreamController<RelayLimitExceeded>.broadcast();

  /// Fires when the connection came up but the session is too large to push
  /// through the relay it landed on. Nothing has been sent at that point.
  Stream<RelayLimitExceeded> get relayBlockedStream =>
      _degradationController.stream;

  final _noPathController = StreamController<NoPathDiagnosis>.broadcast();

  /// ICE gave up before a single byte moved.
  ///
  /// Separate from a failure because it is a different thing to say and a
  /// different thing to do about it: nothing was sent, the cause is a VPN or
  /// a NAT that will not open, and there is a way out — put both devices on
  /// one network. Reported as a failure it reached the person as "Transfer
  /// failed unexpectedly", which names neither.
  ///
  /// Carries what is known about why: whether the relay was in play, what was
  /// gathered, which pair (if any) was chosen. Without a relay this is the
  /// expected ending on the target setup, so it says which kind of "without".
  Stream<NoPathDiagnosis> get noUsablePath => _noPathController.stream;

  /// Why this session has no relay, from the Worker fetch that opened the
  /// peer connection. Null when it has one. Kept for the length of the session
  /// so that a connection that fails can say whether the relay was missing
  /// from the start.
  RelayUnavailable? _relayUnavailable;
  RelayUnavailable? get relayUnavailable => _relayUnavailable;

  /// Bounds the wait for a connection after the answer is applied; expiry is
  /// handled exactly like ICE reporting `failed`.
  late final IceConnectDeadline _connectDeadline = IceConnectDeadline(
    budget: iceConnectBudget,
    tag: 'WEBRTC_SENDER',
    onExpired: () => unawaited(_reportIceGaveUp()),
  );

  /// Whether the connect deadline is running right now. For a test that has to
  /// see it stop once the connection is up.
  @visibleForTesting
  bool get iceDeadlineArmed => _connectDeadline.isArmed;

  bool _noPathReported = false;

  /// Set when the session is being torn down on purpose. Closing the peer
  /// connection makes ICE report `closed`, and that is our own doing, not a
  /// route that failed to exist.
  bool _stopping = false;

  /// True once the session has begun putting bytes on the channel. After
  /// that an ICE collapse is an interruption, not an absent route.
  bool _sendingStarted = false;

  /// DD-24: the send loop used to report on every 64 KB chunk. Same isolate
  /// that writes, same flood the receiver already throttled.
  final _progressThrottle = ProgressThrottle();

  /// §6 — keeps the CPU/display awake for the duration of a transfer.
  final _wakelockGuard = WakelockGuard();

  /// §9 — refreshes TURN credentials before they expire.
  TurnCredentialRefresher? _turnRefresher;

  bool _expectingRelay = false;

  /// How long a negotiation may take once the answer is applied. Overridable
  /// only so a test need not spend a minute to see the deadline act.
  final Duration iceConnectBudget;

  WebRtcTransferTransport(
      {this.iceConnectBudget = IceConnectDeadline.defaultBudget});

  @override
  Stream<double> get progressStream => _progressController.stream;

  @override
  Stream<TransferStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _statusController.add(TransferStatus.initial);
  }

  Future<IceSetup> _iceConfiguration() => IceServers.configurationDynamic();

  Future<RTCPeerConnection> _openPeerConnection() async {
    final setup = await _iceConfiguration();
    final ice = setup.configuration;
    final iceCount = (ice['iceServers'] as List?)?.length ?? 0;
    _expectingRelay = IceServers.containsTurn(ice);
    _relayUnavailable = setup.relayUnavailable;
    AppLogger.info(
      'Creating peer connection ($iceCount ICE servers, cap ${IceServers.maxIceServers}, '
      'expectingRelay=$_expectingRelay, '
      'relay=${_relayUnavailable?.reason.name ?? 'available'}, '
      'policy=${ice['iceTransportPolicy']})',
      tag: 'WEBRTC_SENDER',
    );
    return createPeerConnection(ice);
  }

  /// Starts a TURN credential refresh timer after the peer connection is up.
  ///
  /// §9: Credentials fetched at connection time expire after 30 minutes.
  /// The refresher wakes up 5 minutes before expiry and calls
  /// `setConfiguration()` with fresh credentials — no DataChannel tear-down.
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

  /// Serverless share: brings up the peer connection and the data channel and
  /// stops there. The offer leaves through the QR code and the answer comes
  /// back through an [AnswerChannel], so nothing here talks to the signaling
  /// server.
  ///
  /// Deliberately does **not** call `createRoom()` or
  /// `resolvePeerReachableUrl()`. The first one dials `ws://localhost:3000`
  /// and blocks for its full 12-second timeout when no local signaling process
  /// is running — which is the normal case — and the second one asks the
  /// router for a port mapping with an unlimited lease that nothing ever
  /// removes. Neither is of any use once the answer travels out-of-band.
  Future<void> startSharingServerless(FileMetadata file,
      {List<FileMetadata>? files,
      Future<List<FileMetadata>>? filesReady}) async {
    try {
      // `files` is the real session when it is already known. [filesReady]
      // is the same list still being walked — ICE gathering does not wait
      // on it; the send loop does.
      _sessionFiles = files ?? (filesReady == null ? [file] : null);
      _filesReady = filesReady;
      _statusController.add(TransferStatus.connecting);
      await _wakelockGuard.acquire(); // §6

      _peerConnection = await _openPeerConnection();
      await _startTurnRefresher(); // §9

      // Candidates gathered after the QR is rendered cannot reach the peer —
      // there is no trickle path in this mode — so they are logged rather than
      // sent anywhere.
      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        // No trickle path in this mode: whatever is not in the SDP by the time
        // the QR is drawn never reaches the peer. Tracked so gathering can stop
        // as soon as something routable exists.
        _gathering.observe(candidate);
      };

      final initialConnection = _peerConnection!;
      initialConnection.onIceConnectionState = (state) {
        // The original peer may report its close after a replacement has
        // already taken over. Its events belong only to that original link.
        if (identical(_peerConnection, initialConnection)) {
          _onIceStateChanged(state);
        }
      };

      final dataChannelDict = RTCDataChannelInit()..ordered = true;
      _dataChannel = await _peerConnection!
          .createDataChannel('fileTransfer', dataChannelDict);

      final link = WebRtcSenderLink(
        generation: 1,
        connection: _peerConnection!,
        channel: _dataChannel!,
        sendWindow: AppConstants.webRtcSendWindow,
      );
      _senderLink = link;
      unawaited(() async {
        try {
          await link.opened;
        } catch (_) {
          if (!_stopping) await _reportIceGaveUp();
          return;
        }
        try {
          if (!_stopping) await _startTransferIfAffordable(file);
        } catch (error) {
          if (!_stopping) {
            AppLogger.error('Could not start WebRTC transfer: $error',
                tag: 'WEBRTC_SENDER');
            _statusController.add(TransferStatus.failed);
          }
        }
      }());
    } catch (e) {
      await _wakelockGuard.release(); // §6
      _statusController.add(TransferStatus.failed);
      throw Exception('WebRTC serverless setup failed: $e');
    }
  }

  /// Decides, once the channel is open and before any payload moves, whether
  /// this session is affordable on the path that was actually selected.
  ///
  /// The check belongs here rather than at gathering time: gathering only
  /// knows what was offered, and the winning pair is not chosen until both
  /// sides have run connectivity checks.
  /// Whether the last session went direct or through somebody's relay.
  ///
  /// Read by the sender bloc when it files the transfer away for the settings
  /// screen: "Internet (relayed)" and "Internet (peer to peer)" look identical
  /// to a user watching a progress ring, and differ by an order of magnitude.
  IcePathKind? lastIcePath;

  /// The candidate types on each end of the pair [lastIcePath] was read from —
  /// `local=relay remote=srflx` — for whoever has to say which kinds of
  /// candidate met, not only how the bytes travelled. Null until a channel has
  /// opened.
  String? lastIcePair;

  Future<void> _startTransferIfAffordable(FileMetadata file) async {
    final connection = _peerConnection;
    if (connection == null) return;

    final selected = await waitForSelectedPath(connection);
    final path = selected.kind;
    final pair = selected.pair;
    if (_stopping) return;
    lastIcePair = pair;
    AppLogger.info(
        'Serverless sender selected path: ${path.name} '
        '($pair), '
        'relay=${_relayUnavailable?.reason.name ?? 'available'}, '
        'session ${file.size} bytes',
        tag: 'WEBRTC_SENDER');
    // Which of the two it turned out to be is the single fact that explains a
    // slow internet transfer, and it was only ever written to a log file.
    lastIcePath = path;

    if (_filesReady != null) {
      _sessionFiles = await _filesReady;
    }
    if (_stopping) return;
    final session = _sessionFiles ?? [file];

    // The whole session, not just the first file: ten photos through a relay
    // cost ten photos' worth of somebody else's bandwidth.
    final sessionBytes = session.fold<int>(0, (sum, f) => sum + f.size);
    if (!relayLimitAllows(path, sessionBytes)) {
      final blocked =
          RelayLimitExceeded(sessionBytes, AppConstants.maxRelayTransferBytes);
      AppLogger.warning(
          path == IcePathKind.unknown
              ? 'Refusing to start: the path could not be confirmed as direct '
                  'and the session is over the relay cap. Not a byte was sent.'
              : 'Refusing to start: $blocked. Not a single byte was sent.',
          tag: 'WEBRTC_SENDER');
      if (!_degradationController.isClosed) {
        _degradationController.add(blocked);
      }
      // No `failed` on top of it. The refusal above *is* the outcome, and it
      // has somewhere to go — the screen that explains the limit and offers a
      // local network instead. Both events reached the bloc, the failure
      // arrived second, and "Transfer failed unexpectedly" replaced the
      // explanation on its way to the screen.
      return;
    }

    _sendingStarted = true;
    _statusController.add(TransferStatus.transferring);
    await _sendFilesInChunks(session);
  }

  Future<void> handleDirectAnswer(String sdp, String type) async {
    AppLogger.info(
        'handleDirectAnswer received SDP answer: type=$type, length=${sdp.length}',
        tag: 'WEBRTC_SENDER');
    if (_peerConnection == null) {
      AppLogger.warning('handleDirectAnswer error: _peerConnection is null',
          tag: 'WEBRTC_SENDER');
      return;
    }
    await _peerConnection!
        .setRemoteDescription(RTCSessionDescription(sdp, type));
    AppLogger.info('Remote description set on the sender',
        tag: 'WEBRTC_SENDER');
    // Both descriptions are in: from here a connection either comes up or the
    // session is written off, whether or not libwebrtc ever says `failed`.
    _connectDeadline.arm();
  }

  /// Constraints that keep the offer to the one media section this app has
  /// any use for.
  ///
  /// Without them libwebrtc offers audio and video as well, and the resulting
  /// SDP carries three m-sections — `m=audio` at mid 0, `m=video` at mid 1 and
  /// the data channel at mid 2. [CompactSdp] rebuilds a single
  /// `m=application` at mid 0 on the far side, so the answer came back with
  /// one m-line against an offer with three and libwebrtc rejected it with
  /// "the order of m-lines in answer doesn't match order in offer".
  ///
  /// It also cut the offer from ~8.6 KB to a fraction of that, most of the
  /// removed bulk being codec lists for media nobody sends.
  static const Map<String, dynamic> _dataChannelOnly = {
    'mandatory': {
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    },
    'optional': [],
  };

  Future<String?> createLocalOfferSdp() async {
    if (_peerConnection == null) return null;
    final offer = await _peerConnection!.createOffer(_dataChannelOnly);
    await _peerConnection!.setLocalDescription(offer);

    await waitForUsableCandidates(_peerConnection!, _gathering,
        expectingRelay: _expectingRelay, tag: 'WEBRTC_SENDER');

    final fullLocalDesc = await _peerConnection!.getLocalDescription();
    AppLogger.info(
        'Sender: Generated local SDP offer with gathered candidates (length=${fullLocalDesc?.sdp?.length})',
        tag: 'WEBRTC_SENDER');
    return fullLocalDesc?.sdp ?? offer.sdp;
  }

  /// Sends every file in the session, newest protocol.
  ///
  /// A manifest first, then each file framed by `file-start`/`file-end`, then
  /// `complete`. Progress is reported across the whole session rather than per
  /// file, so a ten-photo send does not snap back to 0% ten times.
  ///
  /// §8: compression is decided per item and skipped for already-compressed
  /// formats (JPEG, HEIC, MP4, ZIP…), which is also what keeps photos and
  /// videos bit-identical on arrival.
  Future<void> _sendFilesInChunks(List<FileMetadata> files) async {
    try {
      final items = <SendItem>[];
      for (final f in files) {
        items.add(SendItem(
            TransferItem(
              name: f.name,
              size: await File(f.path).length(),
              mimeType: f.mimeType,
              compressed: shouldCompressForTransfer(f.mimeType, f.name),
              path: f.relPath,
            ),
            f.path));
      }
      _transferBytes = items.fold<int>(0, (sum, item) => sum + item.item.size);
      final sender = ResumableSender(
        items: items,
        firstLink: _senderLink!,
        reconnect: _reconnect,
        sendWindow: AppConstants.webRtcSendWindow,
        chunkSize: AppConstants.webRtcChunkSizeBytes,
        pace: (sent) async {
          _debugSessionSent = sent;
          await _debugPace(sent);
        },
        onProgress: (fraction) {
          if (_progressThrottle.allow(force: fraction >= 1)) {
            _progressController.add(fraction);
          }
        },
        onPhase: (phase) {
          if (!_stopping) {
            _statusController.add(phase == SenderPhase.reconnecting
                ? TransferStatus.reconnecting
                : TransferStatus.transferring);
          }
        },
        onLinkChanged: (link) {
          if (link is WebRtcSenderLink) {
            _senderLink = link;
            _peerConnection = link.connection;
            _dataChannel = link.channel;
            if (link.generation > 1) {
              _statsProbe?.stop();
              _statsProbe = null;
              _startStatsProbe();
              unawaited(_startTurnRefresher());
            }
          }
        },
      );
      _sender = sender;
      await sender.run();
      if (!_stopping) _statusController.add(TransferStatus.completed);
    } on SendCancelled {
      // stopSharing already published cancellation.
    } on SendFailure catch (e) {
      lastFailureCode = e.code;
      AppLogger.error('WebRTC send failed: $e', tag: 'WEBRTC_SENDER');
      if (!_stopping && !_resumeRelayBlocked) {
        _statusController.add(TransferStatus.failed);
      }
    } catch (e) {
      AppLogger.error('WebRTC send failed: $e', tag: 'WEBRTC_SENDER');
      if (!_stopping) _statusController.add(TransferStatus.failed);
    } finally {
      _sendEnded = true;
      _sender = null;
      await _resumeSignaling?.close();
      _resumeSignaling = null;
    }
  }

  Future<SenderLink> _reconnect(
      int generation, int attempt, Duration timeout) async {
    final setup = _resumeSetup;
    if (setup == null) throw StateError('Resume signaling is unavailable');
    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      if (_stopping) throw const SendCancelled();
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('Reconnect timed out');
      return left;
    }

    final signaling = _resumeSignaling ??= ResumeSenderSignaling(
        mailbox: (setup.mailboxFactory ?? buildCodeMailbox)(),
        keys: setup.keys);
    try {
      await signaling.open().timeout(remaining());
    } catch (_) {
      if (identical(_resumeSignaling, signaling)) _resumeSignaling = null;
      await signaling.close();
      rethrow;
    }
    if (_stopping) throw const SendCancelled();
    var abandoned = false;
    final creating = _openPeerConnection().then((connection) async {
      if (abandoned || _stopping) {
        await connection.close();
        throw const SendCancelled();
      }
      return connection;
    });
    late final RTCPeerConnection connection;
    try {
      connection = await Future.any<RTCPeerConnection>([
        creating,
        _stopped.future.then((_) => throw const SendCancelled()),
      ]).timeout(remaining());
    } catch (_) {
      abandoned = true;
      rethrow;
    }
    _connectingPeer = connection;
    WebRtcSenderLink? link;
    try {
      final gathering = IceGatheringTracker();
      connection.onIceCandidate = gathering.observe;
      connection.onIceConnectionState = (state) => link?.iceState(state);
      final channel = await connection
          .createDataChannel(
              'fileTransfer', RTCDataChannelInit()..ordered = true)
          .timeout(remaining());
      link = WebRtcSenderLink(
          generation: generation,
          connection: connection,
          channel: channel,
          sendWindow: AppConstants.webRtcSendWindow);
      final offer =
          await connection.createOffer(_dataChannelOnly).timeout(remaining());
      await connection.setLocalDescription(offer).timeout(remaining());
      await waitForUsableCandidates(connection, gathering,
              expectingRelay: _expectingRelay, tag: 'WEBRTC_SENDER')
          .timeout(remaining());
      final local = await connection.getLocalDescription().timeout(remaining());
      final sdp = local?.sdp ?? offer.sdp;
      if (sdp == null || sdp.isEmpty) throw StateError('No reconnect offer');
      final answer = await signaling.offer(
          generation: generation,
          offerSdp: ServerlessQr.trimForQr(CompactSdp.fromSdp(sdp)).toBytes(),
          timeout: remaining());
      await connection
          .setRemoteDescription(RTCSessionDescription(
              CompactSdp.fromBytes(answer).toSdp(isOffer: false), 'answer'))
          .timeout(remaining());
      await link.opened.timeout(remaining());
      final selected =
          await waitForSelectedPath(connection).timeout(remaining());
      final path = selected.kind;
      if (!relayLimitAllows(path, _transferBytes)) {
        _resumeRelayBlocked = true;
        if (!_degradationController.isClosed) {
          _degradationController.add(RelayLimitExceeded(
              _transferBytes, AppConstants.maxRelayTransferBytes));
        }
        try {
          link.sendText(TransferProtocol.buildCancelled());
          await link.waitForRoom(0, stallTimeout: const Duration(seconds: 2));
        } catch (_) {}
        throw const SendFailure(FailureCode.connectionLostNotRecovered,
            'The replacement path exceeds the relay transfer limit');
      }
      lastIcePath = path;
      lastIcePair = selected.pair;
      if (_stopping) throw const SendCancelled();
      return link;
    } catch (_) {
      if (link != null) {
        await link.close();
      } else {
        await connection.close();
      }
      rethrow;
    } finally {
      if (identical(_connectingPeer, connection)) _connectingPeer = null;
    }
  }

  final Stopwatch _debugPaceClock = Stopwatch();

  /// Debug builds only (`QUICKSHARE_SEND_RATE_KIB`): holds the send loop back
  /// so that [sent] bytes are not out earlier than the configured rate allows.
  Future<void> _debugPace(int sent) async {
    const rate = AppConstants.debugSendRateKiB;
    if (!kDebugMode || rate <= 0) return;
    if (!_debugPaceClock.isRunning) _debugPaceClock.start();
    final due = Duration(
        microseconds:
            (sent * Duration.microsecondsPerSecond / (rate * 1024)).round());
    final wait = due - _debugPaceClock.elapsed;
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  /// Fails the transfer when ICE reaches a state it will not come back from.
  ///
  /// `disconnected` deliberately does not fail: on a relay path under a VPN it
  /// appears routinely and recovers on its own within seconds, and treating it
  /// as fatal would abort healthy transfers. It only starts a grace period —
  /// if the connection has not come back by the time it expires, the transfer
  /// is declared dead rather than left hanging.
  ///
  /// Previously only `failed` was handled, so a connection that went
  /// `disconnected` and stayed there left the send loop waiting on a buffer
  /// nobody was draining, with the UI frozen on its last percentage.
  /// Says which of the two things just happened: a route that never existed,
  /// or a transfer that was under way and broke.
  Future<void> _reportIceGaveUp() async {
    _connectDeadline.cancel();
    if (_sendingStarted) return;
    if (_stopping || _noPathReported || _noPathController.isClosed) return;
    _noPathReported = true;

    final diagnosis = await diagnoseNoPath(
      relayUnavailable: _relayUnavailable,
      gathering: _gathering,
      connection: _peerConnection,
    );
    AppLogger.error(diagnosis.summary, tag: 'WEBRTC_SENDER');
    if (!_stopping && !_noPathController.isClosed) {
      _noPathController.add(diagnosis);
    }
  }

  void _onIceStateChanged(RTCIceConnectionState state) {
    AppLogger.info('Sender ICE state: $state', tag: 'WEBRTC_SENDER');
    _senderLink?.iceState(state);

    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _connectDeadline.connected();
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
        _startStatsProbe();
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = Timer(_iceRecoveryGrace, () {
          AppLogger.error(
              'ICE stayed disconnected for ${_iceRecoveryGrace.inSeconds}s — '
              'giving up on this session',
              tag: 'WEBRTC_SENDER');
          unawaited(_reportIceGaveUp());
        });
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
        unawaited(_reportIceGaveUp());
      default:
        break;
    }
  }

  TransferStatsSampler? _statsProbe;

  /// Debug builds with `QUICKSHARE_STATS_PROBE=true`: one line a second about
  /// this connection, with what this side has queued and sent next to the
  /// network's own numbers.
  void _startStatsProbe() {
    final connection = _peerConnection;
    if (!kDebugMode || !AppConstants.statsProbe) return;
    if (connection == null || _statsProbe != null) return;
    _statsProbe = TransferStatsSampler(
      label: 'sender',
      connection: connection,
      withLivenessProbe: true,
      extra: () => {
        'queued': _senderLink?.queuedBytes,
        'dc_buffered': _dataChannel?.bufferedAmount,
        'sent_session': _debugSessionSent,
      },
    )..start();
  }

  int _debugSessionSent = 0;

  @override
  Future<void> stopSharing() async {
    final activeSender = _sender;
    _stopping = true;
    if (!_stopped.isCompleted) _stopped.complete();
    await _connectingPeer?.close();
    _statusController.add(TransferStatus.cancelled);
    await activeSender?.cancel();
    await _resumeSignaling?.close();

    // Use the current link, including after reconnection. A queued frame and a
    // fixed delay are not delivery when megabytes of payload precede it.
    if (activeSender == null && !_sendEnded) {
      await _senderLink?.notifyCancellation();
    }

    _iceRecoveryTimer?.cancel();
    _iceRecoveryTimer = null;
    _connectDeadline.cancel();
    _statsProbe?.stop();
    _statsProbe = null;
    _turnRefresher?.cancel(); // §9
    _turnRefresher = null;
    await _wakelockGuard.release(); // §6
    final link = _senderLink;
    _senderLink = null;
    if (link != null) {
      await link.close();
    } else {
      await _dataChannel?.close();
      await _peerConnection?.close();
    }
    _dataChannel = null;
    _peerConnection = null;
    if (!_noPathController.isClosed) {
      await _noPathController.close();
    }
    if (!_degradationController.isClosed) {
      await _degradationController.close();
    }
  }
}

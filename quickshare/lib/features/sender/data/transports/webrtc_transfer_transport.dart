import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/utils/mime_compression.dart';
import 'package:quickshare/core/utils/wakelock_guard.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';
import 'package:quickshare/core/webrtc/send_buffer.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/core/webrtc/turn_credential_refresher.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/core/network/auto_tunnel_service.dart';
import 'package:quickshare/features/sender/data/signaling/webrtc_signaling_client.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/core/utils/app_logger.dart';

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
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;

  final StreamController<double> _progressController =
      StreamController<double>.broadcast();
  final StreamController<TransferStatus> _statusController =
      StreamController<TransferStatus>.broadcast();

  String? _roomId;
  // Only the LAN/room flow uses this. The serverless flow never constructs a
  // signaling client, so every use must stay null-safe.
  WebRtcSignalingClient? _signalingClient;
  StreamSubscription<Map<String, dynamic>>? _signalSub;

  bool _remoteDescriptionSet = false;
  final _gathering = IceGatheringTracker();

  /// How long ICE may sit in `disconnected` before the session is written off.
  /// Long enough for the routine blips a relayed path produces, short enough
  /// that a dead transfer does not look alive indefinitely.
  static const _iceRecoveryGrace = Duration(seconds: 20);
  Timer? _iceRecoveryTimer;

  /// Our own running total of bytes handed to the data channel and not yet
  /// reported as drained.
  ///
  /// `RTCDataChannel.bufferedAmount` cannot be used on its own for flow
  /// control: it is a value cached on the Dart side that only moves when the
  /// native layer pushes a `dataChannelBufferedAmountChange` event across the
  /// platform channel, and it starts at zero. A tight send loop reads that
  /// stale zero, concludes there is room, and sends again — so the real SCTP
  /// queue grows unchecked until libwebrtc hits its hard 16 MiB send-buffer
  /// ceiling and closes the channel mid-transfer.
  ///
  /// Counting locally on every send makes backpressure immediate; the platform
  /// event then corrects the estimate downward as bytes actually leave.
  int _queuedBytes = 0;

  /// Pending waiter for [_awaitDrain], completed by the buffered-amount event.
  Completer<void>? _drainWaiter;

  /// Every file in this session.
  ///
  /// The transport used to take a single [FileMetadata] because the wire
  /// protocol could only express one; it now carries a manifest, so the list
  /// is the real unit of work. Single-file callers still pass one item.
  List<FileMetadata>? _sessionFiles;

  final _degradationController = StreamController<RelayLimitExceeded>.broadcast();

  /// Fires when the connection came up but the session is too large to push
  /// through the relay it landed on. Nothing has been sent at that point.
  Stream<RelayLimitExceeded> get relayBlockedStream =>
      _degradationController.stream;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  /// §6 — keeps the CPU/display awake for the duration of a transfer.
  final _wakelockGuard = WakelockGuard();

  /// §9 — refreshes TURN credentials before they expire.
  TurnCredentialRefresher? _turnRefresher;

  /// Overrides the signaling endpoint this sender dials.
  ///
  /// The receiver has taken one of these since it was written; the sender did
  /// not, which made the room-based path impossible to exercise against
  /// anything but a process listening on the compiled-in default. Production
  /// leaves it null and gets [AppConstants.signalingServerUrl].
  final String? signalingUrlOverride;

  WebRtcTransferTransport({this.signalingUrlOverride});

  @override
  Stream<double> get progressStream => _progressController.stream;

  @override
  Stream<TransferStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _statusController.add(TransferStatus.initial);
    // Sender dials the configured URL as-is (localhost is fine on the Mac
    // that hosts signaling_server).
    _signalingClient = WebRtcSignalingClient(
        serverUrl: signalingUrlOverride ?? AppConstants.signalingServerUrl);
  }

  Future<Map<String, dynamic>> _iceConfiguration() =>
      IceServers.configurationDynamic();

  /// Starts a TURN credential refresh timer after the peer connection is up.
  ///
  /// §9: Credentials fetched at connection time expire after 30 minutes.
  /// The refresher wakes up 5 minutes before expiry and calls
  /// `setConfiguration()` with fresh credentials — no DataChannel tear-down.
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

  @override
  Future<String> startSharing(FileMetadata file, String token) async {
    try {
      _statusController.add(TransferStatus.connecting);
      await _wakelockGuard.acquire(); // §6

      _peerConnection = await createPeerConnection(await _iceConfiguration());
      await _startTurnRefresher(); // §9
      // The room-based path had no ICE state handler at all, so a dropped
      // connection here was even quieter than in the serverless one.
      _peerConnection!.onIceConnectionState = _onIceStateChanged;

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate == null) return;
        _signalingClient?.sendIceCandidate({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };

      // Reliable ordered channel (do not set maxRetransmits).
      final dataChannelDict = RTCDataChannelInit()..ordered = true;
      _dataChannel =
          await _peerConnection!.createDataChannel('fileTransfer', dataChannelDict);

      _trackBufferedAmount(_dataChannel!);

      _dataChannel!.onDataChannelState = (RTCDataChannelState state) {
        debugPrint('WebRTC sender DataChannel state: $state');
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _statusController.add(TransferStatus.transferring);
          unawaited(_sendFilesInChunks([file]));
        }
      };

      // Subscribe BEFORE createRoom so receiver-joined is never dropped.
      _signalSub = _signalingClient!.messages.listen((msg) async {
        try {
          final type = msg['type'];
          if (type == 'receiver-joined') {
            debugPrint('WebRTC: receiver joined — creating offer');
            await _createAndSendOffer();
          } else if (type == 'answer') {
            final sdpMap = Map<String, dynamic>.from(msg['payload'] as Map);
            await _peerConnection?.setRemoteDescription(
              RTCSessionDescription(
                sdpMap['sdp'] as String?,
                sdpMap['type'] as String?,
              ),
            );
            _remoteDescriptionSet = true;
            for (final c in _pendingRemoteCandidates) {
              await _peerConnection?.addCandidate(c);
            }
            _pendingRemoteCandidates.clear();
          } else if (type == 'ice-candidate') {
            final candidateMap =
                Map<String, dynamic>.from(msg['payload'] as Map);
            final candidate = RTCIceCandidate(
              candidateMap['candidate'] as String?,
              candidateMap['sdpMid'] as String?,
              candidateMap['sdpMLineIndex'] as int?,
            );
            if (_remoteDescriptionSet) {
              await _peerConnection?.addCandidate(candidate);
            } else {
              _pendingRemoteCandidates.add(candidate);
            }
          }
        } catch (e) {
          debugPrint('WebRTC sender signaling handler error: $e');
        }
      });

      _roomId = await _signalingClient!.createRoom();

      // Peer must dial a host it can reach — not the sender's localhost.
      final peerSignalingUrl = signalingUrlOverride ??
          await WebRtcSignalingClient.resolvePeerReachableUrl(
              AppConstants.signalingServerUrl);

      return DeepLinkService.buildShareLink(
        roomCode: _roomId!,
        signalingUrlForPeer: peerSignalingUrl,
      );
    } catch (e) {
      await _wakelockGuard.release(); // §6
      _statusController.add(TransferStatus.failed);
      throw Exception('WebRTC startSharing failed: $e');
    }
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
      {List<FileMetadata>? files}) async {
    try {
      // `files` is the real session; `file` stays in the signature because it
      // also carries the name and size the QR/preview screens display.
      _sessionFiles = files ?? [file];
      _statusController.add(TransferStatus.connecting);
      await _wakelockGuard.acquire(); // §6

      _peerConnection = await createPeerConnection(await _iceConfiguration());
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

      _peerConnection!.onIceConnectionState = _onIceStateChanged;

      final dataChannelDict = RTCDataChannelInit()..ordered = true;
      _dataChannel = await _peerConnection!
          .createDataChannel('fileTransfer', dataChannelDict);

      _trackBufferedAmount(_dataChannel!);

      _dataChannel!.onDataChannelState = (RTCDataChannelState state) {
        AppLogger.info('Serverless sender DataChannel state: $state',
            tag: 'WEBRTC_SENDER');
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          unawaited(_startTransferIfAffordable(file));
        }
      };
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

  Future<void> _startTransferIfAffordable(FileMetadata file) async {
    final connection = _peerConnection;
    if (connection == null) return;

    final path = await selectedPathKind(connection);
    AppLogger.info(
        'Serverless sender selected path: ${path.name}, '
        'session ${file.size} bytes',
        tag: 'WEBRTC_SENDER');
    // Which of the two it turned out to be is the single fact that explains a
    // slow internet transfer, and it was only ever written to a log file.
    lastIcePath = path;

    // The whole session, not just the first file: ten photos through a relay
    // cost ten photos' worth of somebody else's bandwidth.
    final sessionBytes =
        (_sessionFiles ?? [file]).fold<int>(0, (sum, f) => sum + f.size);
    if (!relayLimitAllows(path, sessionBytes)) {
      final blocked =
          RelayLimitExceeded(sessionBytes, AppConstants.maxRelayTransferBytes);
      AppLogger.warning(
          'Refusing to start: $blocked. Not a single byte was sent.',
          tag: 'WEBRTC_SENDER');
      if (!_degradationController.isClosed) {
        _degradationController.add(blocked);
      }
      _statusController.add(TransferStatus.failed);
      return;
    }

    _statusController.add(TransferStatus.transferring);
    await _sendFilesInChunks(_sessionFiles ?? [file]);
  }

  Future<void> handleDirectAnswer(String sdp, String type) async {
    AppLogger.info('handleDirectAnswer received SDP answer: type=$type, length=${sdp.length}', tag: 'WEBRTC_SENDER');
    if (_peerConnection == null) {
      AppLogger.warning('handleDirectAnswer error: _peerConnection is null', tag: 'WEBRTC_SENDER');
      return;
    }
    await _peerConnection!.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteDescriptionSet = true;
    AppLogger.info('Remote description set successfully on Sender. Applying ${_pendingRemoteCandidates.length} pending candidates', tag: 'WEBRTC_SENDER');
    for (final c in _pendingRemoteCandidates) {
      await _peerConnection?.addCandidate(c);
    }
    _pendingRemoteCandidates.clear();
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
        tag: 'WEBRTC_SENDER');

    final fullLocalDesc = await _peerConnection!.getLocalDescription();
    AppLogger.info('Sender: Generated local SDP offer with gathered candidates (length=${fullLocalDesc?.sdp?.length})', tag: 'WEBRTC_SENDER');
    return fullLocalDesc?.sdp ?? offer.sdp;
  }

  Future<void> _createAndSendOffer() async {
    if (_peerConnection == null) return;
    final offer = await _peerConnection!.createOffer(_dataChannelOnly);
    await _peerConnection!.setLocalDescription(offer);
    _signalingClient?.sendOffer({'sdp': offer.sdp, 'type': offer.type});
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
      final items = <TransferItem>[];
      for (final f in files) {
        items.add(TransferItem(
          name: f.name,
          size: await File(f.path).length(),
          mimeType: f.mimeType,
          compressed: shouldCompressForTransfer(f.mimeType, f.name),
        ));
      }

      final sessionBytes = items.fold<int>(0, (sum, i) => sum + i.size);
      _dataChannel!
          .send(RTCDataChannelMessage(TransferProtocol.buildManifest(items)));
      AppLogger.info(
          'Sending ${items.length} file(s), $sessionBytes bytes total',
          tag: 'WEBRTC_SENDER');

      const chunkSize = AppConstants.webRtcChunkSizeBytes;
      var sessionSent = 0;

      for (var index = 0; index < files.length; index++) {
        final item = items[index];
        _dataChannel!.send(
            RTCDataChannelMessage(TransferProtocol.buildFileStart(index)));

        final raf = await File(files[index].path).open(mode: FileMode.read);
        var fileSent = 0;
        try {
          while (fileSent < item.size) {
            final bytesToRead = (item.size - fileSent < chunkSize)
                ? (item.size - fileSent)
                : chunkSize;
            final chunk = await raf.read(bytesToRead);

            final payload = item.compressed
                ? Uint8List.fromList(GZipEncoder().encode(chunk)!)
                : Uint8List.fromList(chunk);

            _dataChannel!.send(RTCDataChannelMessage.fromBinary(payload));
            _queuedBytes += payload.length;
            fileSent += bytesToRead;
            sessionSent += bytesToRead;

            if (sessionBytes > 0) {
              _progressController.add(sessionSent / sessionBytes);
            }

            await SendBuffer.waitForRoom(
              bufferedAmount: () => _queuedBytes,
              isOpen: _isChannelOpen,
              limit: AppConstants.webRtcMaxBufferedAmount,
            );
          }
        } finally {
          await raf.close();
        }

        _dataChannel!
            .send(RTCDataChannelMessage(TransferProtocol.buildFileEnd(index)));
      }

      // Drain before complete so the receiver is not short-changed.
      await SendBuffer.waitUntilEmpty(
        bufferedAmount: () => _queuedBytes,
        isOpen: _isChannelOpen,
        onDrain: _awaitDrain,
      );

      _dataChannel!
          .send(RTCDataChannelMessage(TransferProtocol.buildComplete()));
      await Future.delayed(const Duration(milliseconds: 300));
      _statusController.add(TransferStatus.completed);
    } on TransferStalled catch (e) {
      // Reported separately from a generic failure because the cause is
      // different in kind: nothing threw, the far side simply stopped
      // consuming. Before this existed the loop just kept waiting and the UI
      // sat on its last percentage forever.
      AppLogger.error('Transfer stalled: $e', tag: 'WEBRTC_SENDER');
      _statusController.add(TransferStatus.failed);
    } catch (e) {
      debugPrint('WebRTC send failed: $e');
      _statusController.add(TransferStatus.failed);
    }
  }

  /// Keeps [_queuedBytes] honest using the native layer's own figure.
  ///
  /// The event is authoritative but late; the local counter is immediate but
  /// only ever grows. Together they give a number that reacts at once to a
  /// send and still settles back down as the queue actually drains.
  void _trackBufferedAmount(RTCDataChannel channel) {
    _queuedBytes = 0;
    _drainWaiter = null;
    channel.onBufferedAmountChange = (currentAmount, changedAmount) {
      _queuedBytes = currentAmount;
      if (currentAmount <= AppConstants.webRtcMaxBufferedAmount) {
        final waiter = _drainWaiter;
        _drainWaiter = null;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      }
    };
  }

  /// Completes the next time the platform reports the send buffer has room.
  ///
  /// The send loop used to learn that only by polling every 50 ms, which put a
  /// hard ceiling on throughput at one window per poll — 4.8 MB/s measured
  /// against a predicted 5.0, on loopback, with no network involved. Waking on
  /// the event removes the ceiling; the poll stays underneath as a backstop
  /// for platforms that report late or not at all.
  Future<void> _awaitDrain() {
    final waiter = _drainWaiter ??= Completer<void>();
    return waiter.future;
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
  void _onIceStateChanged(RTCIceConnectionState state) {
    AppLogger.info('Sender ICE state: $state', tag: 'WEBRTC_SENDER');

    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = Timer(_iceRecoveryGrace, () {
          AppLogger.error(
              'ICE stayed disconnected for ${_iceRecoveryGrace.inSeconds}s — '
              'giving up on this session',
              tag: 'WEBRTC_SENDER');
          _statusController.add(TransferStatus.failed);
        });
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
        _statusController.add(TransferStatus.failed);
      default:
        break;
    }
  }

  /// Whether the channel is still in a state that can carry bytes.
  ///
  /// `null` counts as open: the channel is created before the first send and
  /// a missing state must not be read as a closed one.
  bool _isChannelOpen() {
    final state = _dataChannel?.state;
    if (_dataChannel == null) return false;
    return state == null || state == RTCDataChannelState.RTCDataChannelOpen;
  }

  @override
  Future<void> stopSharing() async {
    _statusController.add(TransferStatus.cancelled);

    // Tell the far side before tearing anything down. Without this the
    // receiver only sees the channel go quiet, which is indistinguishable
    // from a dropped network — it would sit through its whole disconnect
    // grace period and then report a connection error for what was actually
    // somebody pressing Cancel.
    //
    // Best-effort: if the channel is already gone there is nobody to tell,
    // and failing to send a courtesy message must not block the teardown.
    try {
      if (_isChannelOpen()) {
        _dataChannel?.send(RTCDataChannelMessage(TransferProtocol.buildCancelled()));
        // The frame is only queued by send(); give it a moment on the wire
        // before the channel closes underneath it.
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } catch (e) {
      AppLogger.warning('Could not announce cancellation: $e',
          tag: 'WEBRTC_SENDER');
    }

    // Only the LAN/room flow ever asks the router for a mapping, but calling
    // this unconditionally is free when there is nothing to release and means
    // a future caller cannot forget.
    await AutoTunnelService().releasePortMappings();
    _iceRecoveryTimer?.cancel();
    _iceRecoveryTimer = null;
    _turnRefresher?.cancel(); // §9
    _turnRefresher = null;
    await _wakelockGuard.release(); // §6
    await _signalSub?.cancel();
    _signalSub = null;
    await _dataChannel?.close();
    await _peerConnection?.close();
    await _signalingClient?.dispose();
    _dataChannel = null;
    _peerConnection = null;
    _pendingRemoteCandidates.clear();
    _remoteDescriptionSet = false;
    if (!_degradationController.isClosed) {
      await _degradationController.close();
    }
  }
}

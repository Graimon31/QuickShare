import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/utils/mime_compression.dart';
import 'package:quickshare/core/utils/wakelock_guard.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';
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

      _dataChannel!.onDataChannelState = (RTCDataChannelState state) {
        debugPrint('WebRTC sender DataChannel state: $state');
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _statusController.add(TransferStatus.transferring);
          unawaited(_sendFileInChunks(file));
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
  Future<void> startSharingServerless(FileMetadata file) async {
    try {
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

      _peerConnection!.onIceConnectionState = (state) {
        AppLogger.info('Serverless sender ICE state: $state',
            tag: 'WEBRTC_SENDER');
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          _statusController.add(TransferStatus.failed);
        }
      };

      final dataChannelDict = RTCDataChannelInit()..ordered = true;
      _dataChannel = await _peerConnection!
          .createDataChannel('fileTransfer', dataChannelDict);

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
  Future<void> _startTransferIfAffordable(FileMetadata file) async {
    final connection = _peerConnection;
    if (connection == null) return;

    final path = await selectedPathKind(connection);
    AppLogger.info(
        'Serverless sender selected path: ${path.name}, '
        'session ${file.size} bytes',
        tag: 'WEBRTC_SENDER');

    if (!relayLimitAllows(path, file.size)) {
      final blocked =
          RelayLimitExceeded(file.size, AppConstants.maxRelayTransferBytes);
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
    await _sendFileInChunks(file);
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

  /// §8 — sends the file over the DataChannel with optional gzip compression.
  ///
  /// Compression is skipped for already-compressed formats (JPEG, MP4, ZIP…).
  /// The receiver learns whether compression is active from the `compressed`
  /// field in the `file-meta` JSON message.
  Future<void> _sendFileInChunks(FileMetadata fileMetadata) async {
    try {
      final file = File(fileMetadata.path);
      final totalBytes = await file.length();
      var bytesSent = 0;

      // §8: decide whether to compress this payload.
      final compress =
          shouldCompressForTransfer(fileMetadata.mimeType, fileMetadata.name);

      final metadataJson = jsonEncode({
        'type': 'file-meta',
        'name': fileMetadata.name,
        'size': totalBytes,
        'mime': fileMetadata.mimeType,
        'compressed': compress, // §8
      });
      _dataChannel!.send(RTCDataChannelMessage(metadataJson));

      const chunkSize = AppConstants.webRtcChunkSizeBytes;
      final raf = await file.open(mode: FileMode.read);

      while (bytesSent < totalBytes) {
        final bytesToRead = (totalBytes - bytesSent < chunkSize)
            ? (totalBytes - bytesSent)
            : chunkSize;
        final chunk = await raf.read(bytesToRead);

        // §8: compress the chunk if applicable.
        final payload = compress
            ? Uint8List.fromList(GZipEncoder().encode(chunk)!)
            : Uint8List.fromList(chunk);

        _dataChannel!.send(RTCDataChannelMessage.fromBinary(payload));
        bytesSent += bytesToRead;

        _progressController.add(bytesSent / totalBytes);

        const maxBufferedAmount = AppConstants.webRtcMaxBufferedAmount;
        while (_dataChannel?.bufferedAmount != null &&
            _dataChannel!.bufferedAmount! > maxBufferedAmount) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }

      await raf.close();

      // Drain before complete so the receiver is not short-changed.
      while (_dataChannel?.bufferedAmount != null &&
          _dataChannel!.bufferedAmount! > 0) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      _dataChannel!
          .send(RTCDataChannelMessage(jsonEncode({'type': 'complete'})));
      await Future.delayed(const Duration(milliseconds: 300));
      _statusController.add(TransferStatus.completed);
    } catch (e) {
      debugPrint('WebRTC send failed: $e');
      _statusController.add(TransferStatus.failed);
    }
  }

  @override
  Future<void> stopSharing() async {
    _statusController.add(TransferStatus.cancelled);
    // Only the LAN/room flow ever asks the router for a mapping, but calling
    // this unconditionally is free when there is nothing to release and means
    // a future caller cannot forget.
    await AutoTunnelService().releasePortMappings();
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

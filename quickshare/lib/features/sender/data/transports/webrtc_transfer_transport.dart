import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/webrtc/sdp_compressor.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/features/sender/data/signaling/webrtc_signaling_client.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/core/utils/app_logger.dart';

class WebRtcTransferTransport implements TransferTransport {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;

  final StreamController<double> _progressController =
      StreamController<double>.broadcast();
  final StreamController<TransferStatus> _statusController =
      StreamController<TransferStatus>.broadcast();

  String? _roomId;
  late WebRtcSignalingClient _signalingClient;
  StreamSubscription<Map<String, dynamic>>? _signalSub;

  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  WebRtcTransferTransport();

  @override
  Stream<double> get progressStream => _progressController.stream;

  @override
  Stream<TransferStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _statusController.add(TransferStatus.initial);
    // Sender dials the configured URL as-is (localhost is fine on the Mac
    // that hosts signaling_server).
    _signalingClient =
        WebRtcSignalingClient(serverUrl: AppConstants.signalingServerUrl);
  }

  Map<String, dynamic> _iceConfiguration() {
    final iceServers = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ];
    if (AppConstants.turnServerUrl.isNotEmpty) {
      final mainTurnUrl = AppConstants.turnServerUrl;
      final username = AppConstants.turnUsername;
      final credential = AppConstants.turnCredential;

      // 1. Standard UDP (turn:...) for maximum speed
      final udpTurnMap = <String, dynamic>{'urls': mainTurnUrl};
      if (username.isNotEmpty) udpTurnMap['username'] = username;
      if (credential.isNotEmpty) udpTurnMap['credential'] = credential;
      iceServers.add(udpTurnMap);

      // 2. TCP Port 80 (turn:...?transport=tcp) for cellular NAT traversal
      final tcpUrl = mainTurnUrl.contains('?')
          ? '$mainTurnUrl&transport=tcp'
          : '$mainTurnUrl?transport=tcp';
      final tcpTurnMap = <String, dynamic>{'urls': tcpUrl};
      if (username.isNotEmpty) tcpTurnMap['username'] = username;
      if (credential.isNotEmpty) tcpTurnMap['credential'] = credential;
      iceServers.add(tcpTurnMap);

      // 3. TURNS / TLS Port 443 (turns:...:443?transport=tcp) for corporate HTTPS firewall traversal
      final turnsBase = mainTurnUrl.replaceFirst('turn:', 'turns:');
      final turnsUrl = turnsBase.replaceAll(':80', ':443');
      final turnsTcpUrl = turnsUrl.contains('?')
          ? '$turnsUrl&transport=tcp'
          : '$turnsUrl?transport=tcp';
      final turnsTurnMap = <String, dynamic>{'urls': turnsTcpUrl};
      if (username.isNotEmpty) turnsTurnMap['username'] = username;
      if (credential.isNotEmpty) turnsTurnMap['credential'] = credential;
      iceServers.add(turnsTurnMap);
    }
    return {
      'iceServers': iceServers,
      'iceTransportPolicy': 'all',
    };
  }

  @override
  Future<String> startSharing(FileMetadata file, String token) async {
    try {
      _statusController.add(TransferStatus.connecting);

      _peerConnection = await createPeerConnection(_iceConfiguration());

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate == null) return;
        _signalingClient.sendIceCandidate({
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
      _signalSub = _signalingClient.messages.listen((msg) async {
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

      _roomId = await _signalingClient.createRoom();

      // Peer must dial a host it can reach — not the sender's localhost.
      final peerSignalingUrl =
          await WebRtcSignalingClient.resolvePeerReachableUrl(
              AppConstants.signalingServerUrl);

      return DeepLinkService.buildShareLink(
        roomCode: _roomId!,
        signalingUrlForPeer: peerSignalingUrl,
      );
    } catch (e) {
      _statusController.add(TransferStatus.failed);
      throw Exception('WebRTC startSharing failed: $e');
    }
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

  Future<String?> createLocalOfferSdp() async {
    if (_peerConnection == null) return null;
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    // Wait up to 1 second for local ICE candidate gathering (host, stun, turn relay)
    if (_peerConnection!.iceGatheringState != RTCIceGatheringState.RTCIceGatheringStateComplete) {
      final completer = Completer<void>();
      _peerConnection!.onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete && !completer.isCompleted) {
          completer.complete();
        }
      };
      await completer.future.timeout(const Duration(milliseconds: 1000), onTimeout: () {});
    }

    final fullLocalDesc = await _peerConnection!.getLocalDescription();
    AppLogger.info('Sender: Generated local SDP offer with gathered candidates (length=${fullLocalDesc?.sdp?.length})', tag: 'WEBRTC_SENDER');
    return fullLocalDesc?.sdp ?? offer.sdp;
  }

  Future<void> _createAndSendOffer() async {
    if (_peerConnection == null) return;
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    _signalingClient.sendOffer({'sdp': offer.sdp, 'type': offer.type});
  }

  Future<void> _sendFileInChunks(FileMetadata fileMetadata) async {
    try {
      final file = File(fileMetadata.path);
      final totalBytes = await file.length();
      var bytesSent = 0;

      final metadataJson = jsonEncode({
        'type': 'file-meta',
        'name': fileMetadata.name,
        'size': totalBytes,
        'mime': fileMetadata.mimeType,
      });
      _dataChannel!.send(RTCDataChannelMessage(metadataJson));

      final chunkSize = AppConstants.webRtcChunkSizeBytes;
      final raf = await file.open(mode: FileMode.read);

      while (bytesSent < totalBytes) {
        final bytesToRead = (totalBytes - bytesSent < chunkSize)
            ? (totalBytes - bytesSent)
            : chunkSize;
        final chunk = await raf.read(bytesToRead);

        _dataChannel!
            .send(RTCDataChannelMessage.fromBinary(Uint8List.fromList(chunk)));
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
    await _signalSub?.cancel();
    _signalSub = null;
    await _dataChannel?.close();
    await _peerConnection?.close();
    await _signalingClient.dispose();
    _dataChannel = null;
    _peerConnection = null;
    _pendingRemoteCandidates.clear();
    _remoteDescriptionSet = false;
  }
}

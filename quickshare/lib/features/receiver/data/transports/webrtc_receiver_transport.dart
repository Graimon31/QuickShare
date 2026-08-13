import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/webrtc/sdp_compressor.dart';
import 'package:quickshare/features/sender/data/signaling/webrtc_signaling_client.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/core/utils/app_logger.dart';

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

/// Receives a file over a WebRTC DataChannel after joining a share room.
class WebRtcReceiverTransport {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  WebRtcSignalingClient? _signaling;
  StreamSubscription<Map<String, dynamic>>? _signalSub;

  final _progressController =
      StreamController<WebRtcReceiveProgress>.broadcast();
  final _statusController = StreamController<TransferStatus>.broadcast();

  Stream<WebRtcReceiveProgress> get progressStream => _progressController.stream;
  Stream<TransferStatus> get statusStream => _statusController.stream;

  final _completion = Completer<String>();

  int _totalBytes = 0;
  int _receivedBytes = 0;
  IOSink? _fileSink;
  String _fileName = 'received_file';
  String? _targetPath;
  bool _isRemoteDescSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];

  DateTime _lastTick = DateTime.now();
  int _lastBytes = 0;
  int _speedBps = 0;
  String _baseDir = '';

  static const _connectionTimeout = Duration(seconds: 75);

  String sanitizeFileName(String name) {
    final base = p
        .basename(name)
        .replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_')
        .trim();
    if (base.isEmpty || base.replaceAll('.', '').isEmpty) return 'received_file';
    return base;
  }

  String resolveTargetPath(String fileName, String baseDir) {
    final resolved = p.normalize(p.join(baseDir, sanitizeFileName(fileName)));
    if (!p.isWithin(baseDir, resolved)) {
      throw Exception('Path traversal detected in "$fileName"');
    }
    return resolved;
  }

  /// Connects serverlessly using an [sdpOffer] carried in the QR code.
  ///
  /// The answer goes back through [deliverAnswer] — a sealed drop through
  /// public infrastructure. The older [answerEndpointUrl] path posted straight
  /// to the sender's address, which only ever worked when the sender was
  /// reachable from the internet; behind CGNAT the request never arrived.
  Future<String> receiveWithSdpOffer(
    String sdpOffer, {
    String? targetDir,
    String? answerEndpointUrl,
    Future<void> Function(String answerSdp)? deliverAnswer,
  }) async {
    try {
      _emit('connecting', detail: 'Processing serverless SDP offer…');
      _statusController.add(TransferStatus.connecting);

      final rawSdp = SdpCompressor.decompress(sdpOffer);

      _peerConnection = await createPeerConnection(_buildIceConfiguration());

      _peerConnection!.onDataChannel = (RTCDataChannel channel) {
        debugPrint('WebRTC receiver serverless: data channel received');
        _dataChannel = channel;
        channel.onMessage = _handleMessage;
      };

      AppLogger.info('Receiver: Decompressed sdpOffer length=${rawSdp.length}. Endpoint=$answerEndpointUrl', tag: 'WEBRTC_RECEIVER');

      try {
        await _peerConnection!.setRemoteDescription(RTCSessionDescription(rawSdp, 'offer'));
      } catch (e, st) {
        AppLogger.error('Receiver setRemoteDescription failed for SDP length ${rawSdp.length}', error: e, stackTrace: st, tag: 'WEBRTC_RECEIVER');
        rethrow;
      }
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      // Wait up to 1 second for ICE gathering
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
      final finalAnswerSdp = fullLocalDesc?.sdp ?? answer.sdp;

      if (deliverAnswer != null) {
        AppLogger.info(
            'Receiver: delivering SDP answer through the signaling channel '
            '(${finalAnswerSdp?.length ?? 0} chars)',
            tag: 'WEBRTC_RECEIVER');
        await deliverAnswer(finalAnswerSdp ?? '');
      } else if (answerEndpointUrl != null && answerEndpointUrl.isNotEmpty) {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 5);
        try {
          AppLogger.info('Receiver: Posting SDP answer to $answerEndpointUrl', tag: 'WEBRTC_RECEIVER');
          final req = await client.postUrl(Uri.parse(answerEndpointUrl));
          req.headers.set('Content-Type', 'application/json');
          req.add(utf8.encode(jsonEncode({'sdp': finalAnswerSdp, 'type': answer.type})));
          final res = await req.close();
          AppLogger.info('Receiver: Posted SDP answer response status code=${res.statusCode}', tag: 'WEBRTC_RECEIVER');
        } catch (e) {
          AppLogger.error('Receiver: Error posting SDP answer to $answerEndpointUrl', error: e, tag: 'WEBRTC_RECEIVER');
        } finally {
          client.close();
        }
      }

      final dir = targetDir ?? (await getApplicationDocumentsDirectory()).path;
      final completer = Completer<String>();

      late StreamSubscription sub;
      sub = _statusController.stream.listen((status) {
        if (status == TransferStatus.completed) {
          sub.cancel();
          if (!completer.isCompleted) {
            completer.complete(_targetPath ?? p.join(dir, 'received_file'));
          }
        } else if (status == TransferStatus.failed) {
          sub.cancel();
          if (!completer.isCompleted) {
            completer.completeError(Exception('Serverless WebRTC transfer failed'));
          }
        }
      });

      return completer.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          sub.cancel();
          throw Exception('Serverless transfer timed out waiting for data channel');
        },
      );
    } catch (e) {
      _statusController.add(TransferStatus.failed);
      throw Exception('receiveWithSdpOffer failed: $e');
    }
  }

  /// Joins [roomCode] on [signalingUrl] (or [AppConstants.signalingServerUrl]).
  Future<String> receive(
    String roomCode, {
    String? targetDir,
    String? signalingUrl,
  }) async {
    try {
      _emit('connecting',
          detail: 'Contacting signaling server…');
      _statusController.add(TransferStatus.connecting);

      final url = (signalingUrl != null && signalingUrl.isNotEmpty)
          ? signalingUrl
          : AppConstants.signalingServerUrl;

      if (url.contains('localhost') || url.contains('127.0.0.1')) {
        throw Exception(
          'Signaling URL is localhost ($url). The phone cannot reach the '
          'sender\'s loopback. Rebuild the sender so the share link includes '
          'sig=ws://<sender-lan-ip>:3000, run signaling_server on the Mac, '
          'and keep the phone on the same Wi‑Fi (not LTE-only).',
        );
      }

      _signaling = WebRtcSignalingClient(serverUrl: url);

      _peerConnection = await createPeerConnection(_buildIceConfiguration());

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate == null) return;
        _signaling?.sendIceCandidate({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };

      _peerConnection!.onIceConnectionState = (state) {
        debugPrint('WebRTC receiver ICE: $state');
        if (state ==
                RTCIceConnectionState.RTCIceConnectionStateFailed ||
            state ==
                RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
          if (!_completion.isCompleted) {
            _fail(
              'Peer connection failed (ICE $state). '
              'Same Wi‑Fi helps; for LTE/cellular configure TURN via '
              'QUICKSHARE_TURN_URL / USER / PASS.',
            );
          }
        }
      };

      _peerConnection!.onDataChannel = (RTCDataChannel channel) {
        debugPrint('WebRTC receiver: data channel received');
        _dataChannel = channel;
        channel.onMessage = _handleMessage;
      };

      final baseDir = targetDir ??
          (await getDownloadsDirectory())?.path ??
          (await getApplicationDocumentsDirectory()).path;

      _signalSub = _signaling!.messages.listen((msg) async {
        try {
          switch (msg['type']) {
            case 'offer':
              _emit('connecting', detail: 'Negotiating peer connection…');
              await _handleOffer(
                  Map<String, dynamic>.from(msg['payload'] as Map));
              break;
            case 'ice-candidate':
              await _handleRemoteCandidate(
                  Map<String, dynamic>.from(msg['payload'] as Map));
              break;
            case 'peer-disconnected':
              if (!_completion.isCompleted) {
                if (_totalBytes > 0 && _receivedBytes >= _totalBytes) {
                  await _fileSink?.flush();
                  await _fileSink?.close();
                  _fileSink = null;
                  _statusController.add(TransferStatus.completed);
                  _emit('completed');
                  if (!_completion.isCompleted) {
                    _completion.complete(_targetPath ?? '');
                  }
                  await _cleanup();
                } else {
                  _fail('Sender disconnected before the transfer finished');
                }
              }
              break;
          }
        } catch (e) {
          _fail('Signaling error: $e');
        }
      });

      _emit('connecting', detail: 'Joining room $roomCode…');
      await _signaling!.joinRoom(roomCode);
      _baseDir = baseDir;
      _emit('connecting',
          detail:
              'Waiting for sender peer connection (keep the Mac share screen open)…');

      return await _completion.future.timeout(
        _connectionTimeout,
        onTimeout: () {
          throw Exception(
            'Timed out waiting for the file transfer. Checklist:\n'
            '• Signaling server running on the sender machine\n'
            '• Share link contains sig=ws://… and phone can open that host:port\n'
            '• Same Wi‑Fi for LAN signaling (LTE often needs TURN)\n'
            '• Sender still on the Share / QR screen',
          );
        },
      );
    } catch (e) {
      _statusController.add(TransferStatus.failed);
      await _cleanup();
      rethrow;
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> payload) async {
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(
          payload['sdp'] as String?, payload['type'] as String?),
    );
    _isRemoteDescSet = true;

    for (final c in _pendingCandidates) {
      await _peerConnection!.addCandidate(c);
    }
    _pendingCandidates.clear();

    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    _signaling!.sendAnswer({'sdp': answer.sdp, 'type': answer.type});
  }

  Future<void> _handleRemoteCandidate(Map<String, dynamic> payload) async {
    final candidate = RTCIceCandidate(
      payload['candidate'] as String?,
      payload['sdpMid'] as String?,
      payload['sdpMLineIndex'] as int?,
    );
    if (_isRemoteDescSet) {
      await _peerConnection!.addCandidate(candidate);
    } else {
      _pendingCandidates.add(candidate);
    }
  }

  Future<void> _handleMessage(RTCDataChannelMessage message) async {
    try {
      if (message.isBinary) {
        if (_fileSink == null) return;
        _fileSink!.add(message.binary);
        _receivedBytes += message.binary.length;

        final now = DateTime.now();
        final delta = now.difference(_lastTick).inMilliseconds / 1000.0;
        if (delta >= 0.5) {
          _speedBps = ((_receivedBytes - _lastBytes) / delta).round();
          _lastTick = now;
          _lastBytes = _receivedBytes;
        }
        _emit('transferring');
        return;
      }

      final data = jsonDecode(message.text) as Map<String, dynamic>;
      switch (data['type']) {
        case 'file-meta':
        case 'metadata':
          _fileName =
              sanitizeFileName(data['name'] as String? ?? 'received_file');
          _totalBytes = data['size'] as int? ?? 0;
          _receivedBytes = 0;
          _lastBytes = 0;
          _lastTick = DateTime.now();
          _targetPath = _uniquePath(resolveTargetPath(_fileName, _baseDir));
          _fileSink = File(_targetPath!).openWrite();
          _statusController.add(TransferStatus.transferring);
          _emit('transferring');
          break;

        case 'complete':
        case 'file-complete':
          await _fileSink?.flush();
          await _fileSink?.close();
          _fileSink = null;
          if (_totalBytes > 0 && _receivedBytes < _totalBytes) {
            _fail(
                'Transfer completed prematurely: received $_receivedBytes of $_totalBytes bytes');
          } else {
            _statusController.add(TransferStatus.completed);
            _emit('completed');
            if (!_completion.isCompleted) {
              _completion.complete(_targetPath ?? '');
            }
            await _cleanup();
          }
          break;
      }
    } catch (e) {
      _fail('Failed to write incoming file: $e');
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
      received: _receivedBytes,
      total: _totalBytes,
      speedBps: _speedBps,
      detail: detail,
    ));
  }

  void _fail(String reason) {
    debugPrint('WebRTC receive failed: $reason');
    _statusController.add(TransferStatus.failed);
    _emit('failed', detail: reason);
    if (!_completion.isCompleted) {
      _completion.completeError(Exception(reason));
    }
    _cleanup();
  }

  Future<void> _cleanup() async {
    await _signalSub?.cancel();
    _signalSub = null;
    await _signaling?.dispose();
    _signaling = null;
    await _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    _peerConnection = null;
  }

  Future<void> cancel() async {
    await _fileSink?.close();
    _fileSink = null;
    if (_targetPath != null) {
      final partial = File(_targetPath!);
      if (await partial.exists()) await partial.delete();
    }
    _statusController.add(TransferStatus.cancelled);
    if (!_completion.isCompleted) {
      _completion.completeError(Exception('Cancelled by user'));
    }
    await _cleanup();
  }

  Map<String, dynamic> _buildIceConfiguration() {
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
}

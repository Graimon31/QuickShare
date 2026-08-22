import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/utils/wakelock_guard.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';
import 'package:quickshare/core/webrtc/sdp_compressor.dart';
import 'package:quickshare/core/webrtc/turn_credential_refresher.dart';
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
  final _gathering = IceGatheringTracker();

  /// §8 — whether the incoming binary stream is gzip-compressed.
  bool _isCompressed = false;

  /// §6 — keeps CPU/display alive during the transfer.
  final _wakelockGuard = WakelockGuard();

  /// §9 — refreshes TURN credentials before they expire.
  TurnCredentialRefresher? _turnRefresher;

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
    // An empty base makes p.isWithin('', 'photo.jpg') return true and the
    // guard below wave through a relative path, which lands the file in the
    // process working directory. Reject it outright rather than trusting every
    // caller to have set the destination.
    if (baseDir.isEmpty || !p.isAbsolute(baseDir)) {
      throw Exception('Receive directory is not set (got "$baseDir")');
    }
    final resolved = p.normalize(p.join(baseDir, sanitizeFileName(fileName)));
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

      _peerConnection = await createPeerConnection(await _buildIceConfiguration());
      await _startTurnRefresher(); // §9

      _peerConnection!.onDataChannel = (RTCDataChannel channel) {
        debugPrint('WebRTC receiver serverless: data channel received');
        _dataChannel = channel;
        channel.onMessage = _handleMessage;
      };

      // The answer is sealed and published once; like the offer, it has no
      // trickle path, so gathering has to finish before it is encoded.
      _peerConnection!.onIceCandidate = _gathering.observe;

      AppLogger.info('Receiver: decompressed offer, ${rawSdp.length} chars',
          tag: 'WEBRTC_RECEIVER');

      try {
        await _peerConnection!.setRemoteDescription(RTCSessionDescription(rawSdp, 'offer'));
      } catch (e, st) {
        AppLogger.error('Receiver setRemoteDescription failed for SDP length ${rawSdp.length}', error: e, stackTrace: st, tag: 'WEBRTC_RECEIVER');
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
            completer.complete(_targetPath ?? p.join(_baseDir, 'received_file'));
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
      await _wakelockGuard.release(); // §6
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
      await _wakelockGuard.acquire(); // §6

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

      _peerConnection = await createPeerConnection(await _buildIceConfiguration());
      await _startTurnRefresher(); // §9

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
      await _wakelockGuard.release(); // §6
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

  /// §8 — handles incoming DataChannel messages.
  ///
  /// Binary messages are decompressed if the sender advertised
  /// `"compressed": true` in the `file-meta` JSON.
  Future<void> _handleMessage(RTCDataChannelMessage message) async {
    try {
      if (message.isBinary) {
        if (_fileSink == null) return;

        // §8: decompress if the sender said so.
        final bytes = _isCompressed
            ? GZipDecoder().decodeBytes(message.binary)
            : message.binary;

        _fileSink!.add(bytes);
        _receivedBytes += bytes.length;

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
          // §8: read compression flag; default false for backward compat.
          _isCompressed = (data['compressed'] as bool?) ?? false;
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
    _turnRefresher?.cancel(); // §9
    _turnRefresher = null;
    await _wakelockGuard.release(); // §6
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
}

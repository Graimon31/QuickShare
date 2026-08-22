import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:quickshare/core/network/auto_tunnel_service.dart';

class SignalingException implements Exception {
  final String message;
  SignalingException(this.message);
  @override
  String toString() => message;
}

/// WebRTC signaling over WebSocket, for both peers.
///
/// IMPORTANT: Do not rewrite `localhost` to *this device's* LAN IP when
/// dialing. Mac may correctly use `ws://localhost:3000`; the phone must use
/// the URL embedded in the share link (Mac LAN IP or public host), never its
/// own loopback / own IP.
class WebRtcSignalingClient {
  final String serverUrl;
  WebSocketChannel? _channel;
  StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  // Cancelled in dispose(); the lint only looks inside the declaring method.
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? _socketSub;
  bool _isDisposed = false;

  /// Effective URL after connect (for diagnostics).
  String? connectedUrl;

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  String? roomCode;

  WebRtcSignalingClient({required this.serverUrl});

  /// URL a *remote peer* should use to reach the same signaling process this
  /// sender dials. Resolves loopback with LAN or public endpoints.
  static Future<String> resolvePeerReachableUrl(String configuredUrl) async {
    return await AutoTunnelService().resolveReachableSignalingUrl(configuredUrl);
  }

  Future<Map<String, dynamic>> _connectAndAwait({
    required Map<String, dynamic> request,
    required String handshakeType,
  }) async {
    _isDisposed = false;
    if (_messageController.isClosed) {
      _messageController = StreamController<Map<String, dynamic>>.broadcast();
    }

    final completer = Completer<Map<String, dynamic>>();
    final targetUrl = serverUrl.trim().isEmpty
        ? 'ws://localhost:3000'
        : serverUrl.trim();
    connectedUrl = targetUrl;

    try {
      debugPrint('Signaling: connecting to $targetUrl');
      _channel = WebSocketChannel.connect(Uri.parse(targetUrl));
    } catch (e) {
      return Future.error(
          SignalingException('Cannot reach signaling server ($targetUrl): $e'));
    }

    _socketSub = _channel!.stream.listen(
      (data) {
        if (_isDisposed) return;
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode(data as String) as Map<String, dynamic>;
        } catch (_) {
          return;
        }

        if (!completer.isCompleted) {
          if (msg['type'] == handshakeType) {
            completer.complete(msg);
            // Also forward so late listeners can observe if needed.
            if (!_messageController.isClosed) {
              _messageController.add(msg);
            }
            return;
          }
          if (msg['type'] == 'error') {
            completer.completeError(
              SignalingException(
                  msg['message'] as String? ?? 'Signaling error'),
            );
            return;
          }
        }
        if (!_messageController.isClosed) {
          _messageController.add(msg);
        }
      },
      onError: (e) {
        if (_isDisposed) return;
        if (!completer.isCompleted) {
          completer.completeError(
              SignalingException('Signaling connection failed: $e'));
        }
      },
      onDone: () {
        if (_isDisposed) return;
        if (!completer.isCompleted) {
          completer.completeError(
              SignalingException('Signaling server closed connection'));
        }
      },
    );

    _send(request);
    return completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        final isLan = AutoTunnelService.isPrivateLanUrl(targetUrl);
        final reason = isLan
            ? 'Signaling address ($targetUrl) is a private LAN IP and is unreachable over cellular LTE/5G. Connect both devices to the same Wi‑Fi network, or specify a public signaling URL.'
            : 'Signaling server did not respond at $targetUrl.';
        throw SignalingException(reason);
      },
    );
  }

  Future<String> createRoom() async {
    final msg = await _connectAndAwait(
      request: {'type': 'create-room'},
      handshakeType: 'room-created',
    );
    roomCode = msg['roomCode'] as String;
    return roomCode!;
  }

  Future<void> joinRoom(String code) async {
    await _connectAndAwait(
      request: {'type': 'join-room', 'roomCode': code.toUpperCase()},
      handshakeType: 'room-joined',
    );
    roomCode = code.toUpperCase();
  }

  void sendOffer(Map<String, dynamic> offer) =>
      _send({'type': 'offer', 'roomCode': roomCode, 'payload': offer});

  void sendAnswer(Map<String, dynamic> answer) =>
      _send({'type': 'answer', 'roomCode': roomCode, 'payload': answer});

  void sendIceCandidate(Map<String, dynamic> candidate) =>
      _send({'type': 'ice-candidate', 'roomCode': roomCode, 'payload': candidate});

  void _send(Map<String, dynamic> message) {
    if (_isDisposed || _channel == null) return;
    try {
      _channel!.sink.add(jsonEncode(message));
    } catch (e) {
      debugPrint('Signaling sink error: $e');
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    final sub = _socketSub;
    _socketSub = null;
    try {
      await sub?.cancel();
    } catch (_) {}

    final ch = _channel;
    _channel = null;
    try {
      await ch?.sink.close(status.normalClosure);
    } catch (_) {}

    if (!_messageController.isClosed) {
      try {
        await _messageController.close();
      } catch (_) {}
    }
  }
}

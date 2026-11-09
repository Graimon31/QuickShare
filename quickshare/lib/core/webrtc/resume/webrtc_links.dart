import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/core/webrtc/resume/cancellation_notifier.dart';
import 'package:quickshare/core/webrtc/resume/receiver_link.dart';
import 'package:quickshare/core/webrtc/resume/reconnect_policy.dart';
import 'package:quickshare/core/webrtc/resume/resumable_sender.dart';
import 'package:quickshare/core/webrtc/send_buffer.dart';

/// A cancellation acknowledgement is transport control, hidden from the engine.
/// The recipient keeps the channel alive until the initiator closes it, so an
/// asynchronous native send cannot lose the acknowledgement during teardown.
class _CancellationHandshake {
  _CancellationHandshake(this.send, this.isOpen);
  final Future<void> Function(String frame) send;
  final bool Function() isOpen;
  final _peerClosed = Completer<void>();
  Completer<void>? _ack;
  Future<void>? _notification;
  bool _receivedCancellation = false;

  bool observe(String text) {
    Object? frame;
    try {
      frame = jsonDecode(text);
    } catch (_) {
      return false;
    }
    if (frame is! Map) return false;
    if (frame['__directdropFlow'] == 'cancel-ack') {
      final ack = _ack;
      if (ack != null && !ack.isCompleted) ack.complete();
      return true;
    }
    if (frame['type'] == TransferProtocol.cancelled) {
      _receivedCancellation = true;
      unawaited(send(jsonEncode({'__directdropFlow': 'cancel-ack'}))
          .catchError((Object _) {}));
    }
    return false;
  }

  Future<void> notify(Duration timeout) => _notification ??= _notify(timeout);

  Future<void> _notify(Duration timeout) async {
    if (!isOpen() || _receivedCancellation) return;
    final ack = _ack = Completer<void>();
    try {
      await (() async {
        await send(TransferProtocol.buildCancelled());
        await Future.any<void>([ack.future, _peerClosed.future]);
      })()
          .timeout(timeout);
    } catch (_) {
      // Best effort on broken networks and legacy peers; never an endless wait.
    }
  }

  void peerClosed() {
    if (!_peerClosed.isCompleted) _peerClosed.complete();
  }

  Future<void> beforeClose() async {
    if (!_receivedCancellation || _peerClosed.isCompleted) return;
    try {
      await _peerClosed.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {/* legacy initiator does not close promptly */}
  }
}

/// A peer connection's ICE state, reduced to what a link has to know: is it
/// still carrying bytes, has it stopped for good, or is it somewhere between.
///
/// `disconnected` is not death. On a relay path it comes and goes, and a link
/// that treated the first one as fatal would abort transfers that were never
/// broken. It starts a short grace instead; `failed` and `closed` end the
/// link at once. A link's own stall timers (the sender's send buffer, the
/// receiver's silence) are what notice a path that ICE still believes in.
class _IceWatch {
  _IceWatch({required this.grace, required this.onDead, required this.tag});

  final Duration grace;
  final void Function(String reason) onDead;
  final String tag;
  Timer? _timer;

  void state(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _timer?.cancel();
        _timer = null;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _timer ??= Timer(grace, () {
          _timer = null;
          onDead('ICE stayed disconnected for ${grace.inSeconds}s');
        });
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _timer?.cancel();
        _timer = null;
        onDead('ICE ${state.name.replaceFirst('RTCIceConnectionState', '')}');
      default:
        break;
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// The sender's end of one WebRTC link: a peer connection and the data channel
/// on it.
///
/// What used to live in the transport as bookkeeping for *the* channel is here,
/// once per link: the count of bytes handed to the channel and not yet reported
/// as left (see below), the wait for room, and the way ICE ending is turned
/// into the link being dead.
///
/// New receivers acknowledge cumulative wire bytes after processing each frame.
/// This supplies real backpressure on Windows, whose native WebRTC plugin does
/// not emit buffered-amount events. Older receivers retain native event based
/// flow control on supported platforms. The send counter also includes frames
/// still crossing the platform channel, so a cached native zero cannot flood it.
class WebRtcSenderLink implements SenderLink, CancellationNotifier {
  WebRtcSenderLink({
    required this.generation,
    required this.connection,
    required this.channel,
    required this.sendWindow,
    this.stall = const StallPolicy(),
    this.tag = 'WEBRTC_SENDER',
  }) {
    _ice = _IceWatch(grace: stall.iceDisconnectedGrace, onDead: _die, tag: tag);
    channel.onBufferedAmountChange = (current, changed) {
      if (_remoteFlowControl) return;
      _queuedBytes = current;
      if (current <= sendWindow) _wakeWaiter();
    };
    channel.onMessage = (message) {
      if (!message.isBinary && _cancellation.observe(message.text)) return;
      if (!message.isBinary && _handleFlowControl(message.text)) return;
      if (!message.isBinary && !_incoming.isClosed) {
        _incoming.add(message.text);
      }
    };
    channel.onDataChannelState = _onChannelState;
    // Whoever never asks to wait for the channel must not be told it failed.
    unawaited(_opened.future.then((_) {}, onError: (Object _) {}));
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _opened.complete();
    }
  }

  @override
  final int generation;
  final RTCPeerConnection connection;
  final RTCDataChannel channel;
  final int sendWindow;
  final StallPolicy stall;
  final String tag;

  late final _CancellationHandshake _cancellation = _CancellationHandshake(
      (frame) => channel.send(RTCDataChannelMessage(frame)), () => isOpen);

  @override
  Future<void> notifyCancellation(
          {Duration timeout = const Duration(seconds: 8)}) =>
      _cancellation.notify(timeout);

  late final _IceWatch _ice;
  // Frames that arrive before the engine has started listening are kept, so
  // the receiver's first word is never lost to a race.
  final _incoming = StreamController<String>();
  final _closedWith = Completer<String>();
  final _opened = Completer<void>();
  Completer<void>? _drainWaiter;
  int _queuedBytes = 0;
  int _sentBytes = 0;
  int _acknowledgedBytes = 0;
  bool _remoteFlowControl = false;

  bool _handleFlowControl(String frame) {
    Object? value;
    try {
      value = jsonDecode(frame);
    } catch (_) {
      return false;
    }
    if (value is! Map || !value.containsKey('__directdropFlow')) return false;
    if (value['__directdropFlow'] == 'ready') {
      _remoteFlowControl = true;
      _queuedBytes = _sentBytes - _acknowledgedBytes;
      _wakeWaiter();
    } else if (value['__directdropFlow'] == 'ack' && _remoteFlowControl) {
      final bytes = value['bytes'];
      if (bytes is int && bytes >= _acknowledgedBytes && bytes <= _sentBytes) {
        _acknowledgedBytes = bytes;
        _queuedBytes = _sentBytes - bytes;
        _wakeWaiter();
      }
    }
    return true;
  }

  bool _dead = false;

  /// What has been handed to the channel and has not yet left. For the log.
  int get queuedBytes => _queuedBytes;

  /// Completes when the channel is open; fails if the link dies first.
  Future<void> get opened => _opened.future;

  @override
  bool get isOpen {
    if (_dead) return false;
    final state = channel.state;
    return state == null || state == RTCDataChannelState.RTCDataChannelOpen;
  }

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<String> get closed => _closedWith.future;

  /// The owner of the peer connection forwards its ICE state here.
  void iceState(RTCIceConnectionState state) => _ice.state(state);

  void _onChannelState(RTCDataChannelState state) {
    AppLogger.info('Link $generation: data channel $state', tag: tag);
    if (state == RTCDataChannelState.RTCDataChannelOpen) {
      if (!_opened.isCompleted) _opened.complete();
    } else if (state == RTCDataChannelState.RTCDataChannelClosed ||
        state == RTCDataChannelState.RTCDataChannelClosing) {
      _cancellation.peerClosed();
      _die('the data channel closed');
    }
  }

  void _die(String reason) {
    if (_dead) return;
    _dead = true;
    _ice.cancel();
    AppLogger.warning('Link $generation is dead: $reason', tag: tag);
    if (!_closedWith.isCompleted) _closedWith.complete(reason);
    if (!_opened.isCompleted) {
      _opened.completeError(LinkLost('closed before it opened: $reason'));
    }
    _wakeWaiter();
  }

  void _wakeWaiter() {
    final waiter = _drainWaiter;
    _drainWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  @override
  void sendText(String frame) {
    if (!isOpen) throw const LinkLost('the channel is not open');
    final length = utf8.encode(frame).length;
    _sentBytes += length;
    _queuedBytes += length;
    unawaited(channel.send(RTCDataChannelMessage(frame)).catchError((Object e) {
      _die('sending a frame failed: ${e.runtimeType}');
    }));
  }

  @override
  void sendBinary(Uint8List bytes) {
    if (!isOpen) throw const LinkLost('the channel is not open');
    _sentBytes += bytes.length;
    _queuedBytes += bytes.length;
    unawaited(channel
        .send(RTCDataChannelMessage.fromBinary(bytes))
        .catchError((Object e) {
      _die('sending payload failed: ${e.runtimeType}');
    }));
  }

  @override
  Future<void> waitForRoom(int limit, {required Duration stallTimeout}) async {
    try {
      await SendBuffer.waitForRoom(
        bufferedAmount: () => _queuedBytes,
        isOpen: () => isOpen,
        limit: limit,
        onDrain: () => (_drainWaiter ??= Completer<void>()).future,
        stallTimeout: stallTimeout,
      );
    } on TransferStalled catch (e) {
      if (!_remoteFlowControl &&
          defaultTargetPlatform == TargetPlatform.windows) {
        throw const LinkLost('The receiver does not support acknowledged flow '
            'control. Update DirectDrop on the receiving device.');
      }
      throw LinkLost('$e');
    }
  }

  @override
  Future<void> close() async {
    await _cancellation.beforeClose();
    _die('closed here');
    _ice.cancel();
    try {
      await channel.close();
    } catch (_) {}
    try {
      await connection.close();
    } catch (_) {}
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }
}

/// The receiver's end of one WebRTC link.
///
/// A frame the receiver wants to send before the channel is open (its `hello`,
/// on the first link, goes out the moment the channel is announced) is held
/// and sent when it opens, in order.
class WebRtcReceiverLink implements ReceiverLink, CancellationNotifier {
  WebRtcReceiverLink({
    required this.generation,
    required this.connection,
    required this.channel,
    this.stall = const StallPolicy(),
    this.tag = 'WEBRTC_RECEIVER',
  }) {
    _ice = _IceWatch(grace: stall.iceDisconnectedGrace, onDead: _die, tag: tag);
    channel.onDataChannelState = _onChannelState;
    unawaited(_opened.future.then((_) {}, onError: (Object _) {}));
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _opened.complete();
    }
  }

  @override
  final int generation;
  final RTCPeerConnection connection;
  final RTCDataChannel channel;
  final StallPolicy stall;
  final String tag;

  late final _CancellationHandshake _cancellation = _CancellationHandshake(
      (frame) => channel.send(RTCDataChannelMessage(frame)), () => isOpen);

  @override
  Future<void> notifyCancellation(
          {Duration timeout = const Duration(seconds: 8)}) =>
      _cancellation.notify(timeout);

  late final _IceWatch _ice;
  final _opened = Completer<void>();
  final _pending = <String>[];
  void Function(String reason)? _onClosed;
  String? _deadBecause;
  bool _closing = false;
  bool _bound = false;
  int _receivedWireBytes = 0;

  /// The transport queues disk writes synchronously in onFrame. Acknowledging
  /// only once that queue has processed this frame bounds receiver memory too.
  Future<void> Function()? waitForHandledFrame;

  void _advertiseFlowControl() {
    if (_bound &&
        isOpen &&
        channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      sendText(jsonEncode({'__directdropFlow': 'ready'}));
    }
  }

  /// Completes when the channel is open; fails if the link dies first.
  Future<void> get opened => _opened.future;

  @override
  bool get isOpen =>
      _deadBecause == null &&
      !_closing &&
      channel.state != RTCDataChannelState.RTCDataChannelClosed &&
      channel.state != RTCDataChannelState.RTCDataChannelClosing;

  /// The owner of the peer connection forwards its ICE state here.
  void iceState(RTCIceConnectionState state) => _ice.state(state);

  void _onChannelState(RTCDataChannelState state) {
    AppLogger.info('Link $generation: data channel $state', tag: tag);
    if (state == RTCDataChannelState.RTCDataChannelOpen) {
      if (!_opened.isCompleted) _opened.complete();
      _advertiseFlowControl();
      final waiting = List<String>.of(_pending);
      _pending.clear();
      for (final frame in waiting) {
        sendText(frame);
      }
    } else if (state == RTCDataChannelState.RTCDataChannelClosed ||
        state == RTCDataChannelState.RTCDataChannelClosing) {
      _cancellation.peerClosed();
      _die('the data channel closed');
    }
  }

  void _die(String reason) {
    if (_deadBecause != null || _closing) return;
    _deadBecause = reason;
    _ice.cancel();
    AppLogger.warning('Link $generation is dead: $reason', tag: tag);
    if (!_opened.isCompleted) {
      _opened.completeError(LinkLost('closed before it opened: $reason'));
    }
    _onClosed?.call(reason);
  }

  @override
  void sendText(String frame) {
    if (!isOpen) return;
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      unawaited(
          channel.send(RTCDataChannelMessage(frame)).catchError((Object e) {
        _die('sending a frame failed: ${e.runtimeType}');
      }));
    } else {
      _pending.add(frame);
    }
  }

  @override
  void bind({
    required void Function(RTCDataChannelMessage message) onFrame,
    required void Function(String reason) onClosed,
  }) {
    _onClosed = onClosed;
    _bound = true;
    channel.onMessage = (message) {
      if (!message.isBinary && _cancellation.observe(message.text)) return;
      onFrame(message);
      _receivedWireBytes += message.isBinary
          ? message.binary.length
          : utf8.encode(message.text).length;
      final received = _receivedWireBytes;
      final handled = waitForHandledFrame?.call() ?? Future<void>.value();
      unawaited(handled.then((_) {
        if (isOpen) {
          sendText(jsonEncode({'__directdropFlow': 'ack', 'bytes': received}));
        }
      }).catchError((Object error) {
        _die('handling a received frame failed: ${error.runtimeType}');
      }));
    };
    _advertiseFlowControl();
    final already = _deadBecause;
    if (already != null) onClosed(already);
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    await _cancellation.beforeClose();
    _closing = true;
    _ice.cancel();
    if (!_opened.isCompleted) {
      _opened.completeError(const LinkLost('closed here'));
    }
    try {
      await channel.close();
    } catch (_) {}
    try {
      await connection.close();
    } catch (_) {}
  }
}

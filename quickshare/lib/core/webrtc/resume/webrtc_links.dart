import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/resume/receiver_link.dart';
import 'package:quickshare/core/webrtc/resume/reconnect_policy.dart';
import 'package:quickshare/core/webrtc/resume/resumable_sender.dart';
import 'package:quickshare/core/webrtc/send_buffer.dart';

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
/// ## Why the byte count is kept here
///
/// `RTCDataChannel.bufferedAmount` is a value cached on the Dart side that only
/// moves when the native layer pushes a `dataChannelBufferedAmountChange` event
/// across the platform channel, and it starts at zero. A tight send loop reads
/// that stale zero, concludes there is room and sends again, so the real queue
/// grows until libwebrtc hits its hard 16 MiB limit and closes the channel.
/// Counting locally on every send makes backpressure immediate; the event then
/// corrects the figure downward as bytes leave.
class WebRtcSenderLink implements SenderLink {
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
      _queuedBytes = current;
      if (current <= sendWindow) _wakeWaiter();
    };
    channel.onMessage = (message) {
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

  late final _IceWatch _ice;
  // Frames that arrive before the engine has started listening are kept, so
  // the receiver's first word is never lost to a race.
  final _incoming = StreamController<String>();
  final _closedWith = Completer<String>();
  final _opened = Completer<void>();
  Completer<void>? _drainWaiter;
  int _queuedBytes = 0;
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
    _queuedBytes += utf8.encode(frame).length;
    unawaited(channel.send(RTCDataChannelMessage(frame)).catchError((Object e) {
      _die('sending a frame failed: ${e.runtimeType}');
    }));
  }

  @override
  void sendBinary(Uint8List bytes) {
    if (!isOpen) throw const LinkLost('the channel is not open');
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
      throw LinkLost('$e');
    }
  }

  @override
  Future<void> close() async {
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
class WebRtcReceiverLink implements ReceiverLink {
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

  late final _IceWatch _ice;
  final _opened = Completer<void>();
  final _pending = <String>[];
  void Function(String reason)? _onClosed;
  String? _deadBecause;
  bool _closing = false;

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
      final waiting = List<String>.of(_pending);
      _pending.clear();
      for (final frame in waiting) {
        sendText(frame);
      }
    } else if (state == RTCDataChannelState.RTCDataChannelClosed ||
        state == RTCDataChannelState.RTCDataChannelClosing) {
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
    channel.onMessage = onFrame;
    final already = _deadBecause;
    if (already != null) onClosed(already);
  }

  @override
  Future<void> close() async {
    if (_closing) return;
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

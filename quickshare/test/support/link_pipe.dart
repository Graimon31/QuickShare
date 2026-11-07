import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:quickshare/core/webrtc/resume/receiver_link.dart';
import 'package:quickshare/core/webrtc/resume/resumable_sender.dart';

/// What a frame looked like when it was delivered, for the rules that decide
/// when a pipe is cut.
class PipeFrame {
  PipeFrame.text(String value)
      : text = value,
        binary = null,
        bytes = utf8.encode(value).length;
  PipeFrame.binary(Uint8List data)
      : binary = data,
        text = null,
        bytes = data.length;

  final String? text;
  final Uint8List? binary;
  final int bytes;

  bool get isBinary => binary != null;

  String? get type {
    final t = text;
    if (t == null) return null;
    try {
      final json = jsonDecode(t);
      return json is Map ? json['type'] as String? : null;
    } catch (_) {
      return null;
    }
  }
}

/// How a pipe dies.
enum PipeCut {
  /// Everything after the cut is lost and nobody is told: the sender finds out
  /// only because its buffer stops draining, the receiver only because nothing
  /// arrives. The failure of the logs this feature is about.
  blackhole,

  /// The channel closes and both ends are told at once.
  close,
}

/// One generation of a link, in memory: a [SenderLink] and the [ReceiverLink]
/// it talks to, with a way to cut it at a chosen moment.
///
/// Frames are delivered in order, one event-loop turn apart, and counted as
/// drained when delivered, so the sender's send buffer behaves as it does on a
/// healthy channel until the pipe is cut.
class LinkPipe {
  LinkPipe(this.generation, {this.cutKind = PipeCut.blackhole}) {
    sender = _PipeSender(this);
    receiver = _PipeReceiver(this);
  }

  final int generation;
  PipeCut cutKind;

  late final SenderLink sender;
  late final ReceiverLink receiver;

  /// Frames the sender has put on the pipe, as delivered or as lost.
  final List<PipeFrame> delivered = [];
  int lostFrames = 0;

  /// Cuts the pipe once this many bytes of binary payload have been
  /// delivered. The frame that crosses the mark is delivered whole.
  int? cutAfterBinaryBytes;

  /// Cuts the pipe after delivering the first frame this says yes to.
  bool Function(PipeFrame frame)? cutAfterFrame;

  /// Cuts the pipe *before* delivering the first frame this says yes to: that
  /// frame is lost with everything after it.
  bool Function(PipeFrame frame)? cutBeforeFrame;

  bool _cut = false;
  bool _closedForGood = false;
  final _closedReason = Completer<String>();
  int _binaryDelivered = 0;
  final List<PipeFrame> _queue = [];
  bool _pumping = false;
  int queued = 0;
  final _drained = StreamController<void>.broadcast();
  final _toSender = StreamController<String>();
  void Function(RTCDataChannelMessage message)? _onReceiverFrame;
  void Function(String reason)? _onReceiverClosed;

  bool get isCut => _cut;
  int get binaryBytesDelivered => _binaryDelivered;

  /// Cuts it now.
  void cut() {
    if (_cut) return;
    _cut = true;
    if (cutKind == PipeCut.close) {
      _closedForGood = true;
      if (!_closedReason.isCompleted) {
        _closedReason.complete('the pipe was cut');
      }
      _onReceiverClosed?.call('the pipe was closed');
      if (!_toSender.isClosed) unawaited(_toSender.close());
      _drained.add(null);
    }
  }

  void _enqueue(PipeFrame frame) {
    if (_closedForGood) throw const LinkLost('the pipe is closed');
    queued += frame.bytes;
    _queue.add(frame);
    _pump();
  }

  void _pump() {
    if (_pumping) return;
    _pumping = true;
    scheduleMicrotask(() async {
      while (_queue.isNotEmpty) {
        final frame = _queue.removeAt(0);
        if (_cut) {
          lostFrames++;
          continue; // a black hole: still counted as queued, never drained
        }
        if (cutBeforeFrame?.call(frame) ?? false) {
          lostFrames++;
          cut();
          continue;
        }
        queued -= frame.bytes;
        delivered.add(frame);
        final handler = _onReceiverFrame;
        if (frame.isBinary) {
          _binaryDelivered += frame.bytes;
          handler?.call(RTCDataChannelMessage.fromBinary(frame.binary!));
        } else {
          handler?.call(RTCDataChannelMessage(frame.text!));
        }
        if (!_drained.isClosed) _drained.add(null);
        final limit = cutAfterBinaryBytes;
        if ((limit != null && _binaryDelivered >= limit) ||
            (cutAfterFrame?.call(frame) ?? false)) {
          cut();
        }
        // Give the receiver's handlers and the sender's loop their turn.
        await Future<void>.delayed(Duration.zero);
      }
      _pumping = false;
    });
  }

  Future<void> dispose() async {
    _closedForGood = true;
    if (!_drained.isClosed) await _drained.close();
    if (!_toSender.isClosed) await _toSender.close();
  }
}

class _PipeSender implements SenderLink {
  _PipeSender(this._pipe);
  final LinkPipe _pipe;

  @override
  int get generation => _pipe.generation;

  @override
  bool get isOpen => !_pipe._closedForGood;

  @override
  void sendText(String frame) => _pipe._enqueue(PipeFrame.text(frame));

  @override
  void sendBinary(Uint8List bytes) => _pipe._enqueue(PipeFrame.binary(bytes));

  @override
  Stream<String> get incoming => _pipe._toSender.stream;

  @override
  Future<String> get closed => _pipe._closedReason.future;

  @override
  Future<void> waitForRoom(int limit, {required Duration stallTimeout}) async {
    var last = _pipe.queued;
    var lastMove = DateTime.now();
    while (true) {
      if (_pipe._closedForGood) throw const LinkLost('the pipe is closed');
      if (_pipe.queued <= limit) return;
      if (_pipe.queued < last) {
        last = _pipe.queued;
        lastMove = DateTime.now();
      }
      if (DateTime.now().difference(lastMove) >= stallTimeout) {
        throw LinkLost('nothing left the send buffer for '
            '${stallTimeout.inMilliseconds} ms');
      }
      await Future.any<void>([
        _pipe._drained.stream.first,
        Future<void>.delayed(const Duration(milliseconds: 10)),
      ]);
    }
  }

  @override
  Future<void> close() async {
    _pipe._closedForGood = true;
    if (!_pipe._closedReason.isCompleted) {
      _pipe._closedReason.complete('the sender closed the link');
    }
    _pipe._onReceiverClosed?.call('the sender closed the link');
  }
}

class _PipeReceiver implements ReceiverLink {
  _PipeReceiver(this._pipe);
  final LinkPipe _pipe;

  @override
  int get generation => _pipe.generation;

  @override
  bool get isOpen => !_pipe._closedForGood;

  @override
  void sendText(String frame) {
    if (_pipe._closedForGood || _pipe._cut) return; // lost on the way back
    if (!_pipe._toSender.isClosed) _pipe._toSender.add(frame);
  }

  @override
  void bind({
    required void Function(RTCDataChannelMessage message) onFrame,
    required void Function(String reason) onClosed,
  }) {
    _pipe._onReceiverFrame = onFrame;
    _pipe._onReceiverClosed = onClosed;
  }

  @override
  Future<void> close() async {
    _pipe._closedForGood = true;
  }
}

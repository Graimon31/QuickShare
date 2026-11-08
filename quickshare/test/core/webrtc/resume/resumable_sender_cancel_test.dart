import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/webrtc/resume/reconnect_policy.dart';
import 'package:quickshare/core/webrtc/resume/resumable_sender.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';

class _CancelLink implements SenderLink {
  final messages = StreamController<String>.broadcast();
  final ended = Completer<String>();
  final waitingForRoom = Completer<void>();
  final cancelFrameQueued = Completer<void>();
  final permitCancelDrain = Completer<void>();
  bool blockPayload = false;
  bool holdCancelDrain = false;
  int cancelDrainCalls = 0;
  @override
  int get generation => 1;
  @override
  bool get isOpen => !ended.isCompleted;
  @override
  Stream<String> get incoming => messages.stream;
  @override
  Future<String> get closed => ended.future;
  @override
  void sendText(String frame) {
    if ((jsonDecode(frame) as Map)['type'] == TransferProtocol.cancelled &&
        !cancelFrameQueued.isCompleted) cancelFrameQueued.complete();
  }

  @override
  void sendBinary(Uint8List bytes) {}
  @override
  Future<void> waitForRoom(int limit, {required Duration stallTimeout}) async {
    if (limit == 0 && cancelFrameQueued.isCompleted) {
      cancelDrainCalls++;
      if (holdCancelDrain) await permitCancelDrain.future;
    } else if (blockPayload) {
      if (!waitingForRoom.isCompleted) waitingForRoom.complete();
      await closed;
      throw const LinkLost('peer closed after cancellation');
    }
  }

  @override
  Future<void> close() async {
    if (!ended.isCompleted) ended.complete('closed');
  }

  Future<void> dispose() async {
    await close();
    await messages.close();
  }
}

ResumableSender _sender(_CancelLink link, {SenderReconnector? reconnect}) =>
    ResumableSender(
        items: [],
        firstLink: link,
        sendWindow: 1024,
        stall: const StallPolicy(legacyHelloWait: Duration(seconds: 1)),
        policy: const ReconnectPolicy(
            maxAttempts: 1, attemptTimeout: Duration(milliseconds: 100)),
        reconnect: reconnect ??
            (_, __, ___) => throw StateError('unexpected reconnect'));

void main() {
  test('local cancellation drains the active link before allowing teardown',
      () async {
    final link = _CancelLink()..holdCancelDrain = true;
    addTearDown(link.dispose);
    final sender = _sender(link);
    var finished = false;
    final cancelling = sender.cancel().then((_) => finished = true);
    await link.cancelFrameQueued.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(link.cancelDrainCalls, 1,
        reason: 'queueing a cancellation frame is not delivery');
    expect(finished, isFalse,
        reason: 'transport teardown must wait for active-link drain');
    link.permitCancelDrain.complete();
    await cancelling;
  });

  test(
      'remote cancellation followed by channel close is terminal, not reconnect',
      () async {
    final link = _CancelLink()..blockPayload = true;
    addTearDown(link.dispose);
    var reconnects = 0;
    final sender = _sender(link, reconnect: (_, __, ___) async {
      reconnects++;
      throw StateError('cancel must not reconnect');
    });
    final failed = expectLater(
        sender.run().timeout(const Duration(seconds: 2)),
        throwsA(isA<SendFailure>()
            .having((e) => e.code, 'code', FailureCode.cancelledByReceiver)));
    link.messages.add(TransferProtocol.buildHello(generation: 1));
    await link.waitingForRoom.future;
    link.messages.add(TransferProtocol.buildCancelled());
    await Future<void>.delayed(Duration.zero);
    await link.close();
    await failed;
    expect(reconnects, 0);
  });
}

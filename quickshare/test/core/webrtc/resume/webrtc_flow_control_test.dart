import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quickshare/core/webrtc/resume/resumable_sender.dart';
import 'package:quickshare/core/webrtc/resume/webrtc_links.dart';

class _Connection extends Fake implements RTCPeerConnection {
  @override
  Future<void> close() async {}
}

// Windows' native plugin never emits bufferedAmountChange. In particular,
// bufferedAmount remains zero even while data is still in flight.
class _Channel extends RTCDataChannel {
  final sent = <RTCDataChannelMessage>[];
  _Channel? peer;
  bool holdCancelAck = false;
  final heldAcks = <RTCDataChannelMessage>[];
  int closeCalls = 0;
  @override
  RTCDataChannelState get state => RTCDataChannelState.RTCDataChannelOpen;
  @override
  int get id => 1;
  @override
  String get label => 'test';
  @override
  int get bufferedAmount => 0;
  @override
  Future<void> send(RTCDataChannelMessage message) async {
    sent.add(message);
    if (!message.isBinary &&
        holdCancelAck &&
        message.text.contains('cancel-ack')) {
      heldAcks.add(message);
      return;
    }
    scheduleMicrotask(() => peer?.onMessage?.call(message));
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }

  void receive(Map<String, Object> frame) =>
      onMessage!(RTCDataChannelMessage(jsonEncode(frame)));
}

void main() {
  test('cancellation waits for peer acknowledgement before teardown', () async {
    final outgoing = _Channel();
    final incoming = _Channel()..holdCancelAck = true;
    outgoing.peer = incoming;
    incoming.peer = outgoing;
    final sender = WebRtcSenderLink(
        generation: 1,
        connection: _Connection(),
        channel: outgoing,
        sendWindow: 1024);
    final receiver = WebRtcReceiverLink(
        generation: 1, connection: _Connection(), channel: incoming);
    var gotCancel = false;
    Future<void>? closing;
    receiver.bind(
        onFrame: (frame) {
          if (!frame.isBinary && frame.text.contains('cancelled')) {
            gotCancel = true;
            closing = receiver.close();
          }
        },
        onClosed: (_) {});
    var acknowledged = false;
    final notification = sender
        .notifyCancellation(timeout: const Duration(seconds: 1))
        .then((_) => acknowledged = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(gotCancel, isTrue);
    expect(acknowledged, isFalse);
    expect(incoming.closeCalls, 0,
        reason: 'do not drop queued acknowledgement');
    expect(incoming.heldAcks, hasLength(1));
    outgoing.onMessage!(incoming.heldAcks.single);
    await notification;
    expect(acknowledged, isTrue);
    incoming.onDataChannelState!(RTCDataChannelState.RTCDataChannelClosed);
    await closing;
    await sender.close();
    expect(incoming.closeCalls, 1);
  });

  test('receiver cancellation acknowledgement is hidden from transfer frames',
      () async {
    final outgoing = _Channel()..holdCancelAck = true;
    final incoming = _Channel();
    outgoing.peer = incoming;
    incoming.peer = outgoing;
    final sender = WebRtcSenderLink(
        generation: 1,
        connection: _Connection(),
        channel: outgoing,
        sendWindow: 1024);
    final receiver = WebRtcReceiverLink(
        generation: 1, connection: _Connection(), channel: incoming);
    final seen = <String>[];
    final sub = sender.incoming.listen(seen.add);
    final receiverFrames = <String>[];
    receiver.bind(
        onFrame: (frame) => receiverFrames.add(frame.text), onClosed: (_) {});
    var finished = false;
    final notifying = receiver
        .notifyCancellation(timeout: const Duration(seconds: 1))
        .then((_) => finished = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen.where((s) => s.contains('cancelled')), hasLength(1));
    expect(finished, isFalse);
    incoming.onMessage!(outgoing.heldAcks.single);
    await notifying;
    expect(receiverFrames, isEmpty);
    outgoing.onDataChannelState!(RTCDataChannelState.RTCDataChannelClosed);
    await sub.cancel();
    await receiver.close();
    await sender.close();
  });

  test(
      'missing cancellation acknowledgement is bounded on legacy or dead peers',
      () async {
    final channel = _Channel();
    final sender = WebRtcSenderLink(
        generation: 1,
        connection: _Connection(),
        channel: channel,
        sendWindow: 1024);
    await sender
        .notifyCancellation(timeout: const Duration(milliseconds: 20))
        .timeout(const Duration(milliseconds: 200));
    expect(channel.sent.single.text, contains('cancelled'));
    await sender.close();
  });

  test('Windows sender crosses multiple windows without native buffer events',
      () async {
    const window = 256 * 1024;
    const chunk = 64 * 1024;
    const total = 12 * 1024 * 1024;
    final outgoing = _Channel();
    final incoming = _Channel();
    outgoing.peer = incoming;
    incoming.peer = outgoing;
    final sender = WebRtcSenderLink(
        generation: 1,
        connection: _Connection(),
        channel: outgoing,
        sendWindow: window);
    final receiver = WebRtcReceiverLink(
        generation: 1, connection: _Connection(), channel: incoming);
    addTearDown(sender.close);
    addTearDown(receiver.close);
    var received = 0;
    receiver.bind(
        onFrame: (frame) {
          if (frame.isBinary) received += frame.binary.length;
        },
        onClosed: (reason) => fail(reason));
    await Future<void>.delayed(Duration.zero);
    for (var offset = 0; offset < total; offset += chunk) {
      sender.sendBinary(Uint8List(chunk));
      await sender.waitForRoom(window,
          stallTimeout: const Duration(milliseconds: 500));
    }
    await sender.waitForRoom(0,
        stallTimeout: const Duration(milliseconds: 500));
    expect(received, total);
    expect(sender.queuedBytes, 0);
    expect(sender.isOpen, isTrue);
  });

  test('flow control is hidden from transfer engine and counts UTF-8 bytes',
      () async {
    final channel = _Channel();
    final sender = WebRtcSenderLink(
        generation: 1,
        connection: _Connection(),
        channel: channel,
        sendWindow: 128);
    addTearDown(sender.close);
    final seen = <String>[];
    final subscription = sender.incoming.listen(seen.add);
    addTearDown(subscription.cancel);
    channel.receive({'__directdropFlow': 'ready'});
    sender.sendText('файл');
    channel.receive(
        {'__directdropFlow': 'ack', 'bytes': utf8.encode('файл').length});
    channel.onMessage!(RTCDataChannelMessage('application frame'));
    await Future<void>.delayed(Duration.zero);
    expect(sender.queuedBytes, 0);
    expect(seen, ['application frame']);
  });

  test('invalid ACKs and stale native zero never release unreceived payload',
      () async {
    final channel = _Channel();
    final sender = WebRtcSenderLink(
        generation: 1,
        connection: _Connection(),
        channel: channel,
        sendWindow: 64);
    addTearDown(sender.close);
    channel.receive({'__directdropFlow': 'ready'});
    sender.sendBinary(Uint8List(128));
    for (final value in <Object>[-1, 999, '128', 1.5]) {
      channel.receive({'__directdropFlow': 'ack', 'bytes': value});
    }
    channel.onBufferedAmountChange?.call(0, 128);
    expect(sender.queuedBytes, 128);
    await expectLater(
        sender.waitForRoom(64, stallTimeout: const Duration(milliseconds: 50)),
        throwsA(isA<LinkLost>()));
  });

  test('ACK waits for receiver processing instead of merely queueing a write',
      () async {
    final outgoing = _Channel();
    final incoming = _Channel();
    outgoing.peer = incoming;
    incoming.peer = outgoing;
    final sender = WebRtcSenderLink(
        generation: 1,
        connection: _Connection(),
        channel: outgoing,
        sendWindow: 64);
    final receiver = WebRtcReceiverLink(
        generation: 1, connection: _Connection(), channel: incoming);
    addTearDown(sender.close);
    addTearDown(receiver.close);
    final written = Completer<void>();
    receiver.waitForHandledFrame = () => written.future;
    receiver.bind(onFrame: (_) {}, onClosed: (reason) => fail(reason));
    await Future<void>.delayed(Duration.zero);
    sender.sendBinary(Uint8List(128));
    await Future<void>.delayed(Duration.zero);
    expect(sender.queuedBytes, 128);
    var drained = false;
    final drain = sender
        .waitForRoom(0, stallTimeout: const Duration(seconds: 1))
        .then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(drained, isFalse);
    written.complete();
    await drain;
    expect(sender.queuedBytes, 0);
  });

  test('duplicate or backwards ACKs cannot grant extra room', () async {
    final channel = _Channel();
    final sender = WebRtcSenderLink(
        generation: 1,
        connection: _Connection(),
        channel: channel,
        sendWindow: 128);
    addTearDown(sender.close);
    channel.receive({'__directdropFlow': 'ready'});
    sender.sendBinary(Uint8List(128));
    channel.receive({'__directdropFlow': 'ack', 'bytes': 64});
    sender.sendBinary(Uint8List(64));
    channel.receive({'__directdropFlow': 'ack', 'bytes': 64});
    channel.receive({'__directdropFlow': 'ack', 'bytes': 32});
    expect(sender.queuedBytes, 128);
    channel.receive({'__directdropFlow': 'ack', 'bytes': 192});
    await sender.waitForRoom(0, stallTimeout: const Duration(milliseconds: 50));
    expect(sender.queuedBytes, 0);
  });
  test('failed receiver write closes link without acknowledging payload',
      () async {
    final channel = _Channel();
    final receiver = WebRtcReceiverLink(
        generation: 1, connection: _Connection(), channel: channel);
    addTearDown(receiver.close);
    final written = Completer<void>();
    final closed = Completer<String>();
    receiver.waitForHandledFrame = () => written.future;
    receiver.bind(onFrame: (_) {}, onClosed: closed.complete);
    channel.onMessage!(RTCDataChannelMessage.fromBinary(Uint8List(128)));
    written.completeError(StateError('disk write failed'));
    expect(await closed.future.timeout(const Duration(seconds: 1)),
        contains('handling a received frame failed'));
    expect(receiver.isOpen, isFalse);
    final controls = channel.sent
        .where((m) => !m.isBinary)
        .map((m) => jsonDecode(m.text) as Map);
    expect(controls.where((m) => m['__directdropFlow'] == 'ack'), isEmpty);
  });

  test('late or repeated ready never resets bytes already acknowledged',
      () async {
    final channel = _Channel();
    final sender = WebRtcSenderLink(
        generation: 1,
        connection: _Connection(),
        channel: channel,
        sendWindow: 128);
    addTearDown(sender.close);
    sender.sendBinary(Uint8List(128));
    channel.receive({'__directdropFlow': 'ack', 'bytes': 128});
    expect(sender.queuedBytes, 128,
        reason: 'ACK before negotiation is ignored');
    channel.receive({'__directdropFlow': 'ready'});
    expect(sender.queuedBytes, 128);
    channel.receive({'__directdropFlow': 'ack', 'bytes': 64});
    channel.receive({'__directdropFlow': 'ready'});
    expect(sender.queuedBytes, 64);
  });
}

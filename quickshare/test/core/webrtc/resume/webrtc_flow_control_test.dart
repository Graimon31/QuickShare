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
    scheduleMicrotask(() => peer?.onMessage?.call(message));
  }

  @override
  Future<void> close() async {}
  void receive(Map<String, Object> frame) =>
      onMessage!(RTCDataChannelMessage(jsonEncode(frame)));
}

void main() {
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
}

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quickshare/core/webrtc/resume/resumable_sender.dart';
import 'package:quickshare/core/webrtc/resume/webrtc_links.dart';

class _Connection extends Fake implements RTCPeerConnection {
  @override
  Future<void> close() async {}
}

class _Channel extends RTCDataChannel {
  RTCDataChannelState currentState = RTCDataChannelState.RTCDataChannelOpen;
  final sent = <RTCDataChannelMessage>[];
  bool failSend = false;

  @override
  RTCDataChannelState get state => currentState;
  @override
  int get id => 1;
  @override
  String get label => 'test';
  @override
  int get bufferedAmount => 0;

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    if (failSend) throw StateError('native send failed');
    sent.add(message);
  }

  @override
  Future<void> close() async {}
}

void main() {
  for (final binary in [false, true]) {
    test(
        'an asynchronous ${binary ? 'payload' : 'text'} send failure kills '
        'the sender link and wakes backpressure', () async {
      final channel = _Channel()..failSend = true;
      final link = WebRtcSenderLink(
          generation: 1,
          connection: _Connection(),
          channel: channel,
          sendWindow: 1);
      addTearDown(link.close);

      if (binary) {
        link.sendBinary(Uint8List(128));
      } else {
        link.sendText('a control frame');
      }
      final drain =
          link.waitForRoom(0, stallTimeout: const Duration(seconds: 10));
      await expectLater(drain, throwsA(isA<LinkLost>()));
      expect(await link.closed, contains('sending'));
      expect(link.isOpen, isFalse);
    });
  }

  for (final queued in [false, true]) {
    test(
        'an asynchronous receiver send failure is reported '
        '${queued ? 'after opening' : 'on an open channel'}', () async {
      final channel = _Channel()
        ..failSend = true
        ..currentState = queued
            ? RTCDataChannelState.RTCDataChannelConnecting
            : RTCDataChannelState.RTCDataChannelOpen;
      final link = WebRtcReceiverLink(
          generation: 1, connection: _Connection(), channel: channel);
      addTearDown(link.close);
      final closed = Completer<String>();
      link.bind(onFrame: (_) {}, onClosed: closed.complete);
      link.sendText('hello');
      if (queued) {
        channel.currentState = RTCDataChannelState.RTCDataChannelOpen;
        channel.onDataChannelState!(channel.currentState);
      }

      expect(await closed.future.timeout(const Duration(seconds: 1)),
          contains('sending'));
      expect(link.isOpen, isFalse);
    });
  }

  test('queued receiver frames leave in order when the channel opens',
      () async {
    final channel = _Channel()
      ..currentState = RTCDataChannelState.RTCDataChannelConnecting;
    final link = WebRtcReceiverLink(
        generation: 1, connection: _Connection(), channel: channel);
    addTearDown(link.close);
    link.sendText('hello');
    link.sendText('done');
    expect(channel.sent, isEmpty);

    channel.currentState = RTCDataChannelState.RTCDataChannelOpen;
    channel.onDataChannelState!(channel.currentState);

    expect(channel.sent.map((m) => m.text), ['hello', 'done']);
    expect(link.isOpen, isTrue);
  });
}

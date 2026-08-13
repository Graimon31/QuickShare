// Drives the real Node signaling server with two real WebRtcSignalingClient
// instances over a real socket — the exact handshake the macOS link transfer
// depends on.
//
// WebRTC itself needs platform channels and cannot run under `flutter test`,
// so this covers everything up to (and including) offer/answer/ICE exchange:
// the layer that was previously broken, where the receiver called signaling
// methods that did not exist.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/features/sender/data/signaling/webrtc_signaling_client.dart';

const _port = 3996;
final _serverPath = Directory.current.path + '/signaling_server/server.js';

void main() {
  late Process server;

  setUpAll(() async {
    server = await Process.start(
      'node',
      [_serverPath],
      environment: {...Platform.environment, 'PORT': '$_port'},
    );
    // Wait for the listener to bind.
    await Future.delayed(const Duration(milliseconds: 900));
  });

  tearDownAll(() async {
    server.kill();
  });

  test('sender creates a room and receives receiver-joined when a peer joins', () async {
    final sender = WebRtcSignalingClient(serverUrl: 'ws://127.0.0.1:$_port');
    final receiver = WebRtcSignalingClient(serverUrl: 'ws://127.0.0.1:$_port');

    final code = await sender.createRoom();
    expect(code, matches(RegExp(r'^[A-F0-9]{6}$')));

    final joinedSignal = sender.messages.firstWhere((m) => m['type'] == 'receiver-joined');
    await receiver.joinRoom(code);

    await joinedSignal.timeout(const Duration(seconds: 5));

    await sender.dispose();
    await receiver.dispose();
  });

  test('offer, answer and ICE candidates round-trip between the two peers', () async {
    final sender = WebRtcSignalingClient(serverUrl: 'ws://127.0.0.1:$_port');
    final receiver = WebRtcSignalingClient(serverUrl: 'ws://127.0.0.1:$_port');

    final code = await sender.createRoom();
    final senderSawReceiver = sender.messages.firstWhere((m) => m['type'] == 'receiver-joined');
    await receiver.joinRoom(code);
    await senderSawReceiver.timeout(const Duration(seconds: 5));

    // Sender -> receiver: offer
    final offerAtReceiver = receiver.messages.firstWhere((m) => m['type'] == 'offer');
    sender.sendOffer({'sdp': 'v=0-fake-offer', 'type': 'offer'});
    final offer = await offerAtReceiver.timeout(const Duration(seconds: 5));
    expect(offer['payload']['sdp'], 'v=0-fake-offer');

    // Receiver -> sender: answer
    final answerAtSender = sender.messages.firstWhere((m) => m['type'] == 'answer');
    receiver.sendAnswer({'sdp': 'v=0-fake-answer', 'type': 'answer'});
    final answer = await answerAtSender.timeout(const Duration(seconds: 5));
    expect(answer['payload']['sdp'], 'v=0-fake-answer');

    // Both directions: ICE
    final iceAtReceiver = receiver.messages.firstWhere((m) => m['type'] == 'ice-candidate');
    sender.sendIceCandidate({'candidate': 'candidate:1 udp', 'sdpMid': '0', 'sdpMLineIndex': 0});
    final ice = await iceAtReceiver.timeout(const Duration(seconds: 5));
    expect(ice['payload']['candidate'], 'candidate:1 udp');
    expect(ice['payload']['sdpMLineIndex'], 0);

    await sender.dispose();
    await receiver.dispose();
  });

  test('joining a nonexistent room fails instead of hanging', () async {
    final receiver = WebRtcSignalingClient(serverUrl: 'ws://127.0.0.1:$_port');
    await expectLater(
      receiver.joinRoom('ZZZZZZ'),
      throwsA(isA<SignalingException>()),
    );
    await receiver.dispose();
  });
}

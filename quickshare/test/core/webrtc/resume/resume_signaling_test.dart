// The two ends of a transfer finding each other again through the public
// mailbox, which can read, drop, repeat and forge anything. Only a message that
// opens as the right kind, for the right link, under this transfer's keys, is
// ever acted on.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/webrtc/resume/resume_keys.dart';
import 'package:quickshare/core/webrtc/resume/resume_signaling.dart';

import '../../../support/fake_mailbox.dart';

Uint8List _bytes(List<int> v) => Uint8List.fromList(v);

void main() {
  late FakeMailboxHub hub;
  late ResumeKeys keys;
  late ResumeKeys strangerKeys;
  late ResumeSenderSignaling sender;
  late ResumeReceiverSignaling receiver;
  late List<ResumeOffer> heard;

  Uint8List fingerprint(String s) =>
      Uint8List.fromList(sha256.convert(s.codeUnits).bytes);

  setUp(() async {
    hub = FakeMailboxHub();
    keys = ResumeKeys.derive(
        seed: Uint8List.fromList(List.filled(16, 1)),
        offerFingerprint: fingerprint('offer'));
    strangerKeys = ResumeKeys.derive(
        seed: Uint8List.fromList(List.filled(16, 2)),
        offerFingerprint: fingerprint('offer'));
    sender = ResumeSenderSignaling(
        mailbox: hub.endpoint('sender'),
        keys: keys,
        republishEvery: const Duration(milliseconds: 40));
    receiver = ResumeReceiverSignaling(
        mailbox: hub.endpoint('receiver'),
        keys: keys,
        republishEvery: const Duration(milliseconds: 40));
    heard = [];
    receiver.offers.listen(heard.add);
    receiver.startFrom(1);
  });

  tearDown(() async {
    await sender.close();
    await receiver.close();
  });

  Future<void> settle([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  group('a reconnection, start to finish', () {
    test('the offer reaches the receiver and its answer reaches the sender',
        () async {
      await sender.open();
      await receiver.open();

      final answered = sender.offer(
          generation: 2,
          offerSdp: _bytes([1, 2, 3]),
          timeout: const Duration(seconds: 2));
      await settle();
      expect(heard, hasLength(1));
      expect(heard.single.generation, 2);
      expect(heard.single.sdp, [1, 2, 3]);

      receiver.answer(
          generation: 2,
          answerSdp: _bytes([9, 9]),
          forAtMost: const Duration(seconds: 1));
      expect(await answered, [9, 9]);
    });

    test(
        'the offer is said again until somebody is there to hear it: a '
        'receiver that subscribed late still gets it', () async {
      await sender.open();
      final answered = sender.offer(
          generation: 2,
          offerSdp: _bytes([5]),
          timeout: const Duration(seconds: 2));
      await settle(120); // nobody is listening yet; the mailbox keeps nothing
      expect(heard, isEmpty);

      await receiver.open();
      await settle(120);
      expect(heard, hasLength(1), reason: 'a later copy was heard');
      receiver.answer(
          generation: 2,
          answerSdp: _bytes([6]),
          forAtMost: const Duration(seconds: 1));
      expect(await answered, [6]);
    });

    test('an offer that nobody answers ends in a timeout, not a hang',
        () async {
      await sender.open();
      await expectLater(
          sender.offer(
              generation: 2,
              offerSdp: _bytes([1]),
              timeout: const Duration(milliseconds: 200)),
          throwsA(isA<ResumeSignalingTimeout>()));
    });

    test('a mailbox that is down for a while costs time, not the attempt',
        () async {
      await sender.open();
      await receiver.open();
      final senderBox = hub.endpoint('flaky');
      final flaky = ResumeSenderSignaling(
          mailbox: senderBox,
          keys: keys,
          republishEvery: const Duration(milliseconds: 40));
      await flaky.open();
      senderBox.down = true;
      final answered = flaky.offer(
          generation: 2,
          offerSdp: _bytes([4]),
          timeout: const Duration(seconds: 2));
      await settle(150);
      expect(heard, isEmpty);
      senderBox.down = false;
      await settle(120);
      expect(heard, hasLength(1));
      receiver.answer(
          generation: 2,
          answerSdp: _bytes([8]),
          forAtMost: const Duration(seconds: 1));
      // The answer needs the flaky box to hear it, which it can again.
      expect(await answered, [8]);
      await flaky.close();
    });
  });

  group('the receiver acts only on a genuine, new offer', () {
    setUp(() async {
      await receiver.open();
    });

    test('an offer sealed by a stranger who has not the seed is ignored',
        () async {
      final forged = await strangerKeys.seal(
          kind: ResumeKind.offer, generation: 2, plaintext: _bytes([1]));
      hub.inject(keys.offerTopic, forged);
      await settle();
      expect(heard, isEmpty);
      expect(receiver.highestGeneration, 1,
          reason: 'a stranger cannot move the receiver on');
    });

    test('an answer put on the offer topic is not an offer', () async {
      final answer = await keys.seal(
          kind: ResumeKind.answer, generation: 2, plaintext: _bytes([1]));
      hub.inject(keys.offerTopic, answer);
      await settle();
      expect(heard, isEmpty);
    });

    test('garbage, an empty message and an oversized one are ignored',
        () async {
      hub.inject(keys.offerTopic, Uint8List(0));
      hub.inject(keys.offerTopic, Uint8List(40));
      hub.inject(keys.offerTopic, Uint8List(ResumeKeys.maxEnvelopeBytes + 10));
      await settle();
      expect(heard, isEmpty);
      expect(receiver.ignored, greaterThanOrEqualTo(3));
    });

    test('a recorded offer played back later is dropped: its link is taken',
        () async {
      final recorded = await keys.seal(
          kind: ResumeKind.offer, generation: 2, plaintext: _bytes([1]));
      hub.inject(keys.offerTopic, recorded);
      await settle();
      expect(heard, hasLength(1));

      hub.inject(keys.offerTopic, recorded);
      hub.inject(keys.offerTopic, recorded);
      await settle();
      expect(heard, hasLength(1), reason: 'the replay was not acted on');
    });

    test('an older link than the one already taken is ignored', () async {
      final three = await keys.seal(
          kind: ResumeKind.offer, generation: 3, plaintext: _bytes([3]));
      final two = await keys.seal(
          kind: ResumeKind.offer, generation: 2, plaintext: _bytes([2]));
      hub.inject(keys.offerTopic, three);
      await settle();
      hub.inject(keys.offerTopic, two);
      await settle();
      expect(heard.map((o) => o.generation), [3]);
    });

    test(
        'the link that is already up is not an offer: nothing at or below it '
        'is acted on', () async {
      final one = await keys.seal(
          kind: ResumeKind.offer, generation: 1, plaintext: _bytes([1]));
      hub.inject(keys.offerTopic, one);
      await settle();
      expect(heard, isEmpty);
    });

    test('a newer offer is taken even when an earlier attempt was lost',
        () async {
      // Link 2 never arrived; the sender went on to link 3.
      final three = await keys.seal(
          kind: ResumeKind.offer, generation: 3, plaintext: _bytes([3]));
      hub.inject(keys.offerTopic, three);
      await settle();
      expect(heard.single.generation, 3);
    });

    test('flipping the generation of a genuine offer does not make it newer',
        () async {
      final real = await keys.seal(
          kind: ResumeKind.offer, generation: 2, plaintext: _bytes([2]));
      final bent = Uint8List.fromList(real)..[3] = 7;
      hub.inject(keys.offerTopic, bent);
      await settle();
      expect(heard, isEmpty);
      expect(receiver.highestGeneration, 1,
          reason: 'a message that does not open does not move the counter');
    });
  });

  group('the sender acts only on the genuine answer to its own offer', () {
    setUp(() async {
      await sender.open();
    });

    test('a stranger\'s answer does not end the wait', () async {
      final result = sender.offer(
          generation: 2,
          offerSdp: _bytes([1]),
          timeout: const Duration(milliseconds: 400));
      await settle();
      hub.inject(
          keys.answerTopic,
          await strangerKeys.seal(
              kind: ResumeKind.answer, generation: 2, plaintext: _bytes([66])));
      await expectLater(result, throwsA(isA<ResumeSignalingTimeout>()));
      expect(sender.ignored, greaterThanOrEqualTo(1));
    });

    test('an answer for another link is not the answer to this offer',
        () async {
      final result = sender.offer(
          generation: 3,
          offerSdp: _bytes([1]),
          timeout: const Duration(milliseconds: 400));
      await settle();
      hub.inject(
          keys.answerTopic,
          await keys.seal(
              kind: ResumeKind.answer, generation: 2, plaintext: _bytes([2])));
      await expectLater(result, throwsA(isA<ResumeSignalingTimeout>()));
    });

    test('an offer played back on the answer topic is not an answer', () async {
      final result = sender.offer(
          generation: 2,
          offerSdp: _bytes([1]),
          timeout: const Duration(milliseconds: 400));
      await settle();
      hub.inject(
          keys.answerTopic,
          await keys.seal(
              kind: ResumeKind.offer, generation: 2, plaintext: _bytes([2])));
      await expectLater(result, throwsA(isA<ResumeSignalingTimeout>()));
    });

    test('an answer that arrives with nothing being waited for is dropped',
        () async {
      hub.inject(
          keys.answerTopic,
          await keys.seal(
              kind: ResumeKind.answer, generation: 2, plaintext: _bytes([2])));
      await settle();
      // And it is still not the answer to an offer made afterwards.
      final result = sender.offer(
          generation: 2,
          offerSdp: _bytes([1]),
          timeout: const Duration(milliseconds: 300));
      await expectLater(result, throwsA(isA<ResumeSignalingTimeout>()));
    });

    test('the genuine answer still wins after the junk', () async {
      final result = sender.offer(
          generation: 2,
          offerSdp: _bytes([1]),
          timeout: const Duration(seconds: 2));
      await settle();
      hub.inject(keys.answerTopic, Uint8List(64));
      hub.inject(
          keys.answerTopic,
          await strangerKeys.seal(
              kind: ResumeKind.answer, generation: 2, plaintext: _bytes([66])));
      hub.inject(
          keys.answerTopic,
          await keys.seal(
              kind: ResumeKind.answer, generation: 2, plaintext: _bytes([7])));
      expect(await result, [7]);
    });

    test('closing mid-wait ends the wait', () async {
      final result = sender.offer(
          generation: 2,
          offerSdp: _bytes([1]),
          timeout: const Duration(seconds: 5));
      await settle();
      final ended = expectLater(result, throwsStateError);
      await sender.close();
      await ended;
    });
  });

  group('what the mailbox operator learns', () {
    test('only that two parties exchange small messages on two topics',
        () async {
      await sender.open();
      await receiver.open();
      final answered = sender.offer(
          generation: 2,
          offerSdp: _bytes(List.filled(400, 5)),
          timeout: const Duration(seconds: 2));
      await settle();
      receiver.answer(
          generation: 2,
          answerSdp: _bytes(List.filled(400, 6)),
          forAtMost: const Duration(seconds: 1));
      await answered;

      final topics = hub.published.map((m) => m.topic).toSet();
      expect(topics, {keys.offerTopic, keys.answerTopic});
      for (final m in hub.published) {
        // The plaintext (400 repeated bytes) is not visible in any form.
        expect(m.payload.where((b) => b == 5).length, lessThan(40),
            reason: 'ciphertext is not the plaintext');
      }
    });
  });
}

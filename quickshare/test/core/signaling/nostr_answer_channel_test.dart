import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/crypto/bip340.dart';
import 'package:quickshare/core/signaling/nostr_answer_channel.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';

Uint8List _unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

void main() {
  group('NostrAnswerChannel event construction', () {
    // No sockets here. These assertions cover exactly what a relay checks
    // before it will forward an event, so a break shows up locally rather
    // than as a silent "answer never arrived" in the field.
    late NostrAnswerChannel channel;
    final payload = Uint8List.fromList(List<int>.generate(212, (i) => i % 256));
    const topic = 'nEZ4h-Qs_1tPqAAbCdEf9g';

    setUp(() {
      channel = NostrAnswerChannel(relays: const []);
    });

    test('event id is the SHA-256 of the canonical NIP-01 serialization', () {
      final event = channel.buildEvent(topic, payload);
      final serialized = jsonEncode([
        0,
        event['pubkey'],
        event['created_at'],
        event['kind'],
        event['tags'],
        event['content'],
      ]);
      final expected = sha256.convert(utf8.encode(serialized)).bytes;
      expect(event['id'], equals(_hex(Uint8List.fromList(expected))));
    });

    test('signature verifies against the embedded pubkey', () {
      final event = channel.buildEvent(topic, payload);
      expect(
        Bip340.verify(
          _unhex(event['id'] as String),
          _unhex(event['pubkey'] as String),
          _unhex(event['sig'] as String),
        ),
        isTrue,
      );
    });

    test('uses the ephemeral kind so relays keep no copy', () {
      expect(channel.buildEvent(topic, payload)['kind'], equals(20000));
      expect(NostrAnswerChannel.eventKind, inInclusiveRange(20000, 29999));
    });

    test('tags the event with the derived topic so relays can filter', () {
      expect(channel.buildEvent(topic, payload)['tags'],
          equals([['t', topic]]));
    });

    test('round-trips the payload through the content field', () {
      final event = channel.buildEvent(topic, payload);
      expect(base64.decode(event['content'] as String), equals(payload));
    });

    test('a fresh channel uses a fresh identity', () {
      final a = NostrAnswerChannel(relays: const []).buildEvent(topic, payload);
      final b = NostrAnswerChannel(relays: const []).buildEvent(topic, payload);
      expect(a['pubkey'], isNot(equals(b['pubkey'])),
          reason: 'a stable key would let a relay link transfers together');
    });

    test('subscription id stays inside the 64-character relay limit', () {
      final long = 'x' * 200;
      expect(channel.subscriptionId(long).length, lessThanOrEqualTo(64));
      // Base64url topics carry - and _, which relays are not obliged to accept
      // in a subscription id.
      expect(channel.subscriptionId('ab-cd_ef'), equals('qsabcdef'));
    });

    test('subscribe fails loudly when no relay can be reached', () {
      expect(
        () => NostrAnswerChannel(relays: const []).subscribe(topic),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('topic derivation', () {
    test('a Nostr tag built from a seed carries no key material', () async {
      final seed = SealedEnvelope.newSeed();
      final topic = await SealedEnvelope.deriveTopic(seed);
      // The topic is what a relay operator sees. It must not be the seed.
      expect(topic, isNotEmpty);
      expect(topic, isNot(contains(base64Url.encode(seed).replaceAll('=', ''))));
    });

    test('the same seed always names the same drop point', () async {
      final seed = SealedEnvelope.newSeed();
      expect(await SealedEnvelope.deriveTopic(seed),
          equals(await SealedEnvelope.deriveTopic(seed)));
    });
  });
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

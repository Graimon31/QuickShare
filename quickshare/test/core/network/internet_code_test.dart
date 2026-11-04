// The parts of finding an internet sender by its code that need no network:
// what a topic reveals, what a message may look like, the key schedule and the
// seal.
//
// The model is a public mailbox whose operator reads everything and may forge
// anything. The first group is the one that matters most: the topic is the one
// thing derived from the code that the whole world can see, and it must tell
// nobody more than twelve bits.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/internet_code.dart';
import 'package:quickshare/core/network/session_code.dart';

Uint8List _bytes(Object json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  group('the request topic', () {
    test('is a function of twelve bits of the code and of nothing else', () {
      final random = Random(7);
      final byBucket = <int, List<SessionCode>>{};
      // Four thousand and ninety-six buckets: a few tens of thousands of codes
      // are enough to find many that share one.
      for (var i = 0; i < 40000; i++) {
        final code = SessionCode.generate(random);
        byBucket.putIfAbsent(InternetCode.bucket(code), () => []).add(code);
      }
      final shared =
          byBucket.values.where((codes) => codes.length >= 5).toList();
      expect(shared, isNotEmpty);

      for (final codes in shared.take(50)) {
        final topics = codes.map(InternetCode.requestTopic).toSet();
        expect(topics, hasLength(1),
            reason: 'codes with the same twelve bits cannot be told apart by '
                'the topic they publish on');
      }
      // Codes that differ in those twelve bits do not share a topic.
      final topicOfBucket = {
        for (final entry in byBucket.entries)
          entry.key: InternetCode.requestTopic(entry.value.first),
      };
      expect(topicOfBucket.values.toSet(), hasLength(topicOfBucket.length));
    });

    test('takes at most 4096 values, however many codes there are', () {
      final random = Random(11);
      final topics = <String>{};
      for (var i = 0; i < 30000; i++) {
        topics.add(InternetCode.requestTopic(SessionCode.generate(random)));
      }
      expect(topics.length, lessThanOrEqualTo(4096));
      expect(topics.length, greaterThan(3500),
          reason: 'the twelve bits should all be in use');
    });

    test('is spelled the way the Worker accepts a room id', () {
      final roomId = RegExp(r'^[A-Za-z0-9_-]{16,64}$');
      final random = Random(3);
      for (var i = 0; i < 200; i++) {
        final topic = InternetCode.requestTopic(SessionCode.generate(random));
        expect(topic, hasLength(22));
        expect(roomId.hasMatch(topic), isTrue, reason: topic);
      }
      expect(roomId.hasMatch(InternetCode.newReplyTopic()), isTrue);
    });

    test('does not contain the code, its public id or its discovery hint', () {
      final random = Random(5);
      for (var i = 0; i < 200; i++) {
        final code = SessionCode.generate(random);
        final topic = InternetCode.requestTopic(code);
        expect(topic.contains(code.code), isFalse);
        expect(topic.contains(code.publicId), isFalse);
        expect(topic, isNot(code.sessionToken.substring(0, 22)));
      }
    });

    test('is not the topic the LAN hint or the public id would give', () {
      // The twelve bits come from their own domain, so the eight a LAN
      // announcement reveals and the twelve a topic reveals are independent.
      final random = Random(9);
      var agreements = 0;
      const trials = 4000;
      for (var i = 0; i < trials; i++) {
        final code = SessionCode.generate(random);
        final hintByte = int.parse(code.discoveryHint, radix: 16);
        if ((InternetCode.bucket(code) >> 4) == hintByte) agreements++;
      }
      // Independent bytes agree one time in 256.
      expect(agreements, lessThan(trials ~/ 64));
    });
  });

  group('requests', () {
    final n = Uint8List.fromList(List.generate(16, (i) => i + 1));
    final pA = Uint8List.fromList([4, ...List.generate(64, (i) => i)]);
    final reply = InternetCode.newReplyTopic();
    final good = CodeRequest(n: n, pA: pA, reply: reply, ts: 1800000000);

    test('survive a round trip', () {
      final parsed = CodeRequest.tryParse(good.encode())!;
      expect(parsed.n, n);
      expect(parsed.pA, pA);
      expect(parsed.reply, reply);
      expect(parsed.ts, 1800000000);
    });

    test('carry the code nowhere in the clear', () {
      final text = utf8.decode(good.encode());
      expect(text, isNot(contains('QS1')));
      expect(jsonDecode(text).keys, unorderedEquals(['v', 'n', 'pA', 'reply', 'ts']));
    });

    test('are refused when oversized, before anything is parsed', () {
      final padded = Uint8List.fromList(
          [...good.encode(), ...List.filled(InternetCode.maxRequestBytes, 32)]);
      expect(CodeRequest.tryParse(padded), isNull);
    });

    test('are refused when they are not exactly the shape', () {
      Map<String, Object?> body() => jsonDecode(utf8.decode(good.encode()))
          as Map<String, Object?>;

      expect(CodeRequest.tryParse(Uint8List(0)), isNull);
      expect(CodeRequest.tryParse(_bytes([1, 2, 3])), isNull);
      expect(CodeRequest.tryParse(Uint8List.fromList([0xff, 0xfe, 0x00])), isNull);
      expect(CodeRequest.tryParse(Uint8List.fromList(utf8.encode('{"v":'))), isNull);

      expect(CodeRequest.tryParse(_bytes(body()..['v'] = 2)), isNull);
      expect(CodeRequest.tryParse(_bytes(body()..['v'] = '1')), isNull);
      expect(CodeRequest.tryParse(_bytes(body()..remove('n'))), isNull);
      expect(CodeRequest.tryParse(_bytes(body()..['n'] = 'short')), isNull);
      expect(CodeRequest.tryParse(_bytes(body()..['n'] = 42)), isNull);
      expect(
          CodeRequest.tryParse(
              _bytes(body()..['pA'] = InternetCode.encode(Uint8List(64)))),
          isNull,
          reason: 'a share is 65 bytes');
      expect(CodeRequest.tryParse(_bytes(body()..['reply'] = 'x' * 22)), isNull,
          reason: 'not canonical base64 of sixteen bytes');
      expect(CodeRequest.tryParse(_bytes(body()..['reply'] = '${reply}A')),
          isNull);
      expect(CodeRequest.tryParse(_bytes(body()..['reply'] = 'a' * 4000)),
          isNull);
      expect(CodeRequest.tryParse(_bytes(body()..['ts'] = 1.5)), isNull);
      expect(CodeRequest.tryParse(_bytes(body()..['ts'] = '1800000000')), isNull);
      expect(CodeRequest.tryParse(_bytes(body()..['ts'] = -1)), isNull);
      expect(CodeRequest.tryParse(_bytes(body()..['ts'] = 1 << 60)), isNull);
    });
  });

  group('replies', () {
    final pB = Uint8List.fromList([4, ...List.generate(64, (i) => 200 - i)]);
    final cB = Uint8List.fromList(List.generate(32, (i) => i));

    test('survive a round trip and are told apart by version', () {
      final encoded = CodeReply(pB: pB, cB: cB).encode();
      final parsed = CodeReply.tryParse(encoded)!;
      expect(parsed.pB, pB);
      expect(parsed.cB, cB);
      expect(CodeReply.isOtherVersion(encoded), isFalse);

      final newer = _bytes({
        'v': 2,
        'pB': InternetCode.encode(pB),
        'cB': InternetCode.encode(cB),
      });
      expect(CodeReply.tryParse(newer), isNull);
      expect(CodeReply.isOtherVersion(newer), isTrue);
      expect(CodeReply.isOtherVersion(Uint8List.fromList([1, 2, 3])), isFalse,
          reason: 'garbage is not another version');
    });

    test('are refused when oversized or malformed', () {
      expect(CodeReply.tryParse(Uint8List(0)), isNull);
      expect(CodeReply.tryParse(Uint8List(InternetCode.maxReplyBytes + 1)),
          isNull);
      expect(
          CodeReply.tryParse(_bytes({
            'v': 1,
            'pB': InternetCode.encode(pB),
            'cB': InternetCode.encode(cB.sublist(1)),
          })),
          isNull);
      expect(CodeReply.tryParse(_bytes({'v': 1, 'pB': 1, 'cB': 2})), isNull);
    });
  });

  group('device names from the public', () {
    test('are shown as one short line of plain text', () {
      expect(InternetCode.cleanName('  Alice\u0007\u0000 laptop  '),
          'Alice laptop');
      expect(InternetCode.cleanName('line one\nline two'), 'line one line two');
      expect(InternetCode.cleanName('a' * 200).runes.length,
          InternetCode.maxNameChars);
      expect(InternetCode.cleanName('😀' * 100).runes.length,
          InternetCode.maxNameChars);
    });

    test('cannot reverse, hide or reorder the text around them', () {
      for (final mark in [0x202e, 0x202d, 0x2066, 0x2067, 0x2069, 0x200f,
          0x200b, 0x061c, 0xfeff]) {
        final cleaned =
            InternetCode.cleanName('x${String.fromCharCode(mark)}y');
        expect(cleaned.runes.contains(mark), isFalse,
            reason: 'U+${mark.toRadixString(16)} survived');
      }
    });

    test('are kept as data: markup stays markup', () {
      expect(InternetCode.cleanName('<b>Bob</b> & \$(rm -rf)'),
          '<b>Bob</b> & \$(rm -rf)');
    });
  });

  group('the key schedule', () {
    final ke = Uint8List.fromList(List.generate(16, (i) => 255 - i));
    final n = Uint8List.fromList(List.generate(16, (i) => i));

    test('gives a key and two topics, distinct from one another', () {
      final keys = InternetCodeKeys.derive(ke, n);
      expect(keys.aeadKey, hasLength(32));
      expect(keys.confirmTopic, hasLength(22));
      expect(keys.payloadTopic, hasLength(22));
      expect(keys.confirmTopic, isNot(keys.payloadTopic));
      expect(RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(keys.confirmTopic), isTrue);
    });

    test('depends on both Ke and n', () {
      final base = InternetCodeKeys.derive(ke, n);
      final otherN = InternetCodeKeys.derive(
          ke, Uint8List.fromList(List.generate(16, (i) => i + 1)));
      final otherKe = InternetCodeKeys.derive(
          Uint8List.fromList(List.generate(16, (i) => i)), n);
      expect(otherN.confirmTopic, isNot(base.confirmTopic));
      expect(otherN.aeadKey, isNot(base.aeadKey));
      expect(otherKe.payloadTopic, isNot(base.payloadTopic));
      expect(otherKe.aeadKey, isNot(base.aeadKey));
    });

    test('is deterministic', () {
      expect(InternetCodeKeys.derive(ke, n).payloadTopic,
          InternetCodeKeys.derive(ke, n).payloadTopic);
    });
  });

  group('the seal', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final n = Uint8List.fromList(List.generate(16, (i) => 100 + i));
    final clear = utf8.encode('{"k":"offer","qs":"QS1abc"}');

    Future<Uint8List> sealed({
      SealRole role = SealRole.payload,
      Uint8List? useKey,
      Uint8List? useN,
    }) =>
        InternetCodeSeal.seal(
            key: useKey ?? key,
            role: role,
            n: useN ?? n,
            plaintext: clear);

    test('opens under the same key, role and nonce', () async {
      final envelope = await sealed();
      expect(
          await InternetCodeSeal.open(
              key: key, role: SealRole.payload, n: n, envelope: envelope),
          clear);
    });

    test('does not show its contents', () async {
      final envelope = await sealed();
      expect(utf8.decode(envelope, allowMalformed: true), isNot(contains('QS1')));
    });

    test('refuses a flipped byte anywhere, and a truncation', () async {
      final envelope = await sealed();
      for (final i in [0, 5, 12, envelope.length - 17, envelope.length - 1]) {
        final bad = Uint8List.fromList(envelope)..[i] ^= 0x01;
        expect(
            await InternetCodeSeal.open(
                key: key, role: SealRole.payload, n: n, envelope: bad),
            isNull,
            reason: 'byte $i');
      }
      expect(
          await InternetCodeSeal.open(
              key: key,
              role: SealRole.payload,
              n: n,
              envelope: envelope.sublist(0, envelope.length - 1)),
          isNull);
      expect(
          await InternetCodeSeal.open(
              key: key, role: SealRole.payload, n: n, envelope: Uint8List(0)),
          isNull);
      expect(
          await InternetCodeSeal.open(
              key: key,
              role: SealRole.payload,
              n: n,
              envelope: Uint8List(20)),
          isNull);
    });

    test('refuses another key, another run and the other message', () async {
      final envelope = await sealed();
      expect(
          await InternetCodeSeal.open(
              key: Uint8List(32), role: SealRole.payload, n: n, envelope: envelope),
          isNull);
      expect(
          await InternetCodeSeal.open(
              key: key,
              role: SealRole.payload,
              n: Uint8List(16),
              envelope: envelope),
          isNull,
          reason: 'a message from one run cannot be replayed into another');
      expect(
          await InternetCodeSeal.open(
              key: key, role: SealRole.confirm, n: n, envelope: envelope),
          isNull,
          reason: 'the confirmation cannot be replayed as the offer');
    });

    test('uses a fresh nonce each time', () async {
      final a = await sealed();
      final b = await sealed();
      expect(a, isNot(b));
    });
  });

  group('the proof of the code', () {
    const pake = InternetCodePake(inline: true);
    final n = InternetCode.randomBytes(InternetCode.nonceLength);

    test('agrees when both ends hold the code', () async {
      const code = SessionCode('1234567890');
      final a = await pake.begin(code);
      final b = await pake.respond(code, n: n, receiverShare: a.share);
      final keys = await pake.complete(a, n: n, senderShare: b.share);

      expect(keys.verifies(Spake2Role.b, b.keys.confirmationB), isTrue);
      expect(b.keys.verifies(Spake2Role.a, keys.confirmationA), isTrue);
      expect(keys.ke, b.keys.ke);
    });

    test('does not agree on a different code', () async {
      final a = await pake.begin(const SessionCode('1234567890'));
      final b = await pake.respond(const SessionCode('1234567891'),
          n: n, receiverShare: a.share);
      final keys = await pake.complete(a, n: n, senderShare: b.share);

      expect(keys.verifies(Spake2Role.b, b.keys.confirmationB), isFalse);
      expect(keys.ke, isNot(b.keys.ke));
    });

    test('does not agree when the two ends have different nonces', () async {
      const code = SessionCode('1234567890');
      final a = await pake.begin(code);
      final b = await pake.respond(code, n: n, receiverShare: a.share);
      final keys = await pake.complete(a,
          n: InternetCode.randomBytes(InternetCode.nonceLength),
          senderShare: b.share);

      expect(keys.verifies(Spake2Role.b, b.keys.confirmationB), isFalse,
          reason: 'a run is bound to its nonce');
    });

    test('is not the proof the local network runs for the same code', () async {
      const code = SessionCode('1234567890');
      final a = await pake.begin(code);
      final b = await pake.respond(code, n: n, receiverShare: a.share);
      final lanA = await CodePake.begin(code);
      final lanB = await CodePake.respond(code,
          receiverShare: lanA.share, certFingerprint: 'AA:BB');
      expect(b.keys.confirmationB, isNot(lanB.keys.confirmationB));
      expect(b.keys.ke, isNot(lanB.keys.ke));
    });

    test('refuses a share that is not a point of the curve', () async {
      const code = SessionCode('1234567890');
      final offCurve = Uint8List.fromList([4, ...List.filled(64, 1)]);
      await expectLater(
          pake.respond(code, n: n, receiverShare: offCurve),
          throwsA(isA<Spake2Exception>()));

      final a = await pake.begin(code);
      await expectLater(pake.complete(a, n: n, senderShare: offCurve),
          throwsA(isA<Spake2Exception>()));
      await expectLater(
          pake.respond(code,
              n: n, receiverShare: Uint8List.fromList([0, ...List.filled(64, 0)])),
          throwsA(isA<Spake2Exception>()),
          reason: 'not the uncompressed encoding');
      await expectLater(
          pake.respond(code, n: n, receiverShare: Uint8List(10)),
          throwsA(isA<Spake2Exception>()));
    });

    test('runs on an isolate by default and agrees with the inline run',
        () async {
      const code = SessionCode('0000000001');
      const isolated = InternetCodePake();
      final a = await isolated.begin(code);
      final b = await isolated.respond(code, n: n, receiverShare: a.share);
      final keys = await isolated.complete(a, n: n, senderShare: b.share);
      expect(keys.verifies(Spake2Role.b, b.keys.confirmationB), isTrue);
    });
  });
}

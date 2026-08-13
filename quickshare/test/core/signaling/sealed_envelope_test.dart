import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';

void main() {
  final seed = Uint8List.fromList(List.generate(16, (i) => i * 7 % 256));
  final offerFp = Uint8List.fromList(List.generate(32, (i) => 255 - i));
  final payload = Uint8List.fromList(utf8.encode('compact-answer-payload'));

  group('SealedEnvelope', () {
    test('seals and opens with the same seed and offer', () async {
      final sealed = await SealedEnvelope.seal(
          plaintext: payload, seed: seed, offerFingerprint: offerFp);
      final opened = await SealedEnvelope.open(
          envelope: sealed, seed: seed, offerFingerprint: offerFp);

      expect(opened, payload);
    });

    test('ciphertext leaks neither the payload nor a stable shape', () async {
      final first = await SealedEnvelope.seal(
          plaintext: payload, seed: seed, offerFingerprint: offerFp);
      final second = await SealedEnvelope.seal(
          plaintext: payload, seed: seed, offerFingerprint: offerFp);

      expect(String.fromCharCodes(first), isNot(contains('compact-answer')));
      // A fresh nonce each time: identical plaintext must not produce
      // identical bytes, or the broker can correlate repeated sessions.
      expect(first, isNot(second));
      expect(first.sublist(0, 12), isNot(second.sublist(0, 12)));
    });

    test('a wrong seed cannot open it', () async {
      final sealed = await SealedEnvelope.seal(
          plaintext: payload, seed: seed, offerFingerprint: offerFp);
      final wrong = Uint8List.fromList(List.generate(16, (i) => i));

      expect(
        () => SealedEnvelope.open(
            envelope: sealed, seed: wrong, offerFingerprint: offerFp),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('an answer captured from one offer will not replay into another',
        () async {
      final sealed = await SealedEnvelope.seal(
          plaintext: payload, seed: seed, offerFingerprint: offerFp);
      final otherOffer = Uint8List.fromList(List.generate(32, (i) => i));

      expect(
        () => SealedEnvelope.open(
            envelope: sealed, seed: seed, offerFingerprint: otherOffer),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('tampering with a single byte is caught', () async {
      final sealed = await SealedEnvelope.seal(
          plaintext: payload, seed: seed, offerFingerprint: offerFp);
      sealed[20] ^= 0x01;

      expect(
        () => SealedEnvelope.open(
            envelope: sealed, seed: seed, offerFingerprint: offerFp),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('a truncated envelope is rejected before decryption', () async {
      expect(
        () => SealedEnvelope.open(
            envelope: Uint8List(10), seed: seed, offerFingerprint: offerFp),
        throwsA(isA<FormatException>()),
      );
    });

    test('topic is deterministic, and unrelated to the key', () async {
      final a = await SealedEnvelope.deriveTopic(seed);
      final b = await SealedEnvelope.deriveTopic(seed);
      final other = await SealedEnvelope.deriveTopic(
          Uint8List.fromList(List.generate(16, (i) => i + 1)));

      expect(a, b);
      expect(a, isNot(other));
      expect(a.length, greaterThanOrEqualTo(16));
      expect(a, isNot(contains('=')));
    });

    test('seeds are random and full length', () {
      final seeds = List.generate(32, (_) => SealedEnvelope.newSeed());

      expect(seeds.every((s) => s.length == SealedEnvelope.seedLengthBytes),
          isTrue);
      expect(seeds.map((s) => base64Url.encode(s)).toSet().length, 32);
    });

    test('a sealed compact answer still fits a single small datagram',
        () async {
      const answerSdp = '''v=0
o=- 0 0 IN IP4 0.0.0.0
s=-
t=0 0
a=group:BUNDLE 0
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=ice-ufrag:9Kd2
a=ice-pwd:LmQ2p8xVnT4bYcRe7wZaXs
a=fingerprint:sha-256 A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90:A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90
a=setup:active
a=mid:0
a=sctp-port:5000
a=candidate:1 1 udp 1686052607 100.71.14.9 41002 typ srflx generation 0
a=candidate:2 1 udp 41885439 172.253.62.127 30001 typ relay generation 0''';

      final compact = CompactSdp.fromSdp(answerSdp).toBytes();
      final sealed = await SealedEnvelope.seal(
          plaintext: compact, seed: seed, offerFingerprint: offerFp);

      expect(sealed.length, lessThan(300),
          reason: 'sealed answer is ${sealed.length} bytes');
      final opened = await SealedEnvelope.open(
          envelope: sealed, seed: seed, offerFingerprint: offerFp);
      expect(CompactSdp.fromBytes(opened).iceUfrag, '9Kd2');
    });
  });
}

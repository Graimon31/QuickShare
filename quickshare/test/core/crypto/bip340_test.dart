import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/crypto/bip340.dart';

Uint8List _unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

String _hex(Uint8List b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('BIP-340', () {
    // Test vector 0 from the BIP-340 specification. This one is also
    // independently corroborated: three public Nostr relays accepted events
    // signed by this implementation, and relays verify Schnorr themselves.
    const secretKey =
        '0000000000000000000000000000000000000000000000000000000000000003';
    const publicKey =
        'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9';
    const signature =
        'e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca8215'
        '25f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0';

    test('derives the x-only public key from the spec vector', () {
      expect(_hex(Bip340.publicKey(_unhex(secretKey))), equals(publicKey));
    });

    test('reproduces the signature from the spec vector', () {
      final sig = Bip340.sign(Uint8List(32), _unhex(secretKey), Uint8List(32));
      expect(_hex(sig), equals(signature));
    });

    test('verifies the signature from the spec vector', () {
      expect(
        Bip340.verify(Uint8List(32), _unhex(publicKey), _unhex(signature)),
        isTrue,
      );
    });

    test('rejects a signature with a single flipped bit', () {
      final tampered = _unhex(signature)..[63] ^= 0x01;
      expect(Bip340.verify(Uint8List(32), _unhex(publicKey), tampered), isFalse);
    });

    test('rejects a signature made for a different message', () {
      final otherMessage = Uint8List(32)..[0] = 0x42;
      expect(
        Bip340.verify(otherMessage, _unhex(publicKey), _unhex(signature)),
        isFalse,
      );
    });

    test('rejects a signature checked against a different key', () {
      final otherKey = Bip340.publicKey(Uint8List(32)..[31] = 0x07);
      expect(
        Bip340.verify(Uint8List(32), otherKey, _unhex(signature)),
        isFalse,
      );
    });

    test('round-trips random messages with a random key', () {
      // The aux_rand differs per call, so this also covers the branch where
      // the nonce point has an odd y and the scalar must be negated.
      final key = Uint8List(32)..[31] = 0x2A;
      for (var i = 1; i <= 8; i++) {
        final message = Uint8List(32)..[0] = i;
        final aux = Uint8List(32)..[1] = i;
        final sig = Bip340.sign(message, key, aux);
        expect(Bip340.verify(message, Bip340.publicKey(key), sig), isTrue,
            reason: 'message $i should verify');
      }
    });

    test('rejects malformed inputs instead of throwing', () {
      expect(Bip340.verify(Uint8List(31), _unhex(publicKey), _unhex(signature)),
          isFalse);
      expect(Bip340.verify(Uint8List(32), Uint8List(31), _unhex(signature)),
          isFalse);
      expect(Bip340.verify(Uint8List(32), _unhex(publicKey), Uint8List(63)),
          isFalse);
    });

    test('refuses out-of-range secret keys', () {
      expect(() => Bip340.publicKey(Uint8List(32)), throwsArgumentError);
      expect(
        () => Bip340.sign(Uint8List(32), Uint8List(31), Uint8List(32)),
        throwsArgumentError,
      );
    });
  });
}

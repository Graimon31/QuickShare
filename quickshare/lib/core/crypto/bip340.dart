import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// BIP-340 Schnorr signatures over secp256k1.
///
/// Written out rather than pulled from a package: the only consumer is the
/// Nostr rendezvous channel, which needs exactly two operations, and a
/// hand-rolled 150 lines on BigInt is easier to audit than a transitive
/// dependency tree carrying a full Bitcoin stack onto five platforms.
///
/// Correctness is pinned by the BIP-340 test vectors in
/// `test/core/crypto/bip340_test.dart`. Note that nothing in DirectDrop's
/// security rests on these signatures: they exist because Nostr relays refuse
/// unsigned events. Authenticity of an answer comes from
/// [SealedEnvelope.open], which fails on any payload not sealed under the
/// seed shown in the QR code.
class Bip340 {
  const Bip340._();

  static final BigInt _p = BigInt.parse(
      'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
      radix: 16);
  static final BigInt _n = BigInt.parse(
      'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
      radix: 16);
  static final _g = _Point(
    BigInt.parse(
        '79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798',
        radix: 16),
    BigInt.parse(
        '483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8',
        radix: 16),
  );

  /// x-only public key (32 bytes) for [secretKey].
  static Uint8List publicKey(Uint8List secretKey) {
    final d = _scalar(secretKey);
    return _bytes32(_mul(_g, d)!.x);
  }

  /// Signs a 32-byte [message] digest. [auxRand] must be 32 fresh random
  /// bytes; it only masks the nonce and never has to be reproduced.
  static Uint8List sign(
      Uint8List message, Uint8List secretKey, Uint8List auxRand) {
    if (message.length != 32) {
      throw ArgumentError('message must be a 32-byte digest');
    }
    if (auxRand.length != 32) {
      throw ArgumentError('auxRand must be 32 bytes');
    }

    final d0 = _scalar(secretKey);
    final point = _mul(_g, d0)!;
    final d = point.y.isEven ? d0 : _n - d0;

    final masked = _taggedHash('BIP0340/aux', auxRand);
    final dBytes = _bytes32(d);
    final t = Uint8List.fromList(
        List<int>.generate(32, (i) => dBytes[i] ^ masked[i]));

    final rand =
        _taggedHash('BIP0340/nonce', [...t, ..._bytes32(point.x), ...message]);
    final k0 = _int(rand) % _n;
    if (k0 == BigInt.zero) {
      throw StateError('derived nonce is zero, which BIP-340 forbids');
    }
    final r = _mul(_g, k0)!;
    final k = r.y.isEven ? k0 : _n - k0;

    final e = _challenge(_bytes32(r.x), _bytes32(point.x), message);
    return Uint8List.fromList([..._bytes32(r.x), ..._bytes32((k + e * d) % _n)]);
  }

  /// Verifies a 64-byte [signature]. Used by the unit tests and available to
  /// callers that want to reject malformed relay traffic early.
  static bool verify(
      Uint8List message, Uint8List publicKey, Uint8List signature) {
    if (message.length != 32 ||
        publicKey.length != 32 ||
        signature.length != 64) {
      return false;
    }
    final point = _liftX(_int(publicKey));
    if (point == null) return false;

    final r = _int(Uint8List.sublistView(signature, 0, 32));
    final s = _int(Uint8List.sublistView(signature, 32, 64));
    if (r >= _p || s >= _n) return false;

    final e = _challenge(
        Uint8List.sublistView(signature, 0, 32), publicKey, message);
    final negated = _mul(point, e);
    final result = _add(
      _mul(_g, s),
      negated == null ? null : _Point(negated.x, _mod(-negated.y, _p)),
    );
    return result != null && result.y.isEven && result.x == r;
  }

  static BigInt _scalar(Uint8List secretKey) {
    if (secretKey.length != 32) {
      throw ArgumentError('secret key must be 32 bytes');
    }
    final d = _int(secretKey);
    if (d <= BigInt.zero || d >= _n) {
      throw ArgumentError('secret key is out of range');
    }
    return d;
  }

  static BigInt _challenge(Uint8List rx, Uint8List px, Uint8List message) =>
      _int(_taggedHash('BIP0340/challenge', [...rx, ...px, ...message])) % _n;

  static Uint8List _taggedHash(String tag, List<int> message) {
    final tagHash = sha256.convert(utf8.encode(tag)).bytes;
    return Uint8List.fromList(
        sha256.convert([...tagHash, ...tagHash, ...message]).bytes);
  }

  static _Point? _liftX(BigInt x) {
    if (x >= _p) return null;
    final c = _mod(x * x % _p * x + BigInt.from(7), _p);
    final y = c.modPow((_p + BigInt.one) ~/ BigInt.from(4), _p);
    if (y * y % _p != c) return null;
    return _Point(x, y.isEven ? y : _p - y);
  }

  static _Point? _add(_Point? a, _Point? b) {
    if (a == null) return b;
    if (b == null) return a;
    if (a.x == b.x && a.y != b.y) return null;
    final BigInt lambda;
    if (a.x == b.x) {
      lambda = _mod(
          BigInt.from(3) * a.x * a.x * _inv(BigInt.two * a.y), _p);
    } else {
      lambda = _mod((b.y - a.y) * _inv(b.x - a.x), _p);
    }
    final x = _mod(lambda * lambda - a.x - b.x, _p);
    return _Point(x, _mod(lambda * (a.x - x) - a.y, _p));
  }

  static _Point? _mul(_Point? point, BigInt scalar) {
    _Point? result;
    var addend = point;
    var k = scalar;
    while (k > BigInt.zero) {
      if (k.isOdd) result = _add(result, addend);
      addend = _add(addend, addend);
      k >>= 1;
    }
    return result;
  }

  static BigInt _mod(BigInt a, BigInt m) => (a % m + m) % m;
  static BigInt _inv(BigInt a) => _mod(a, _p).modInverse(_p);

  static Uint8List _bytes32(BigInt value) {
    final out = Uint8List(32);
    var v = value;
    for (var i = 31; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xFF)).toInt();
      v >>= 8;
    }
    return out;
  }

  static BigInt _int(Uint8List bytes) =>
      bytes.fold(BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));
}

class _Point {
  final BigInt x;
  final BigInt y;
  const _Point(this.x, this.y);
}

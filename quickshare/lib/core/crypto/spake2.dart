import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/export.dart'
    show ECCurve_secp256r1, ECDomainParameters, ECPoint;

import 'package:quickshare/core/crypto/hkdf.dart';

/// A share or a key schedule that must not be used.
///
/// Always the same silent outcome for the caller: the peer is not who it
/// claims, or is not speaking this protocol. There is nothing to tell it.
class Spake2Exception implements Exception {
  final String message;
  const Spake2Exception(this.message);

  @override
  String toString() => 'Spake2Exception: $message';
}

/// Which end of the exchange this is. A speaks first and masks with M; B
/// answers and masks with N.
enum Spake2Role { a, b }

/// What both ends hold once they have exchanged shares.
class Spake2Keys {
  /// The shared secret (RFC 9382 `Ke`). Nothing here uses it yet; the
  /// exchange is run to prove the code, not to key a channel.
  final Uint8List ke;

  /// `cA`, the confirmation A sends B.
  final Uint8List confirmationA;

  /// `cB`, the confirmation B sends A.
  final Uint8List confirmationB;

  /// The transcript `TT`, for known-answer tests.
  @visibleForTesting
  final Uint8List transcript;

  Spake2Keys._(this.ke, this.confirmationA, this.confirmationB, this.transcript);

  /// Whether [tag] is the confirmation [from] would have computed.
  ///
  /// Constant-time in the contents of [tag]: it is compared to a secret.
  bool verifies(Spake2Role from, List<int> tag) => Spake2._constantTimeEquals(
      tag, from == Spake2Role.a ? confirmationA : confirmationB);
}

/// SPAKE2 over P-256 with SHA-256, HKDF and HMAC — RFC 9382's
/// SPAKE2-P256-SHA256-HKDF-HMAC, written out on `pointycastle`'s curve
/// arithmetic.
///
/// ## Why this and not a hash of the code
///
/// The code is ten digits, a little over 33 bits, and it is the only secret
/// the two devices share. Anything an eavesdropper or an impostor can see that
/// depends on it — a hash, a MAC, an encryption of something known — can be
/// tried against all ten billion codes at home. SPAKE2 is built so that what
/// crosses the wire depends on the code only in a way that cannot be tested
/// without the other end's private scalar: one online run gives an attacker
/// one guess, and a guess costs a run the other side can count and refuse.
///
/// ## What it does not do
///
/// It does not make a short code strong, only online-only. An attacker who is
/// allowed enough runs still wins; the sender's limiters are what keep that
/// number small. And Dart's `BigInt` arithmetic is not constant-time, which is
/// acceptable against a peer that can measure only whole network round trips
/// and not against one with a local timer on this CPU.
///
/// ## Correctness
///
/// Pinned by all four vectors of RFC 9382 Appendix B in
/// `test/core/crypto/spake2_test.dart`, which also regenerates M and N from
/// the RFC's own seed so the constants are shown not chosen.
///
/// Pure, synchronous and made of sendable parts — `BigInt`, bytes and an
/// enum — so a caller can run any step on another isolate. A scalar
/// multiplication is about five milliseconds here and a run does four per
/// side, which is more than a frame on the UI isolate.
class Spake2 {
  /// Uncompressed SEC1: `04 || X || Y`, the RFC's encoding for P-256.
  static const int shareLength = 65;

  /// M and N from RFC 9382 section 6, compressed.
  @visibleForTesting
  static const String mCompressedHex =
      '02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f';
  @visibleForTesting
  static const String nCompressedHex =
      '03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49';

  static final ECDomainParameters _params = ECCurve_secp256r1();
  static final ECPoint _m = _params.curve.decodePoint(_hex(mCompressedHex))!;
  static final ECPoint _n = _params.curve.decodePoint(_hex(nCompressedHex))!;

  // The field and the curve equation, restated here rather than read back out
  // of the library: the check that a received share is a point is the one the
  // protocol's security rests on, and it should not depend on a decoder that
  // accepts what it is handed.
  static final BigInt _p = BigInt.parse(
      'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
      radix: 16);
  static final BigInt _b = BigInt.parse(
      '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
      radix: 16);

  /// The order of the group. A password scalar lives in `[1, order)`.
  static BigInt get order => _params.n;

  final Spake2Role role;

  /// Our public value: `pA = w*M + x*P` or `pB = w*N + y*P`.
  final Uint8List share;

  final BigInt _w;
  final BigInt _secret;

  Spake2._(this.role, this._w, this._secret, this.share);

  /// Picks this end's secret scalar and computes its share.
  ///
  /// [w] is the password as a scalar — the caller's business how it is
  /// derived, and where the work factor goes. [secret] exists so the RFC's
  /// vectors can be reproduced; nothing else may pass it, because a repeated
  /// scalar breaks the protocol.
  factory Spake2.start({
    required Spake2Role role,
    required BigInt w,
    Random? random,
    BigInt? secret,
  }) {
    _checkScalar(w, 'w');
    final scalar = secret ?? _randomScalar(random ?? Random.secure());
    _checkScalar(scalar, 'secret');

    final mask = role == Spake2Role.a ? _m : _n;
    final point = (_params.G * scalar)! + (mask * w)!;
    if (point == null || point.isInfinity) {
      throw StateError('SPAKE2 produced the identity as a share');
    }
    return Spake2._(role, w, scalar, point.getEncoded(false));
  }

  /// Combines the peer's share with ours and derives the keys.
  ///
  /// Throws [Spake2Exception] for a peer share that is not a point of the
  /// group, in any encoding but the one the RFC fixes, or that cancels to the
  /// identity. [identityA] and [identityB] are bound into the transcript: two
  /// ends that disagree about either derive unrelated keys. [aad] goes into
  /// the confirmation-key derivation, so a version label there stops a run of
  /// one protocol being replayed into another.
  Spake2Keys finish(
    List<int> peerShare, {
    required List<int> identityA,
    required List<int> identityB,
    List<int> aad = const [],
  }) {
    final peer = _decode(peerShare);

    // A's share is masked with M, so A removes N's mask from B's, and the
    // reverse. The cofactor is 1, so the RFC's multiplication by h is a no-op.
    final peerMask = role == Spake2Role.a ? _n : _m;
    final unmasked = peer - (peerMask * _w)!;
    if (unmasked == null || unmasked.isInfinity) {
      throw const Spake2Exception('degenerate share');
    }
    final k = unmasked * _secret;
    if (k == null || k.isInfinity) {
      throw const Spake2Exception('degenerate key');
    }

    final peerBytes = peer.getEncoded(false);
    final pA = role == Spake2Role.a ? share : peerBytes;
    final pB = role == Spake2Role.a ? peerBytes : share;

    // TT = len(A)||A || len(B)||B || len(pA)||pA || len(pB)||pB || len(K)||K
    //      || len(w)||w, lengths as eight bytes little-endian, w as a
    //      big-endian number the width of the group order.
    final transcript = BytesBuilder(copy: false);
    void put(List<int> value) {
      transcript.add(_le64(value.length));
      transcript.add(value);
    }

    put(identityA);
    put(identityB);
    put(pA);
    put(pB);
    put(k.getEncoded(false));
    put(_scalarBytes(_w));
    final tt = transcript.takeBytes();

    // Ke || Ka = Hash(TT); KcA || KcB = HKDF(Ka, nil, "ConfirmationKeys" ||
    // AAD, 32); each side's confirmation is HMAC(Kc, TT).
    final digest = sha256.convert(tt).bytes;
    final ke = Uint8List.fromList(digest.sublist(0, 16));
    final ka = digest.sublist(16);
    final kc = hkdfSha256(
      ka,
      info: [...'ConfirmationKeys'.codeUnits, ...aad],
      length: 32,
    );
    List<int> mac(List<int> key) => Hmac(sha256, key).convert(tt).bytes;

    return Spake2Keys._(
      ke,
      Uint8List.fromList(mac(kc.sublist(0, 16))),
      Uint8List.fromList(mac(kc.sublist(16))),
      tt,
    );
  }

  /// Reads a peer's share, strictly: 65 bytes, the uncompressed prefix, both
  /// coordinates below the field prime, and on the curve. With a cofactor of
  /// one that is the whole group-membership test the RFC requires, and the
  /// prefix rules out the point at infinity.
  static ECPoint _decode(List<int> bytes) {
    if (bytes.length != shareLength || bytes[0] != 0x04) {
      throw const Spake2Exception('malformed share');
    }
    final x = _bigEndian(bytes, 1, 33);
    final y = _bigEndian(bytes, 33, 65);
    if (x >= _p || y >= _p) {
      throw const Spake2Exception('coordinate out of range');
    }
    // y^2 = x^3 - 3x + b (mod p). Dart's % is never negative for a positive
    // modulus.
    final onCurve =
        (y * y - (x * x * x - BigInt.from(3) * x + _b)) % _p == BigInt.zero;
    if (!onCurve) throw const Spake2Exception('not a point of the group');
    return _params.curve.createPoint(x, y);
  }

  static void _checkScalar(BigInt value, String name) {
    if (value <= BigInt.zero || value >= _params.n) {
      throw ArgumentError.value(value, name, 'must be in [1, order)');
    }
  }

  /// Uniform in `[1, order)`: 64 bits more than the order, so reducing it
  /// leaves no bias worth measuring.
  static BigInt _randomScalar(Random random) {
    var v = BigInt.zero;
    for (var i = 0; i < 40; i++) {
      v = (v << 8) | BigInt.from(random.nextInt(256));
    }
    return v % (_params.n - BigInt.one) + BigInt.one;
  }

  static BigInt _bigEndian(List<int> bytes, int start, int end) {
    var v = BigInt.zero;
    for (var i = start; i < end; i++) {
      v = (v << 8) | BigInt.from(bytes[i]);
    }
    return v;
  }

  static Uint8List _scalarBytes(BigInt value) {
    final out = Uint8List(32);
    var v = value;
    for (var i = 31; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }

  static Uint8List _le64(int value) {
    final out = Uint8List(8);
    ByteData.view(out.buffer).setUint64(0, value, Endian.little);
    return out;
  }

  static Uint8List _hex(String value) => Uint8List.fromList([
        for (var i = 0; i < value.length; i += 2)
          int.parse(value.substring(i, i + 2), radix: 16),
      ]);

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    // The length of a tag is not a secret; its contents are.
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}

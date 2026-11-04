import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'package:quickshare/core/crypto/spake2.dart';

Uint8List hex(String value) {
  final clean = value.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

BigInt big(String value) => BigInt.parse(value, radix: 16);

/// One of the vectors in RFC 9382 Appendix B (SPAKE2-P256-SHA256-HKDF-HMAC).
/// A and B are given as text; empty means the identity is absent.
class _Vector {
  final String a, b;
  final String w, x, pA, y, pB, tt, ke, confA, confB;
  const _Vector({
    required this.a,
    required this.b,
    required this.w,
    required this.x,
    required this.pA,
    required this.y,
    required this.pB,
    required this.tt,
    required this.ke,
    required this.confA,
    required this.confB,
  });
}

const _vectors = <_Vector>[
  _Vector(
    a: 'server',
    b: 'client',
    w: '2ee57912099d31560b3a44b1184b9b4866e904c49d12ac5042c97dca461b1a5f',
    x: '43dd0fd7215bdcb482879fca3220c6a968e66d70b1356cac18bb26c84a78d729',
    pA: '04a56fa807caaa53a4d28dbb9853b9815c61a411118a6fe516a8798434751470'
        'f9010153ac33d0d5f2047ffdb1a3e42c9b4e6be662766e1eeb4116988ede5f912c',
    y: 'dcb60106f276b02606d8ef0a328c02e4b629f84f89786af5befb0bc75b6e66be',
    pB: '0406557e482bd03097ad0cbaa5df82115460d951e3451962f1eaf4367a420676'
        'd09857ccbc522686c83d1852abfa8ed6e4a1155cf8f1543ceca528afb591a1e0b7',
    tt: '06000000000000007365727665720600000000000000636c69656e744100000'
        '00000000004a56fa807caaa53a4d28dbb9853b9815c61a411118a6fe516a8798434751'
        '470f9010153ac33d0d5f2047ffdb1a3e42c9b4e6be662766e1eeb4116988ede5f912c4'
        '1000000000000000406557e482bd03097ad0cbaa5df82115460d951e3451962f1eaf43'
        '67a420676d09857ccbc522686c83d1852abfa8ed6e4a1155cf8f1543ceca528afb591a'
        '1e0b741000000000000000412af7e89717850671913e6b469ace67bd90a4df8ce45c2a'
        'f19010175e37eed69f75897996d539356e2fa6a406d528501f907e04d97515fbe83db2'
        '77b715d332520000000000000002ee57912099d31560b3a44b1184b9b4866e904c49d1'
        '2ac5042c97dca461b1a5f',
    ke: '0e0672dc86f8e45565d338b0540abe69',
    confA: '58ad4aa88e0b60d5061eb6b5dd93e80d9c4f00d127c65b3b35b1b5281fee38f0',
    confB: 'd3e2e547f1ae04f2dbdbf0fc4b79f8ecff2dff314b5d32fe9fcef2fb26dc459b',
  ),
  _Vector(
    a: '',
    b: 'client',
    w: '0548d8729f730589e579b0475a582c1608138ddf7054b73b5381c7e883e2efae',
    x: '403abbe3b1b4b9ba17e3032849759d723939a27a27b9d921c500edde18ed654b',
    pA: '04a897b769e681c62ac1c2357319a3d363f610839c4477720d24cbe32f5fd8'
        '5f44fb92ba966578c1b712be6962498834078262caa5b441ecfa9d4a9485720e918a',
    y: '903023b6598908936ea7c929bd761af6039577a9c3f9581064187c3049d87065',
    pB: '04e0f816fd1c35e22065d5556215c097e799390d16661c386e0ecc84593974'
        'a61b881a8c82327687d0501862970c64565560cb5671f696048050ca66ca5f8cc7fc',
    tt: '00000000000000000600000000000000636c69656e74410000000000000004a'
        '897b769e681c62ac1c2357319a3d363f610839c4477720d24cbe32f5fd85f44fb92ba9'
        '66578c1b712be6962498834078262caa5b441ecfa9d4a9485720e918a4100000000000'
        '00004e0f816fd1c35e22065d5556215c097e799390d16661c386e0ecc84593974a61b8'
        '81a8c82327687d0501862970c64565560cb5671f696048050ca66ca5f8cc7fc4100000'
        '000000000048f83ec9f6e4f87cc6f9dc740bdc2769725f923364f01c84148c049a39a7'
        '35ebda82eac03e00112fd6a5710682767cff5361f7e819e53d8d3c3a2922e0d837aa62'
        '0000000000000000548d8729f730589e579b0475a582c1608138ddf7054b73b5381c7e'
        '883e2efae',
    ke: '642f05c473c2cd79909f9a841e2f30a7',
    confA: '47d29e6666af1b7dd450d571233085d7a9866e4d49d2645e2df975489521232b',
    confB: '3313c5cefc361d27fb16847a91c2a73b766ffa90a4839122a9b70a2f6bd1d6df',
  ),
  _Vector(
    a: 'server',
    b: '',
    w: '626e0cdc7b14c9db3e52a0b1b3a768c98e37852d5db30febe0497b14eae8c254',
    x: '07adb3db6bc623d3399726bfdbfd3d15a58ea776ab8a308b00392621291f9633',
    pA: '04f88fb71c99bfffaea370966b7eb99cd4be0ff1a7d335caac4211c4afd855e2'
        'e15a873b298503ad8ba1d9cbb9a392d2ba309b48bfd7879aefd0f2cea6009763b0',
    y: 'b6a4fc8dbb629d4ba51d6f91ed1532cf87adec98f25dd153a75accafafedec16',
    pB: '040c269d6be017dccb15182ac6bfcd9e2a14de019dd587eaf4bdfd353f031101'
        'e7cca177f8eb362a6e83e7d5e729c0732e1b528879c086f39ba0f31a9661bd34db',
    tt: '06000000000000007365727665720000000000000000410000000000000004f'
        '88fb71c99bfffaea370966b7eb99cd4be0ff1a7d335caac4211c4afd855e2e15a873b2'
        '98503ad8ba1d9cbb9a392d2ba309b48bfd7879aefd0f2cea6009763b04100000000000'
        '000040c269d6be017dccb15182ac6bfcd9e2a14de019dd587eaf4bdfd353f031101e7c'
        'ca177f8eb362a6e83e7d5e729c0732e1b528879c086f39ba0f31a9661bd34db4100000'
        '0000000000445ee233b8ecb51ebd6e7da3f307e88a1616bae2166121221fdc0dadb986'
        'afaf3ec8a988dc9c626fa3b99f58a7ca7c9b844bb3e8dd9554aafc5b53813504c1cbe2'
        '000000000000000626e0cdc7b14c9db3e52a0b1b3a768c98e37852d5db30febe0497b1'
        '4eae8c254',
    ke: '005184ff460da2ce59062c87733c299c',
    confA: 'bc9f9bbe99f26d0b2260e6456e05a86196a3307ec6663a18bf6ac825736533b2',
    confB: 'c2370e1bf813b086dff0d834e74425a06e6390f48f5411900276dcccc5a297ec',
  ),
  _Vector(
    a: '',
    b: '',
    w: '7bf46c454b4c1b25799527d896508afd5fc62ef4ec59db1efb49113063d70cca',
    x: '8cef65df64bb2d0f83540c53632de911b5b24b3eab6cc74a97609fd659e95473',
    pA: '04a65b367a3f613cf9f0654b1b28a1e3a8a40387956c8ba6063e8658563890f4'
        '6ca1ef6a676598889fc28de2950ab8120b79a5ef1ea4c9f44bc98f585634b46d66',
    y: 'd7a66f64074a84652d8d623a92e20c9675c61cb5b4f6a0063e4648a2fdc02d53',
    pB: '04589f13218822710d98d8b2123a079041052d9941b9cf88c6617ddb2fcc0494'
        '662eea8ba6b64692dc318250030c6af045cb738bc81ba35b043c3dcb46adf6f58d',
    tt: '00000000000000000000000000000000410000000000000004a65b367a3f613'
        'cf9f0654b1b28a1e3a8a40387956c8ba6063e8658563890f46ca1ef6a676598889fc28'
        'de2950ab8120b79a5ef1ea4c9f44bc98f585634b46d66410000000000000004589f132'
        '18822710d98d8b2123a079041052d9941b9cf88c6617ddb2fcc0494662eea8ba6b6469'
        '2dc318250030c6af045cb738bc81ba35b043c3dcb46adf6f58d4100000000000000041'
        'a3c03d51b452537ca2a1fea6110353c6d5ed483c4f0f86f4492ca3f378d40a994b4477'
        'f93c64d928edbbcd3e85a7c709b7ea73ee97986ce3d1438e1355437722000000000000'
        '0007bf46c454b4c1b25799527d896508afd5fc62ef4ec59db1efb49113063d70cca',
    ke: 'fc6374762ba5cf11f4b2caa08b2cd1b9',
    confA: 'dfb4db8d48ae5a675963ea5e6c19d98d4ea028d8e898dad96ea19a80ade95dca',
    confB: 'd0f0609d1613138d354f7e95f19fb556bf52d751947241e8c7118df5ef0ae175',
  ),
];

/// Appendix A of the RFC, as written there: how M and N were found. Running
/// it here is what shows the constants are nobody's chosen points, rather
/// than this file agreeing with itself.
Uint8List _generatePoint(String seed) {
  final params = ECCurve_secp256r1();
  Uint8List iteratedHash(List<int> start, int rounds) {
    var h = Uint8List.fromList(start);
    for (var i = 0; i < rounds; i++) {
      h = Uint8List.fromList(sha256.convert(h).bytes);
    }
    return h;
  }

  for (var i = 1; i < 1000; i++) {
    const size = 33;
    const blocks = 2; // ceil(33 / 32)
    final joined = <int>[
      for (var k = i; k < i + blocks; k++)
        ...iteratedHash(utf8.encode(seed), k),
    ].sublist(0, size);
    joined[0] = (joined[0] & 1) | 2;
    try {
      final point = params.curve.decodePoint(joined);
      if (point != null && !point.isInfinity) {
        // Cofactor 1: any point on the curve is in the prime-order group.
        if ((point * params.n)!.isInfinity) return Uint8List.fromList(joined);
      }
    } catch (_) {
      // Not on the curve; the next block.
    }
  }
  throw StateError('no point found');
}

void main() {
  group('RFC 9382 Appendix B (SPAKE2-P256-SHA256-HKDF-HMAC)', () {
    for (final v in _vectors) {
      test("A='${v.a}' B='${v.b}' reproduces the published values", () {
        final w = big(v.w);
        final a = Spake2.start(
            role: Spake2Role.a, w: w, secret: big(v.x));
        final b = Spake2.start(
            role: Spake2Role.b, w: w, secret: big(v.y));

        expect(toHex(a.share), equals(v.pA));
        expect(toHex(b.share), equals(v.pB));

        final idA = utf8.encode(v.a);
        final idB = utf8.encode(v.b);
        final fromA = a.finish(b.share, identityA: idA, identityB: idB);
        final fromB = b.finish(a.share, identityA: idA, identityB: idB);

        expect(toHex(fromA.transcript), equals(v.tt.replaceAll(RegExp(r'\s'), '')));
        expect(toHex(fromA.ke), equals(v.ke));
        expect(toHex(fromA.confirmationA), equals(v.confA));
        expect(toHex(fromA.confirmationB), equals(v.confB));

        // Both ends land on the same keys.
        expect(fromB.transcript, equals(fromA.transcript));
        expect(fromB.ke, equals(fromA.ke));
        expect(fromB.confirmationA, equals(fromA.confirmationA));
        expect(fromB.confirmationB, equals(fromA.confirmationB));
      });
    }
  });

  group('constants', () {
    test('M and N are the points Appendix A generates', () {
      expect(
        toHex(_generatePoint('1.2.840.10045.3.1.7 point generation seed (M)')),
        equals(Spake2.mCompressedHex),
      );
      expect(
        toHex(_generatePoint('1.2.840.10045.3.1.7 point generation seed (N)')),
        equals(Spake2.nCompressedHex),
      );
    });
  });

  group('a run between two honest ends', () {
    final w = big(_vectors.first.w);
    final idA = utf8.encode('receiver');
    final idB = utf8.encode('fingerprint-of-the-certificate');

    test('agrees on keys, and each confirmation verifies at the other end',
        () {
      final a = Spake2.start(role: Spake2Role.a, w: w);
      final b = Spake2.start(role: Spake2Role.b, w: w);
      final fromA = a.finish(b.share, identityA: idA, identityB: idB);
      final fromB = b.finish(a.share, identityA: idA, identityB: idB);

      expect(fromA.ke, equals(fromB.ke));
      expect(fromA.verifies(Spake2Role.b, fromB.confirmationB), isTrue);
      expect(fromB.verifies(Spake2Role.a, fromA.confirmationA), isTrue);
    });

    test('never repeats a share', () {
      final first = Spake2.start(role: Spake2Role.a, w: w);
      final second = Spake2.start(role: Spake2Role.a, w: w);
      expect(first.share, isNot(equals(second.share)));
    });

    test('shares are 65-byte uncompressed points', () {
      final share = Spake2.start(role: Spake2Role.a, w: w).share;
      expect(share.length, equals(Spake2.shareLength));
      expect(share.first, equals(0x04));
    });

    test('different passwords never agree', () {
      final a = Spake2.start(role: Spake2Role.a, w: w);
      final b = Spake2.start(role: Spake2Role.b, w: w + BigInt.one);
      final fromA = a.finish(b.share, identityA: idA, identityB: idB);
      final fromB = b.finish(a.share, identityA: idA, identityB: idB);

      expect(fromA.ke, isNot(equals(fromB.ke)));
      expect(fromA.verifies(Spake2Role.b, fromB.confirmationB), isFalse);
      expect(fromB.verifies(Spake2Role.a, fromA.confirmationA), isFalse);
    });

    test('a different B identity never agrees — the certificate is bound in',
        () {
      final a = Spake2.start(role: Spake2Role.a, w: w);
      final b = Spake2.start(role: Spake2Role.b, w: w);
      // The receiver saw one certificate, the real sender holds another.
      final fromA = a.finish(b.share,
          identityA: idA, identityB: utf8.encode('the-attackers-certificate'));
      final fromB = b.finish(a.share, identityA: idA, identityB: idB);

      expect(fromA.ke, isNot(equals(fromB.ke)));
      expect(fromA.verifies(Spake2Role.b, fromB.confirmationB), isFalse);
      expect(fromB.verifies(Spake2Role.a, fromA.confirmationA), isFalse);
    });

    test('a different A identity never agrees', () {
      final a = Spake2.start(role: Spake2Role.a, w: w);
      final b = Spake2.start(role: Spake2Role.b, w: w);
      final fromA = a.finish(b.share,
          identityA: utf8.encode('someone-else'), identityB: idB);
      final fromB = b.finish(a.share, identityA: idA, identityB: idB);

      expect(fromA.verifies(Spake2Role.b, fromB.confirmationB), isFalse);
    });

    test('different associated data change the confirmations, not the secret',
        () {
      final a = Spake2.start(role: Spake2Role.a, w: w);
      final b = Spake2.start(role: Spake2Role.b, w: w);
      final fromA = a.finish(b.share,
          identityA: idA, identityB: idB, aad: utf8.encode('v1'));
      final fromB = b.finish(a.share,
          identityA: idA, identityB: idB, aad: utf8.encode('v2'));

      expect(fromA.ke, equals(fromB.ke));
      expect(fromA.verifies(Spake2Role.b, fromB.confirmationB), isFalse);
    });

    test('a tampered confirmation does not verify', () {
      final a = Spake2.start(role: Spake2Role.a, w: w);
      final b = Spake2.start(role: Spake2Role.b, w: w);
      final fromA = a.finish(b.share, identityA: idA, identityB: idB);
      final fromB = b.finish(a.share, identityA: idA, identityB: idB);

      final flipped = Uint8List.fromList(fromB.confirmationB)..[31] ^= 0x01;
      expect(fromA.verifies(Spake2Role.b, flipped), isFalse);

      final truncated = fromB.confirmationB.sublist(0, 31);
      expect(fromA.verifies(Spake2Role.b, truncated), isFalse);

      expect(fromA.verifies(Spake2Role.b, Uint8List(0)), isFalse);
      expect(fromA.verifies(Spake2Role.b, Uint8List(32)), isFalse);
    });

    test('a confirmation does not verify as the other role\'s', () {
      final a = Spake2.start(role: Spake2Role.a, w: w);
      final b = Spake2.start(role: Spake2Role.b, w: w);
      final fromA = a.finish(b.share, identityA: idA, identityB: idB);
      final fromB = b.finish(a.share, identityA: idA, identityB: idB);

      // Reflecting a side's own tag back at it proves nothing.
      expect(fromA.verifies(Spake2Role.a, fromB.confirmationB), isFalse);
      expect(fromA.verifies(Spake2Role.b, fromB.confirmationA), isFalse);
    });
  });

  group('points that must be refused', () {
    final w = big(_vectors.first.w);
    final idA = utf8.encode('a');
    final idB = utf8.encode('b');
    final honest = Spake2.start(role: Spake2Role.a, w: w);
    final params = ECCurve_secp256r1();

    void refuses(List<int> share) {
      expect(
        () => honest.finish(share, identityA: idA, identityB: idB),
        throwsA(isA<Spake2Exception>()),
      );
    }

    test('the identity element', () {
      refuses([0x00]);
      refuses(Uint8List(65));
    });

    test('the wrong length or encoding', () {
      refuses(Uint8List(0));
      final good = Spake2.start(role: Spake2Role.b, w: w).share;
      refuses(good.sublist(0, 64));
      refuses([...good, 0]);
      // The same point in compressed form: the RFC fixes uncompressed.
      refuses(params.curve.decodePoint(good)!.getEncoded(true));
      // Hybrid prefix.
      refuses([0x06, ...good.sublist(1)]);
    });

    test('a point that is not on the curve', () {
      final good = Spake2.start(role: Spake2Role.b, w: w).share;
      refuses(Uint8List.fromList(good)..[64] ^= 0x01);
      refuses(Uint8List.fromList(good)..[1] ^= 0x01);
    });

    test('coordinates outside the field, even when they reduce to a point',
        () {
      final p = big(
          'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff');
      final b = big(
          '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b');
      Uint8List be(BigInt v) => Uint8List.fromList([
            for (var i = 31; i >= 0; i--)
              ((v >> (8 * i)) & BigInt.from(0xff)).toInt()
          ]);

      // The smallest x with a point above it. P-256's p is 3 mod 4, so the
      // square root is a single exponentiation.
      var x = BigInt.one;
      late BigInt y;
      while (true) {
        final rhs = (x * x * x - BigInt.from(3) * x + b) % p;
        y = rhs.modPow((p + BigInt.one) >> 2, p);
        if ((y * y) % p == rhs) break;
        x += BigInt.one;
      }
      // Sanity: the canonical encoding is a point, so only the range is wrong
      // in the cases below.
      expect(
        () => honest.finish([0x04, ...be(x), ...be(y)],
            identityA: idA, identityB: idB),
        returnsNormally,
      );

      // x + p is the same residue. A share has exactly one encoding.
      refuses([0x04, ...be(x + p), ...be(y)]);
      refuses([0x04, ...be(p), ...be(y)]);
      refuses([0x04, ...be(x), ...be(p)]);
      refuses([0x04, ...Uint8List(32)..fillRange(0, 32, 0xff), ...be(y)]);
    });

    test('a share that cancels to the identity once w*N is removed', () {
      // pB = w*N means Y is the identity: K would be the identity whatever
      // x is, and the run would "agree" on a key anybody can compute.
      final n = params.curve.decodePoint(hex(Spake2.nCompressedHex))!;
      final degenerate = (n * w)!.getEncoded(false);
      refuses(degenerate);
    });
  });

  group('inputs', () {
    test('a password scalar of zero or past the group order is refused', () {
      expect(() => Spake2.start(role: Spake2Role.a, w: BigInt.zero),
          throwsA(isA<ArgumentError>()));
      expect(() => Spake2.start(role: Spake2Role.a, w: Spake2.order),
          throwsA(isA<ArgumentError>()));
      expect(() => Spake2.start(role: Spake2Role.a, w: -BigInt.one),
          throwsA(isA<ArgumentError>()));
    });
  });
}

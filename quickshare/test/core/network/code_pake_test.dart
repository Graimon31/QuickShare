// The two small pieces of the code proof that a protocol test cannot see into:
// how the code becomes a scalar, and how a value is read off the wire.
//
// Both ends run the same functions, so a mistake in either one is invisible to
// every test that has the two talk to each other — they agree on the wrong
// thing. What pins them down is an answer worked out somewhere else.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/session_code.dart';

void main() {
  group('passwordScalar', () {
    // HKDF-SHA256 (RFC 5869, empty salt) of the digits, 64 bytes, with
    // info "directdrop/v2/code-pake/password", read as one big-endian number
    // and reduced modulo the order of P-256. Worked out with Python's hmac,
    // not with this code.
    const known = {
      '0000000000':
          '85dea1fda9f845b813eacd1e8bf843baebced28847c11b006e00a6897fa7a814',
      '1234567890':
          'd1b776b48ead1febf3b3ba8c53ee9a94ca882743b09a14c63ea3700804ee4834',
      '9999999999':
          '33322dbddabaec7e86b81a6450e66d602bce1fb7a1ce2f388a56015201f55cee',
    };

    for (final entry in known.entries) {
      test('${entry.key} is ${entry.value.substring(0, 12)}...', () {
        expect(CodePake.passwordScalar(SessionCode(entry.key)).toRadixString(16),
            entry.value);
      });
    }

    test('is not the digits read as a number', () {
      // The code is ten decimal digits, about 33 bits. Used as it stands it
      // would be a tiny scalar, and a guess would cost a handful of
      // multiplications instead of a derivation per try.
      final w = CodePake.passwordScalar(const SessionCode('1234567890'));
      expect(w, isNot(BigInt.from(1234567890)));
      expect(w.bitLength, greaterThan(200));
    });

    test('differs for codes one digit apart', () {
      final a = CodePake.passwordScalar(const SessionCode('1234567890'));
      final b = CodePake.passwordScalar(const SessionCode('1234567891'));
      expect(a, isNot(b));
    });
  });

  group('decode', () {
    final random = Random(77);
    Uint8List bytes(int n) =>
        Uint8List.fromList(List.generate(n, (_) => random.nextInt(256)));

    test('reads back exactly what encode wrote', () {
      for (final length in [1, 2, 3, 32, 65]) {
        final original = bytes(length);
        expect(CodePake.decode(CodePake.encode(original), length: length),
            original);
      }
    });

    test('wants one spelling only: padding is a different value', () {
      // 32 and 65 bytes are not multiples of three, so encode leaves padding
      // off and a padded spelling decodes to the same bytes if let through.
      for (final length in [32, 65]) {
        final original = bytes(length);
        final canonical = CodePake.encode(original);
        final padded = canonical + '=' * ((4 - canonical.length % 4) % 4);
        expect(padded, isNot(canonical), reason: 'the premise');

        expect(CodePake.decode(padded, length: length), isNull);
      }
    });

    test('wants one spelling only: unused bits at the end must be zero', () {
      // 32 bytes is 43 characters of 6 bits, the last carrying 4 bits and 2
      // spare ones. Two spellings of the same bytes differ only in those.
      final original = Uint8List(32); // all zero: the last character is 'A'
      final canonical = CodePake.encode(original);
      expect(canonical, endsWith('A'));
      final variant = '${canonical.substring(0, canonical.length - 1)}B';

      expect(CodePake.decode(canonical, length: 32), original);
      expect(CodePake.decode(variant, length: 32), isNull);
    });

    test('the standard alphabet is not the URL one', () {
      // 0xFB 0xFF 0xBF is "-_-_" in the URL alphabet and "+/+/" in the other.
      final original = Uint8List.fromList([0xFB, 0xFF, 0xBF]);
      expect(CodePake.encode(original), '-_-_');
      expect(CodePake.decode('-_-_', length: 3), original);
      expect(CodePake.decode('+/+/', length: 3), isNull);
    });

    test('refuses a value of the wrong length, in either direction', () {
      expect(CodePake.decode(CodePake.encode(bytes(31)), length: 32), isNull);
      expect(CodePake.decode(CodePake.encode(bytes(33)), length: 32), isNull);
      expect(CodePake.decode('', length: 32), isNull);
    });

    test('refuses anything that is not a string, and a string too long to '
        'be worth decoding', () {
      expect(CodePake.decode(null, length: 32), isNull);
      expect(CodePake.decode(42, length: 32), isNull);
      expect(CodePake.decode(<int>[1, 2, 3], length: 32), isNull);
      expect(CodePake.decode('A' * 10000, length: 32), isNull);
    });
  });
}

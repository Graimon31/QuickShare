import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/crypto/hkdf.dart';

Uint8List hex(String value) => Uint8List.fromList([
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ]);

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('HKDF-SHA256 (RFC 5869 Appendix A)', () {
    test('test case 1: basic', () {
      final okm = hkdfSha256(
        hex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        salt: hex('000102030405060708090a0b0c'),
        info: hex('f0f1f2f3f4f5f6f7f8f9'),
        length: 42,
      );
      expect(
        toHex(okm),
        equals('3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
            '34007208d5b887185865'),
      );
    });

    test('test case 3: no salt, no info', () {
      final okm = hkdfSha256(
        hex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        length: 42,
      );
      expect(
        toHex(okm),
        equals('8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d'
            '9d201395faa4b61a96c8'),
      );
    });

    test('asks for more than a hash block and gets exactly that', () {
      expect(hkdfSha256([1, 2, 3], length: 64), hasLength(64));
      expect(hkdfSha256([1, 2, 3], length: 0), isEmpty);
      expect(() => hkdfSha256([1], length: 255 * 32 + 1),
          throwsA(isA<ArgumentError>()));
    });
  });
}

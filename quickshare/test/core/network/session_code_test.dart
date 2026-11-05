import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/session_code.dart';

void main() {
  group('derivation', () {
    test('what is derived is the same for a code however it was typed', () {
      const shown = SessionCode('1234567890');
      final typed = SessionCode.parse('12345-67890')!;

      expect(typed.sessionToken, equals(shown.sessionToken));
      expect(typed.discoveryHint, equals(shown.discoveryHint));
    });

    test('different codes do not collide', () {
      const a = SessionCode('1234567890');
      const b = SessionCode('1234567891');

      expect(a.sessionToken, isNot(equals(b.sessionToken)));
    });

    test('the token is not the code', () {
      const code = SessionCode('1234567890');

      expect(code.sessionToken, isNot(contains(code.code)));
      expect(code.sessionToken, hasLength(32));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(code.sessionToken), isTrue);
    });

    test('a code no longer names a Wi-Fi network', () {
      // It used to: the network's name and passphrase were hashes of the
      // digits, and the name is broadcast, so thirty of the thirty-three bits
      // of the code were on the air. The network gets its own, at random (see
      // hotspot_naming_test.dart); nothing here is left to be misused for it.
      final source =
          File('lib/core/network/session_code.dart').readAsStringSync();
      final code = source
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('///'))
          .join('\n');

      for (final gone in ['get ssid', 'get passphrase', 'wifiQrPayload',
          'ssidPrefix', 'passphraseAlphabet']) {
        expect(code, isNot(contains(gone)), reason: gone);
      }
    });
  });

  group('publicId', () {
    test('is stable for the same code', () {
      expect(const SessionCode('1234567890').publicId,
          equals(SessionCode.parse('12345 67890')!.publicId));
    });

    test('is not the code or another output verbatim', () {
      // All this checks is that nothing is copied across. It does not make the
      // value safe to announce: forty bits of a hash over a 33-bit space can
      // be searched for the code in seconds, which is why the mDNS record
      // carries [discoveryHint] and this stays out of every announcement.
      const code = SessionCode('1234567890');
      expect(code.publicId, isNot(contains(code.code)));
      expect(code.publicId, isNot(equals(code.sessionToken)));
    });

    test('different codes get different identifiers', () {
      expect(const SessionCode('1234567890').publicId,
          isNot(equals(const SessionCode('1234567891').publicId)));
    });
  });

  group('discoveryHint', () {
    test('is stable for the same code', () {
      expect(const SessionCode('1234567890').discoveryHint,
          equals(SessionCode.parse('12345 67890')!.discoveryHint));
    });

    test('is one byte, as two lower-case hex digits', () {
      final random = Random(7);
      for (var i = 0; i < 500; i++) {
        final hint = SessionCode.generate(random).discoveryHint;
        expect(hint, matches(RegExp(r'^[0-9a-f]{2}$')));
      }
    });

    test('cannot be searched for the code: about forty million codes share '
        'every value', () {
      // Eight bits against a space of ten billion. What matters for the
      // eavesdropper is that the values spread evenly — a hint that favoured
      // a few would narrow things further — so over a large sample every one
      // of the 256 turns up, and none dominates.
      final random = Random(11);
      final seen = <String, int>{};
      const samples = 20000;
      for (var i = 0; i < samples; i++) {
        seen.update(SessionCode.generate(random).discoveryHint, (n) => n + 1,
            ifAbsent: () => 1);
      }
      expect(seen.length, equals(256));
      expect(seen.values.reduce(max), lessThan(samples * 3 ~/ 256));
    });
  });

  group('parse', () {
    test('accepts how people actually type it', () {
      const canonical = SessionCode('1234567890');

      expect(SessionCode.parse('1234567890'), equals(canonical));
      expect(SessionCode.parse('12345 67890'), equals(canonical));
      expect(SessionCode.parse('12345-67890'), equals(canonical));
      expect(SessionCode.parse('  12345—67890  '), equals(canonical));
    });

    test('anything that is not a digit is a typo, not something to drop', () {
      // Quietly dropping a stray character would produce a valid-looking code
      // that derives a different session, and the failure would surface later
      // as "cannot connect" with nothing to point at.
      expect(SessionCode.parse('123456789O'), isNull);
      expect(SessionCode.parse('1234 5678AB'), isNull);
    });

    test('the wrong length is refused', () {
      expect(SessionCode.parse('123456789'), isNull);
      expect(SessionCode.parse('12345678901'), isNull);
      expect(SessionCode.parse(''), isNull);
    });
  });

  group('display', () {
    test('is grouped so a person can read it aloud', () {
      expect(const SessionCode('1234567890').display, equals('12345 67890'));
    });

    test('what is displayed parses back to what was displayed', () {
      final generated = SessionCode.generate();
      expect(SessionCode.parse(generated.display), equals(generated));
    });
  });

  group('generate', () {
    test('produces a code of the right shape', () {
      final code = SessionCode.generate();

      expect(code.code, hasLength(SessionCode.length));
      for (final char in code.code.split('')) {
        expect(SessionCode.alphabet, contains(char));
      }
    });

    test('does not repeat itself', () {
      final codes = {for (var i = 0; i < 200; i++) SessionCode.generate().code};
      // 32^8 possibilities; 200 draws colliding would mean the source is not
      // random at all.
      expect(codes, hasLength(200));
    });

    test('a seeded source makes it reproducible for tests', () {
      expect(
        SessionCode.generate(Random(42)).code,
        equals(SessionCode.generate(Random(42)).code),
      );
    });
  });
}

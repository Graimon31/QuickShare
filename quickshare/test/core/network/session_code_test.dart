import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/session_code.dart';

void main() {
  group('derivation', () {
    test('both ends derive the same network from the code they share', () {
      // The whole point: nothing about the network is transmitted. The device
      // that raises it and the device that joins it work out the same name and
      // passphrase from the code alone.
      const shown = SessionCode('K7M2P4QX');
      final typed = SessionCode.parse('k7m2-p4qx')!;

      expect(typed.ssid, equals(shown.ssid));
      expect(typed.passphrase, equals(shown.passphrase));
      expect(typed.sessionToken, equals(shown.sessionToken));
    });

    test('different codes do not collide', () {
      const a = SessionCode('K7M2P4QX');
      const b = SessionCode('K7M2P4QY');

      expect(a.ssid, isNot(equals(b.ssid)));
      expect(a.passphrase, isNot(equals(b.passphrase)));
      expect(a.sessionToken, isNot(equals(b.sessionToken)));
    });

    test('the network name gives away nothing about the passphrase', () {
      // The SSID is broadcast in the clear to everyone in radio range. If it
      // shared a derivation with the passphrase it would be handing out the
      // key to the network it names.
      const code = SessionCode('K7M2P4QX');

      expect(code.ssid, isNot(contains(code.passphrase)));
      expect(code.passphrase, isNot(contains(code.ssid)));
      // Nor may either be a prefix of the other's derivation.
      expect(code.ssid.replaceFirst('DirectDrop-', ''),
          isNot(equals(code.passphrase.substring(0, 6))));
    });

    test('the token is not the code, and not the passphrase', () {
      const code = SessionCode('K7M2P4QX');

      expect(code.sessionToken, isNot(contains(code.code)));
      expect(code.sessionToken, isNot(equals(code.passphrase)));
      expect(code.sessionToken, hasLength(32));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(code.sessionToken), isTrue);
    });

    test('the SSID is recognisable and fits what Wi-Fi allows', () {
      // Prefixed so a device scanning the air can tell our networks apart from
      // the neighbours' before trying to join one. 32 bytes is the SSID limit.
      const code = SessionCode('K7M2P4QX');

      expect(code.ssid, startsWith('DirectDrop-'));
      expect(code.ssid.length, lessThanOrEqualTo(32));
    });

    test('the passphrase clears the WPA2 minimum', () {
      // Eight characters is the floor; anything shorter is refused by the
      // radio, not by us.
      expect(const SessionCode('K7M2P4QX').passphrase.length,
          greaterThanOrEqualTo(8));
    });

    test('derived values use only unambiguous characters', () {
      // A passphrase somebody may end up typing by hand must not contain the
      // pairs the alphabet exists to avoid.
      const code = SessionCode('K7M2P4QX');
      for (final char in code.passphrase.split('')) {
        expect(SessionCode.alphabet, contains(char));
      }
    });
  });

  group('parse', () {
    test('accepts how people actually type it', () {
      const canonical = SessionCode('K7M2P4QX');

      expect(SessionCode.parse('K7M2P4QX'), equals(canonical));
      expect(SessionCode.parse('k7m2p4qx'), equals(canonical));
      expect(SessionCode.parse('K7M2-P4QX'), equals(canonical));
      expect(SessionCode.parse('k7m2 p4qx'), equals(canonical));
      expect(SessionCode.parse('  K7M2—P4QX  '), equals(canonical));
    });

    test('a character outside the alphabet is a typo, not something to drop',
        () {
      // `O` for `0` is the classic one. Quietly dropping it would produce a
      // valid-looking code that derives a different network, and the failure
      // would surface later as "cannot connect" with nothing to point at.
      expect(SessionCode.parse('K7M2P4QO'), isNull);
      expect(SessionCode.parse('K7M2P4QI'), isNull);
      expect(SessionCode.parse('K7M2P4QL'), isNull);
      expect(SessionCode.parse('K7M2P4QU'), isNull);
    });

    test('the alphabet divides a byte evenly, so no character is favoured', () {
      // Derivation is `byte % alphabet.length`; at any size but a power of two
      // the low characters come up more often than the high ones.
      expect(SessionCode.alphabet, hasLength(32));
      expect(SessionCode.alphabet.split('').toSet(), hasLength(32),
          reason: 'a repeated symbol would skew the derivation too');
    });

    test('the wrong length is refused', () {
      expect(SessionCode.parse('K7M2P4Q'), isNull);
      expect(SessionCode.parse('K7M2P4QXY'), isNull);
      expect(SessionCode.parse(''), isNull);
    });
  });

  group('display', () {
    test('is grouped so a person can read it aloud', () {
      expect(const SessionCode('K7M2P4QX').display, equals('K7M2-P4QX'));
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

  group('wifiQrPayload', () {
    test('is the standard payload a phone camera already understands', () {
      // The joining device may not have the app yet — the system camera can
      // still put it on the network from this.
      const code = SessionCode('K7M2P4QX');
      final payload = code.wifiQrPayload;

      expect(payload, startsWith('WIFI:T:WPA;'));
      expect(payload, contains('S:${code.ssid};'));
      expect(payload, contains('P:${code.passphrase};'));
      expect(payload, endsWith(';;'));
    });
  });
}

// A network's name and passphrase are drawn at random, from nothing.
//
// They used to be hashes of a ten-digit code, the same at both ends. The name is
// broadcast, so thirty of the code's thirty-three bits were in it, and the
// passphrase followed (see hotspot_credentials_not_from_code_test.dart for the
// search that finds it). What is checked here is what is left: that the pair is
// a good one for WPA2 and for every place it is put, and that nothing makes one
// pair predictable from another.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/hotspot_naming.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';

void main() {
  group('the name', () {
    test('is recognisable, and fits what Wi-Fi allows', () {
      for (var i = 0; i < 200; i++) {
        final ssid = HotspotNaming.generate().ssid;

        expect(ssid, startsWith('DirectDrop-'),
            reason: 'a device scanning the air tells our networks by it');
        expect(utf8.encode(ssid).length, lessThanOrEqualTo(32),
            reason: 'the limit on an SSID is 32 bytes');
        expect(ssid.length, 'DirectDrop-'.length + 6);
      }
    });

    test('is made of characters nothing needs to escape', () {
      for (var i = 0; i < 200; i++) {
        final suffix = HotspotNaming.generate()
            .ssid
            .substring(HotspotNaming.ssidPrefix.length);

        expect(suffix, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{6}$')));
      }
    });
  });

  group('the passphrase', () {
    test('clears WPA2\'s eight characters and stays far from its sixty-three',
        () {
      for (var i = 0; i < 200; i++) {
        final passphrase = HotspotNaming.generate().passphrase;

        expect(passphrase.length, HotspotNaming.passphraseLength);
        expect(passphrase.length, inInclusiveRange(8, 63));
      }
    });

    test('is printable ASCII, and none of it needs escaping anywhere it goes',
        () {
      // The `WIFI:` QR escapes \ ; , : and ". A command line, the XML Windows
      // keeps a profile in and a dialog somebody types it into all have their
      // own. Letters and digits are none of those.
      for (var i = 0; i < 500; i++) {
        final passphrase = HotspotNaming.generate().passphrase;

        expect(passphrase, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{12}$')));
        for (final unit in passphrase.codeUnits) {
          expect(unit, inInclusiveRange(0x20, 0x7E));
        }
      }
    });

    test('stays out of the characters people mistake for one another', () {
      expect(HotspotNaming.alphabet, hasLength(32));
      expect(HotspotNaming.alphabet.split('').toSet(), hasLength(32));
      for (final lookAlike in ['I', 'L', 'O', 'U']) {
        expect(HotspotNaming.alphabet, isNot(contains(lookAlike)));
      }
    });

    test('goes into the QR a phone camera reads without any escaping', () {
      final naming = HotspotNaming.generate();
      final credentials =
          HotspotCredentials(ssid: naming.ssid, passphrase: naming.passphrase);

      expect(credentials.toWifiQrPayload(),
          'WIFI:T:WPA;S:${naming.ssid};P:${naming.passphrase};;');
    });
  });

  group('each pair', () {
    test('is new: no two networks share a passphrase', () {
      final seen = {
        for (var i = 0; i < 5000; i++) HotspotNaming.generate().passphrase
      };

      expect(seen, hasLength(5000),
          reason: 'sixty random bits do not repeat in five thousand draws');
    });

    test('and no two share a name, but for the chance thirty bits allow', () {
      final seen = {for (var i = 0; i < 300; i++) HotspotNaming.generate().ssid};

      expect(seen.length, greaterThanOrEqualTo(298));
    });

    test('draws every symbol about equally often', () {
      final counts = <String, int>{};
      for (var i = 0; i < 2000; i++) {
        for (final char in HotspotNaming.generate().passphrase.split('')) {
          counts.update(char, (n) => n + 1, ifAbsent: () => 1);
        }
      }

      // 24000 characters over 32 symbols: 750 each. A source that favoured some
      // (a modulo of a number that does not divide it) would show here.
      expect(counts.keys.toSet(), HotspotNaming.alphabet.split('').toSet());
      for (final entry in counts.entries) {
        expect(entry.value, inInclusiveRange(600, 900), reason: entry.key);
      }
    });

    test('has a name that says nothing about its passphrase', () {
      // Two separate draws. The name is public; if any of it were also in the
      // passphrase, the name would be handing out part of the key.
      for (var i = 0; i < 3000; i++) {
        final naming = HotspotNaming.generate();
        final suffix = naming.ssid.substring(HotspotNaming.ssidPrefix.length);

        expect(naming.passphrase, isNot(contains(suffix)));
      }
    });

    test('comes from the source it is given, and from nothing else', () {
      // A hidden input — a code, a clock, a device name — would make two
      // generators on the same seed differ.
      final a = HotspotNaming.generate(Random(42));
      final b = HotspotNaming.generate(Random(42));
      final c = HotspotNaming.generate(Random(43));

      expect(a.ssid, b.ssid);
      expect(a.passphrase, b.passphrase);
      expect(a.passphrase, isNot(c.passphrase));
    });
  });

  group('the source', () {
    final source = File('lib/core/network/hotspot_naming.dart').readAsStringSync();

    test('is cryptographic unless a test says otherwise', () {
      expect(source, contains('Random.secure()'));
    });

    test('takes nothing from a session code, a token or a locator', () {
      final code = source
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('///'))
          .join('\n');

      for (final forbidden in [
        'session_code', 'SessionCode', 'sha256', 'crypto', 'sessionToken',
        'locator', 'DateTime',
      ]) {
        expect(code, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });
}

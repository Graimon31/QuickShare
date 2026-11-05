// What a Bluetooth session is made of, and what each side does with it.
//
// The rule this protects is the one that is easy to get wrong and impossible
// to see: what goes out over the air is a random locator, never the token and
// never anything worked out from a session code. Earlier builds advertised
// `QuickShare-<first eight characters of the token>`, which put part of the
// session's own secret in a packet anyone in radio range can read; the build
// after them advertised a hash of the code's digits instead, which anyone in
// range could search for the digits (about 33 bits: seconds of hashing).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/core/transfer/ble_session.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

void main() {
  group('what a Bluetooth session is made of', () {
    test('a locator of the right length, in the alphabet people can read', () {
      final locator = BleAdvertisement.newLocator();

      expect(locator, hasLength(BleAdvertisement.locatorLength));
      expect(locator, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{8}$')),
          reason: 'no I, L, O or U: it is sometimes read off a log');
    });

    test('a token of 128 bits, as hex', () {
      expect(BleSession.generate().token, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('two sessions do not collide on either half', () {
      final a = BleSession.generate();
      final b = BleSession.generate();

      expect(a.locator, isNot(equals(b.locator)));
      expect(a.token, isNot(equals(b.token)));
    });

    test('a thousand locators are a thousand different ones', () {
      // Forty random bits: a repeat in a thousand draws would mean the source
      // is not random at all.
      final seen = {for (var i = 0; i < 1000; i++) BleAdvertisement.newLocator()};
      expect(seen, hasLength(1000));
    });

    test('the locator gives nothing away about the token, nor the token about '
        'the locator', () {
      // Not a proof, and not meant as one — it catches the mistake actually
      // made here, which was advertising a slice of the token itself.
      for (var i = 0; i < 50; i++) {
        final session = BleSession.generate();
        expect(session.token.toLowerCase().contains(session.locator.toLowerCase()),
            isFalse);
        expect(session.locator.toLowerCase().contains(session.token), isFalse);
      }
    });

    test('everything comes from the source it is given, and from nothing else',
        () {
      // Seeded: the same source gives the same session. A hidden input — a
      // code, a clock, a device name — would make these differ.
      final a = BleSession.generate(Random(7));
      final b = BleSession.generate(Random(7));

      expect(a.locator, b.locator);
      expect(a.token, b.token);
    });
  });

  group('the advertised name', () {
    test('carries the locator, not the token', () {
      final session = BleSession.generate();
      final name =
          BluetoothTransferTransport.bleAdvertisedName(locator: session.locator);

      expect(name, equals('QuickShare-${session.locator}'));
      expect(name.contains(session.token.substring(0, 8)), isFalse,
          reason: 'the token must not be readable off the air');
    });

    test('falls back to safe directdrop name for a session without a locator',
        () {
      final name = BluetoothTransferTransport.bleAdvertisedName(locator: '');
      expect(name, equals('QuickShare-directdrop'));
      expect(name.contains('token'), isFalse);
    });

    test('bridges never leak token prefix in advertised names', () {
      final linuxBridge =
          File('lib/features/sender/data/transports/linux_bluetooth_sender.dart')
              .readAsStringSync();
      final transport = File(
              'lib/features/sender/data/transports/bluetooth_transfer_transport.dart')
          .readAsStringSync();
      final iosSwift =
          File('ios/Runner/QuickShareBluetooth.swift').readAsStringSync();
      final macSwift =
          File('macos/Runner/QuickShareBluetooth.swift').readAsStringSync();

      expect(linuxBridge, isNot(contains('token.substring(0, 8)')));
      expect(transport, isNot(contains('token.substring(0, 8)')));
      expect(iosSwift, isNot(contains('sessionToken.prefix(8)')));
      expect(macSwift, isNot(contains('sessionToken.prefix(8)')));
    });
  });

  group('the QR payload', () {
    test('carries both halves, so the receiver can find the sender and start '
        'the session', () {
      final session = BleSession.generate();
      final encoded = BluetoothQrPayload(
        token: session.token,
        locator: session.locator,
      ).encode();

      final decoded = BluetoothQrPayload.tryDecode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.token, equals(session.token));
      expect(decoded.locator, equals(session.locator),
          reason: 'the scanner matches the advertisement on this, and the two '
              'devices bind the sealed credentials to it');
    });

    test('still reads one from a build that sent no locator', () {
      final old = const BluetoothQrPayload(token: 'a-token').encode();
      final decoded = BluetoothQrPayload.tryDecode(old);

      expect(decoded, isNotNull);
      expect(decoded!.token, equals('a-token'));
      expect(decoded.locator, isEmpty,
          reason: 'absent, so the receiver falls back to the token match');
    });

    test('keeps the key older receivers read it under', () {
      // An older receiver that scans a current QR looks for the name in `cid`,
      // finds the sender, and is told to update. Under another key it would
      // search for a sender that never turns up and say nothing useful.
      final raw = const BluetoothQrPayload(token: 't', locator: 'ABCD2345')
          .encode()
          .substring(BluetoothQrPayload.prefix.length);
      expect(String.fromCharCodes(base64Url.decode(base64Url.normalize(raw))),
          contains('"cid":"ABCD2345"'));
    });
  });

  group('a receiver giving its name', () {
    test('a name survives the round trip', () {
      final written = BleControlProtocol.hello("Farman's iPhone");
      expect(BleControlProtocol.parseHello(written), equals("Farman's iPhone"));
    });

    test('the other commands are not mistaken for it', () {
      // They share one characteristic, so a HELLO test that matched START
      // would begin a transfer nobody asked for.
      expect(BleControlProtocol.parseHello(BleControlProtocol.start('t')),
          isNull);
      expect(BleControlProtocol.parseHello(BleControlProtocol.capabilities()),
          isNull);
    });

    test('a nameless or oversized announcement is refused', () {
      // The name is chosen by the far side and is only ever text.
      expect(BleControlProtocol.parseHello('HELLO:'), isNull);
      expect(BleControlProtocol.parseHello('HELLO:   '), isNull);
      expect(BleControlProtocol.parseHello('HELLO:${'x' * 65}'), isNull);
    });

    test('it does not claim a new generation', () {
      // A HELLO is not a CAPS write: it must not make the receiver look
      // newer than it is. Generation 5 is the rendezvous with nothing derived
      // from a session code on the air — the bump after the one that took the
      // file off the radio entirely.
      expect(BleControlProtocol.generation, equals(5));
      expect(BleControlProtocol.peerSupportsDirectLink(5), isTrue);
      expect(
        BleControlProtocol.peerSupportsDirectLink(4),
        isFalse,
        reason: 'a generation-4 receiver seals and opens against a value this '
            'build no longer sends, so it cannot take part',
      );
      expect(BleControlProtocol.peerSupportsDirectLink(3), isFalse);
    });
  });
}

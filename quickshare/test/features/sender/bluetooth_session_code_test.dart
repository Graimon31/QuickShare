// The digits, and what each side does with them over Bluetooth.
//
// The rule this protects is the one that is easy to get wrong and impossible
// to see: what goes out over the air is the code's public half, never the
// token. Earlier builds advertised `QuickShare-<first eight characters of the
// token>`, which put part of the session's own secret in a packet anyone in
// radio range can read — and it only worked as a filter because of that.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

void main() {
  group('what the two sides derive from the digits', () {
    test('the same code reaches the same session on both devices', () {
      // The sender generates; the receiver types. Nothing about the session
      // travels between them, so these have to agree by derivation alone.
      final sender = SessionCode.generate();
      final receiver = SessionCode.parse(sender.display);

      expect(receiver, isNotNull);
      expect(receiver!.sessionToken, equals(sender.sessionToken));
      expect(receiver.publicId, equals(sender.publicId));
    });

    test('two codes do not collide on either half', () {
      final a = SessionCode.generate();
      final b = SessionCode.generate();
      expect(a.publicId, isNot(equals(b.publicId)));
      expect(a.sessionToken, isNot(equals(b.sessionToken)));
    });

    test('the public half gives nothing away about the token', () {
      // Not a proof, and not meant as one — it catches the mistake actually
      // made here, which was advertising a slice of the token itself.
      final code = SessionCode.generate();
      expect(code.sessionToken.contains(code.publicId), isFalse);
      expect(code.publicId.contains(code.sessionToken), isFalse);
    });
  });

  group('the advertised name', () {
    test('carries the public half, not the token', () {
      final code = SessionCode.generate();
      final name = BluetoothTransferTransport.bleAdvertisedName(
          publicId: code.publicId);

      expect(name, equals('QuickShare-${code.publicId}'));
      expect(name.contains(code.sessionToken.substring(0, 8)), isFalse,
          reason: 'the token must not be readable off the air');
    });

    test('falls back to safe directdrop name for a session without a code', () {
      final name = BluetoothTransferTransport.bleAdvertisedName(publicId: '');
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
    test('carries both halves, so scanning and typing agree', () {
      final code = SessionCode.generate();
      final encoded = BluetoothQrPayload(
        token: code.sessionToken,
        publicId: code.publicId,
      ).encode();

      final decoded = BluetoothQrPayload.tryDecode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.token, equals(code.sessionToken));
      expect(decoded.publicId, equals(code.publicId),
          reason: 'the scanner matches the advertisement on this');
    });

    test('still reads one from a build that sent no identifier', () {
      final old = const BluetoothQrPayload(token: 'a-token').encode();
      final decoded = BluetoothQrPayload.tryDecode(old);

      expect(decoded, isNotNull);
      expect(decoded!.token, equals('a-token'));
      expect(decoded.publicId, isEmpty,
          reason: 'absent, so the receiver falls back to the token match');
    });
  });

  group('announcing a receiver that is only waiting', () {
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
      // The name is chosen by the far side and drawn in a list.
      expect(BleControlProtocol.parseHello('HELLO:'), isNull);
      expect(BleControlProtocol.parseHello('HELLO:   '), isNull);
      expect(BleControlProtocol.parseHello('HELLO:${'x' * 65}'), isNull);
    });

    test('it does not claim a new generation', () {
      // A HELLO is not a CAPS write: it must not make the receiver look
      // newer than it is. Generation 4 is the direct-link rendezvous — the
      // bump that took the file off the radio entirely.
      expect(BleControlProtocol.generation, equals(4));
      expect(BleControlProtocol.peerSupportsDirectLink(4), isTrue);
      expect(
        BleControlProtocol.peerSupportsDirectLink(3),
        isFalse,
        reason: 'a generation-3 receiver knows only how to be sent the file '
            'over the radio, which is no longer a path this build takes',
      );
    });
  });
}

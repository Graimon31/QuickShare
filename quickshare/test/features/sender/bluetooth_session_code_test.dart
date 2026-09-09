// The digits, and what each side does with them over Bluetooth.
//
// The rule this protects is the one that is easy to get wrong and impossible
// to see: what goes out over the air is the code's public half, never the
// token. Earlier builds advertised `QuickShare-<first eight characters of the
// token>`, which put part of the session's own secret in a packet anyone in
// radio range can read — and it only worked as a filter because of that.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/session_code.dart';
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
    /// Exactly what the transport and both native bridges build.
    String advertisedName(String token, String publicId) =>
        'QuickShare-${publicId.isNotEmpty ? publicId : token.substring(0, 8)}';

    test('carries the public half, not the token', () {
      final code = SessionCode.generate();
      final name = advertisedName(code.sessionToken, code.publicId);

      expect(name, equals('QuickShare-${code.publicId}'));
      expect(name.contains(code.sessionToken.substring(0, 8)), isFalse,
          reason: 'the token must not be readable off the air');
    });

    test('falls back to the token for a session without a code', () {
      // What an older sender still does. The receiver has to keep matching it
      // or this build simply cannot see those devices.
      final name = advertisedName('0123456789abcdef', '');
      expect(name, equals('QuickShare-01234567'));
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
      final old = BluetoothQrPayload(token: 'a-token').encode();
      final decoded = BluetoothQrPayload.tryDecode(old);

      expect(decoded, isNotNull);
      expect(decoded!.token, equals('a-token'));
      expect(decoded.publicId, isEmpty,
          reason: 'absent, so the receiver falls back to the token match');
    });
  });
}

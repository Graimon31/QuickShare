import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';

void main() {
  group('DeepLinkService.parseRoomCode', () {
    test('accepts the canonical share link', () {
      expect(DeepLinkService.parseRoomCode(Uri.parse('directdrop://join?room=A1B2C3')), 'A1B2C3');
    });

    test('uppercases a lowercase code', () {
      expect(DeepLinkService.parseRoomCode(Uri.parse('directdrop://join?room=a1b2c3')), 'A1B2C3');
    });

    test('accepts the code as a trailing path segment', () {
      expect(DeepLinkService.parseRoomCode(Uri.parse('directdrop://join/A1B2C3')), 'A1B2C3');
    });

    test('rejects a foreign scheme', () {
      expect(DeepLinkService.parseRoomCode(Uri.parse('https://evil.example/join?room=A1B2C3')), isNull);
    });

    test('rejects a malformed code', () {
      expect(DeepLinkService.parseRoomCode(Uri.parse('directdrop://join?room=TOO-LONG-123')), isNull);
      expect(DeepLinkService.parseRoomCode(Uri.parse('directdrop://join?room=AB1')), isNull);
      expect(DeepLinkService.parseRoomCode(Uri.parse('directdrop://join?room=')), isNull);
    });

    test('rejects a link with no room at all', () {
      expect(DeepLinkService.parseRoomCode(Uri.parse('directdrop://join')), isNull);
    });

    test('rejects the retired quickshare:// scheme', () {
      // The product was renamed off the Quick Share trademark; a link in the
      // old scheme belongs to whatever else claims it now, not to us.
      expect(
          DeepLinkService.parseRoomCode(
              Uri.parse('quickshare://join?room=A1B2C3')),
          isNull);
    });
  });

  group('DeepLinkService.parseFromText', () {
    test('accepts a pasted full link', () {
      expect(DeepLinkService.parseFromText('  directdrop://join?room=A1B2C3  '), 'A1B2C3');
    });

    test('accepts a bare six-character code', () {
      expect(DeepLinkService.parseFromText('a1b2c3'), 'A1B2C3');
    });

    test('rejects arbitrary text', () {
      expect(DeepLinkService.parseFromText('hello there'), isNull);
      expect(DeepLinkService.parseFromText(''), isNull);
      expect(DeepLinkService.parseFromText('https://example.com'), isNull);
    });
  });

  group('DeepLinkService Internet invite + sig', () {
    test('parses sig from share link', () {
      final link = DeepLinkService.buildShareLink(
        roomCode: '0AB3B4',
        signalingUrlForPeer: 'ws://192.168.1.42:3000',
      );
      final invite = DeepLinkService.parseInternetInvite(link);
      expect(invite, isNotNull);
      expect(invite!.roomCode, '0AB3B4');
      expect(invite.signalingUrl, 'ws://192.168.1.42:3000');
    });

    test('bare room has no signaling url', () {
      final invite = DeepLinkService.parseInternetInvite('A1B2C3');
      expect(invite?.roomCode, 'A1B2C3');
      expect(invite?.signalingUrl, isNull);
    });

    test('rejects non-ws sig', () {
      final uri = Uri.parse(
          'directdrop://join?room=A1B2C3&sig=${Uri.encodeComponent('http://evil')}');
      final invite = DeepLinkService.parseInternetInviteFromUri(uri);
      expect(invite?.roomCode, 'A1B2C3');
      expect(invite?.signalingUrl, isNull);
    });
  });

  group('DeepLinkService payload share link', () {
    test('round-trips a serverless QR payload', () {
      const payload = 'QS1abcdefghijk';
      final link = DeepLinkService.buildPayloadLink(payload);
      expect(link, startsWith('directdrop://join?p='));
      final parsed = DeepLinkService.parseSharePayloadFromUri(Uri.parse(link));
      expect(parsed, payload);
    });

    test('round-trips a compressed QHTP locator', () {
      const payload = 'eJyNjsEKwjAQRP-l';
      final link = DeepLinkService.buildPayloadLink(payload);
      expect(DeepLinkService.parseSharePayloadFromUri(Uri.parse(link)), payload);
    });

    test('unwrapToQrPayload peels the wrapper and leaves raw QR text alone', () {
      const payload = 'QS1rawpayload';
      expect(
        DeepLinkService.unwrapToQrPayload(
            DeepLinkService.buildPayloadLink(payload)),
        payload,
      );
      expect(DeepLinkService.unwrapToQrPayload('  QS1rawpayload  '), payload);
    });

    test('a room invite is not mistaken for a payload link', () {
      final uri = Uri.parse('directdrop://join?room=A1B2C3');
      expect(DeepLinkService.parseSharePayloadFromUri(uri), isNull);
      expect(DeepLinkService.unwrapToQrPayload(uri.toString()), uri.toString());
    });

    test('rejects an empty p=', () {
      expect(
        DeepLinkService.parseSharePayloadFromUri(
            Uri.parse('directdrop://join?p=')),
        isNull,
      );
    });

    test('carries file name, size and count for the receiver preview', () {
      final link = DeepLinkService.buildPayloadLink(
        'QS1abcdefghijk',
        name: 'Vacation.jpg',
        bytes: 1234567,
        itemCount: 1,
      );
      final parsed = DeepLinkService.parseShareLink(link);
      expect(parsed, isNotNull);
      expect(parsed!.qrPayload, 'QS1abcdefghijk');
      expect(parsed.name, 'Vacation.jpg');
      expect(parsed.bytes, 1234567);
      expect(parsed.itemCount, 1);
    });

    test('encodes a Cyrillic folder name without losing it', () {
      final link = DeepLinkService.buildPayloadLink(
        'QS1x',
        name: 'Фото',
        bytes: 42,
        itemCount: 3,
      );
      final parsed = DeepLinkService.parseShareLink(link)!;
      expect(parsed.name, 'Фото');
      expect(parsed.itemCount, 3);
    });
  });
}

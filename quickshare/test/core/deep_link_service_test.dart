import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';

void main() {
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

    test('a link with no p= is not mistaken for a payload link', () {
      final uri = Uri.parse('directdrop://join?x=1');
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

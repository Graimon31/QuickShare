import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';

void main() {
  group('QRPayload v2 (QHTP locator)', () {
    test('encode/decode roundtrip preserves sid, mode and size metadata', () {
      final payload = QRPayload(
        version: 2,
        ip: '192.168.1.42',
        port: 8123,
        token: '550e8400-e29b-41d4-a716-446655440000',
        sessionId: 'a1b2c3d4e5f6789012345678',
        mode: 'http-lan',
        fileName: 'Vacation',
        fileSize: 12345678,
        itemCount: 12,
      );

      expect(payload.isQhtp, isTrue);
      expect(payload.isValid, isTrue);

      final encoded = payload.encode();
      final decoded = QRPayload.decode(encoded);

      expect(decoded.version, 2);
      expect(decoded.ip, '192.168.1.42');
      expect(decoded.port, 8123);
      expect(decoded.token, payload.token);
      expect(decoded.sessionId, payload.sessionId);
      expect(decoded.mode, 'http-lan');
      expect(decoded.isQhtp, isTrue);
      expect(decoded.fileName, 'Vacation');
      expect(decoded.fileSize, 12345678);
      expect(decoded.itemCount, 12);
    });

    test('isValid requires sessionId for QHTP', () {
      final invalid = QRPayload(
        version: 2,
        ip: '10.0.0.1',
        port: 8000,
        token: 'tok',
        sessionId: null,
      );
      // version 2 alone without sid: isQhtp is true via version==2
      // but isValid needs non-empty sessionId
      expect(invalid.isValid, isFalse);

      final valid = QRPayload(
        version: 2,
        ip: '10.0.0.1',
        port: 8000,
        token: 'tok',
        sessionId: 'abc',
      );
      expect(valid.isValid, isTrue);
    });

    test('QRPayloadDecoder accepts v2 and rejects unsupported version', () {
      final decoder = QRPayloadDecoder();
      final payload = QRPayload(
        version: 2,
        ip: '192.168.0.5',
        port: 9000,
        token: 't',
        sessionId: 'sid1',
        mode: 'http-lan',
      );
      final encoded = payload.encode();
      final decoded = decoder.decode(encoded);
      expect(decoded.sessionId, 'sid1');

      // Manually craft base64url JSON with v=99 (encode() always forces v:2 for isQhtp)
      final badJson = '{"v":99,"ip":"1.1.1.1","p":1,"t":"t","sid":"x","mode":"http-lan"}';
      final badEncoded = base64UrlEncode(utf8.encode(badJson));
      expect(() => decoder.decode(badEncoded), throwsA(anything));
    });
  });
}

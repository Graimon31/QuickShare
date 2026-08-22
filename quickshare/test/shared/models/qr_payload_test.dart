import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

void main() {
  group('QRPayload', () {
    test('encode and decode roundtrip', () {
      const payload = QRPayload(
        version: 1,
        ip: '192.168.1.1',
        port: 8080,
        token: 'test-token-abc',
        fileName: 'document.pdf',
        fileSize: 1024,
        checksum: 'sha256:abc123',
      );
      final encoded = payload.encode();
      final decoded = QRPayload.decode(encoded);
      expect(decoded.ip, equals(payload.ip));
      expect(decoded.port, equals(payload.port));
      expect(decoded.token, equals(payload.token));
      expect(decoded.fileName, equals(payload.fileName));
      expect(decoded.fileSize, equals(payload.fileSize));
    });

    test('isValid returns false for empty token', () {
      const payload = QRPayload(
        version: 1, ip: '192.168.1.1', port: 8080,
        token: '', fileName: 'test.txt', fileSize: 100, checksum: 'x',
      );
      expect(payload.isValid, isFalse);
    });

    test('isValid returns true for fileSize zero (0-byte file)', () {
      const payload = QRPayload(
        version: 1, ip: '192.168.1.1', port: 8080,
        token: 'tok', fileName: 'test.txt', fileSize: 0, checksum: 'x',
      );
      expect(payload.isValid, isTrue);
    });

    test('decode throws on invalid base64', () {
      expect(() => QRPayload.decode('not-valid-base64!!!'), throwsA(anything));
    });
  });
}

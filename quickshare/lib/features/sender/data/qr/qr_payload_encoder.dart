import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/constants/app_constants.dart';

class QRPayloadEncoder {
  String encode({
    required String ip,
    required int port,
    required String token,
    required String fileName,
    required int fileSize,
    required String checksum,
    required String tlsFingerprint,
  }) {
    if (ip.isEmpty ||
        port <= 0 ||
        token.isEmpty ||
        fileName.isEmpty ||
        fileSize < 0) {
      throw ArgumentError('Invalid payload parameters');
    }
    if (tlsFingerprint.isEmpty) {
      // The LAN server is HTTPS-only now; a payload with no fingerprint to
      // pin to could only describe a plaintext server, and that is the hole
      // this closes.
      throw ArgumentError('Missing TLS fingerprint');
    }

    final payload = QRPayload(
      version: AppConstants.qrPayloadVersion,
      ip: ip,
      port: port,
      token: token,
      fileName: fileName,
      fileSize: fileSize,
      checksum: checksum,
      tlsFingerprint: tlsFingerprint,
    );

    return payload.encode();
  }
}

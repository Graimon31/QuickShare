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
  }) {
    if (ip.isEmpty ||
        port <= 0 ||
        token.isEmpty ||
        fileName.isEmpty ||
        fileSize < 0) {
      throw ArgumentError('Invalid payload parameters');
    }

    final payload = QRPayload(
      version: AppConstants.qrPayloadVersion,
      ip: ip,
      port: port,
      token: token,
      fileName: fileName,
      fileSize: fileSize,
      checksum: checksum,
    );

    return payload.encode();
  }
}

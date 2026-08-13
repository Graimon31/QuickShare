import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';

class QRPayloadDecoder {
  /// Marks a payload whose `sdpOffer` holds a raw [ServerlessQr] string rather
  /// than an SDP body. The bloc branches on this to run the sealed-answer flow.
  static const String serverlessMode = 'webrtc-qs1';

  QRPayload decode(String rawQRData) {
    if (ServerlessQr.looksLikeOne(rawQRData)) {
      // Validate by decoding — a corrupt scan should fail here rather than
      // halfway through the handshake.
      final qr = ServerlessQr.decode(rawQRData.trim());
      return QRPayload(
        version: 2,
        ip: 'p2p',
        port: 0,
        token: qr.offer.iceUfrag,
        sessionId: qr.offer.iceUfrag,
        mode: serverlessMode,
        sdpOffer: rawQRData.trim(),
      );
    }

    try {
      final payload = QRPayload.decode(rawQRData);
      if (payload.version != 1 && payload.version != 2) {
        throw Exception('Unsupported QR version: ${payload.version}. Expected 1 or 2.');
      }
      if (!payload.isValid) {
        throw Exception('Invalid payload fields');
      }
      return payload;
    } catch (e) {
      final roomCode = DeepLinkService.parseFromText(rawQRData);
      if (roomCode != null) {
        return QRPayload(
          version: 1,
          ip: 'webrtc',
          port: 0,
          token: roomCode,
          mode: 'internet',
          fileName: 'Internet Transfer ($roomCode)',
        );
      }
      throw ServerException('Invalid QR Code data: $e');
    }
  }
}

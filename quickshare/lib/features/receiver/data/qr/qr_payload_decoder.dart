import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';

class QRPayloadDecoder {
  /// Marks a payload whose `sdpOffer` holds a raw [ServerlessQr] string rather
  /// than an SDP body. The bloc branches on this to run the sealed-answer flow.
  static const String serverlessMode = 'webrtc-qs1';

  QRPayload decode(String rawQRData) {
    final share = DeepLinkService.parseShareLink(rawQRData);
    final unwrapped = share?.qrPayload ??
        DeepLinkService.unwrapToQrPayload(rawQRData);
    if (ServerlessQr.looksLikeOne(unwrapped)) {
      // Validate by decoding — a corrupt scan should fail here rather than
      // halfway through the handshake.
      final qr = ServerlessQr.decode(unwrapped);
      return QRPayload(
        version: 2,
        ip: 'p2p',
        port: 0,
        token: qr.offer.iceUfrag,
        sessionId: qr.offer.iceUfrag,
        mode: serverlessMode,
        sdpOffer: unwrapped,
        fileName: share?.name ?? '',
        fileSize: share?.bytes ?? 0,
        itemCount: share?.itemCount ?? 0,
      );
    }

    try {
      final payload = QRPayload.decode(unwrapped);
      if (payload.version != 1 && payload.version != 2) {
        throw Exception('Unsupported QR version: ${payload.version}. Expected 1 or 2.');
      }
      if (!payload.isValid) {
        throw Exception('Invalid payload fields');
      }
      return QRPayload(
        version: payload.version,
        ip: payload.ip,
        port: payload.port,
        token: payload.token,
        fileName: payload.fileName.isNotEmpty
            ? payload.fileName
            : (share?.name ?? ''),
        fileSize: payload.fileSize > 0 ? payload.fileSize : (share?.bytes ?? 0),
        checksum: payload.checksum,
        sessionId: payload.sessionId,
        mode: payload.mode,
        sdpOffer: payload.sdpOffer,
        itemCount: payload.itemCount > 0
            ? payload.itemCount
            : (share?.itemCount ?? 0),
      );
    } catch (e) {
      final roomCode = DeepLinkService.parseFromText(unwrapped);
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

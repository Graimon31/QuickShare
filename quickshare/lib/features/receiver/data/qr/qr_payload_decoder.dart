import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';

class QRPayloadDecoder {
  /// Marks a payload whose `sdpOffer` holds a raw [ServerlessQr] string rather
  /// than an SDP body. The bloc branches on this to run the sealed-answer flow.
  static const String serverlessMode = 'webrtc-qs1';
  static const String bluetoothMode = 'bluetooth';

  QRPayload decode(String rawQRData) {
    final unwrapped = rawQRData.trim();
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
        fileName: qr.fileName,
        fileSize: qr.fileSize,
        itemCount: qr.itemCount,
      );
    }

    final bt = BluetoothQrPayload.tryDecode(unwrapped);
    if (bt != null) {
      return QRPayload(
        version: 2,
        ip: 'bt',
        port: 0,
        token: bt.token,
        sessionId: bt.publicId.isNotEmpty ? bt.publicId : bt.token,
        mode: bluetoothMode,
        fileName: bt.fileName,
        fileSize: bt.fileSize,
        itemCount: bt.itemCount,
        senderName: bt.senderName.isNotEmpty ? bt.senderName : null,
      );
    }

    try {
      final payload = QRPayload.decode(unwrapped);
      if (payload.version != 1 && payload.version != 2) {
        throw Exception(
            'Unsupported QR version: ${payload.version}. Expected 1 or 2.');
      }
      if (!payload.isValid) {
        throw Exception('Invalid payload fields');
      }
      return QRPayload(
        version: payload.version,
        ip: payload.ip,
        port: payload.port,
        token: payload.token,
        fileName: payload.fileName,
        fileSize: payload.fileSize,
        checksum: payload.checksum,
        sessionId: payload.sessionId,
        mode: payload.mode,
        sdpOffer: payload.sdpOffer,
        itemCount: payload.itemCount,
        // The whole reason the LAN transfer can be trusted — dropping it here
        // is what made every scan report the sender as "unencrypted".
        tlsFingerprint: payload.tlsFingerprint,
      );
    } catch (e) {
      throw ServerException('Invalid QR Code data: $e');
    }
  }
}

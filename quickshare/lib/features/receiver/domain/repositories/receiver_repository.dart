import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_receive_result.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_session_preview.dart';

abstract class ReceiverRepository {
  Future<Either<Failure, QRPayload>> parseQRCode(String rawData);
  Future<Either<Failure, bool>> checkServerAvailability(QRPayload payload);
  Future<Either<Failure, QhtpSessionPreview>> fetchQhtpSessionPreview(
      QRPayload payload);
  Future<Either<Failure, String>> downloadFile(QRPayload payload,
      {void Function(int received, int total)? onProgress});
  Future<Either<Failure, QhtpReceiveResult>> receiveQhtpSession(
    QRPayload payload,
    String targetDir, {
    void Function(QhtpProgress progress)? onProgress,
  });
  Future<Either<Failure, bool>> verifyChecksum(
      String filePath, String expectedChecksum);
  Future<Either<Failure, String>> saveToFinalLocation(
      String tempPath, String fileName);
  void cancelDownload();
}

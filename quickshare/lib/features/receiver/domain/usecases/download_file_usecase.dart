import 'dart:io';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';

class DownloadFileUseCase {
  final ReceiverRepository repository;

  DownloadFileUseCase(this.repository);

  Future<Either<Failure, String>> call(QRPayload payload,
      {void Function(int received, int total)? onProgress,
      void Function()? onVerifying}) async {
    final serverCheck = await repository.checkServerAvailability(
        payload.ip, payload.port, payload.token);
    if (serverCheck is Left) {
      return Left((serverCheck as Left<Failure, bool>).value);
    }

    final downloadResult =
        await repository.downloadFile(payload, onProgress: onProgress);
    if (downloadResult is Left) {
      return Left((downloadResult as Left<Failure, String>).value);
    }

    final tempPath = (downloadResult as Right<Failure, String>).value;

    if (onVerifying != null) onVerifying();

    final verifyResult =
        await repository.verifyChecksum(tempPath, payload.checksum);
    if (verifyResult is Left) {
      final tempFile = File(tempPath);
      if (await tempFile.exists()) await tempFile.delete();
      return Left((verifyResult as Left<Failure, bool>).value);
    }

    return repository.saveToFinalLocation(tempPath, payload.fileName);
  }
}

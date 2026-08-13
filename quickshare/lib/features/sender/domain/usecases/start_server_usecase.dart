import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';

class StartServerUseCase {
  final SenderRepository repository;

  StartServerUseCase(this.repository);

  Future<Either<Failure, TransferSession>> call(FileMetadata file) {
    return repository.startServer(file);
  }
}

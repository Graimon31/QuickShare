import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';

class StopServerUseCase {
  final SenderRepository repository;

  StopServerUseCase(this.repository);

  Future<Either<Failure, void>> call() {
    return repository.stopServer();
  }
}

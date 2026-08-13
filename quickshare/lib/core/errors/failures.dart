import 'package:equatable/equatable.dart';

abstract class Failure extends Equatable {
  final String message;

  const Failure(this.message);

  @override
  List<Object?> get props => [message];
}

class ServerFailure extends Failure {
  const ServerFailure(super.message);
}

class NetworkFailure extends Failure {
  const NetworkFailure(super.message);
}

class PermissionFailure extends Failure {
  const PermissionFailure(super.message);
}

class FileFailure extends Failure {
  const FileFailure(super.message);
}

class QRFailure extends Failure {
  const QRFailure(super.message);
}

class StorageFailure extends Failure {
  const StorageFailure(super.message);
}

class TimeoutFailure extends Failure {
  const TimeoutFailure(super.message);
}

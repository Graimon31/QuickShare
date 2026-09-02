import 'package:equatable/equatable.dart';

/// A stable tag for the handful of failures a screen needs to explain in the
/// user's own language rather than repeat as-is.
///
/// [Failure.message] stays raw and technical on purpose — it is what a log
/// line or `debugPrint` gets — and most failures carry no [Failure.code] at
/// all, because most call sites already hand [Failure.message] a sentence
/// the UI was written to show directly. A code exists only where the message
/// is instead a caught exception's own text (a `DioException`, a socket
/// error), which is not something to put in front of someone who does not
/// read English stack traces.
class FailureCode {
  FailureCode._();

  /// The sender's server stopped answering mid-session: the user cancelled,
  /// its app closed, its Wi-Fi dropped. A one-way HTTP pull has no channel to
  /// ask which one it was — they all look identical from here — and this
  /// name is true of every one of them.
  static const senderUnreachable = 'senderUnreachable';

  /// The sender explicitly said "cancelled" over a channel that can say
  /// that — the WebRTC data channel carries a real control message, unlike
  /// the QHTP pull [senderUnreachable] covers.
  static const cancelledBySender = 'cancelledBySender';
}

abstract class Failure extends Equatable {
  final String message;

  /// See [FailureCode]. Null means the UI should show [message] itself, as
  /// it always has.
  final String? code;

  const Failure(this.message, {this.code});

  @override
  List<Object?> get props => [message, code];
}

class ServerFailure extends Failure {
  const ServerFailure(super.message, {super.code});
}

class NetworkFailure extends Failure {
  const NetworkFailure(super.message, {super.code});
}

class PermissionFailure extends Failure {
  const PermissionFailure(super.message, {super.code});
}

class FileFailure extends Failure {
  const FileFailure(super.message, {super.code});
}

class QRFailure extends Failure {
  const QRFailure(super.message, {super.code});
}

class StorageFailure extends Failure {
  const StorageFailure(super.message, {super.code});
}

class TimeoutFailure extends Failure {
  const TimeoutFailure(super.message, {super.code});
}

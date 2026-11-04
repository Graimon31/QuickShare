class ServerException implements Exception {
  final String message;
  final String? code;
  const ServerException(this.message, [this.code]);
}

class NetworkException implements Exception {
  final String message;
  final String? code;
  const NetworkException(this.message, [this.code]);
}

class FileException implements Exception {
  final String message;
  final String? code;
  const FileException(this.message, [this.code]);
}

class PermissionException implements Exception {
  final String message;
  final String? code;
  const PermissionException(this.message, [this.code]);
}

/// The Bluetooth radio could not do what a sender needs of it, and why: make
/// this device visible, or put a frame on the air.
///
/// [code] is a `FailureCode`, so the screen can say it in the person's own
/// language; [message] is the English text for the log, and carries whatever
/// the platform itself said.
class BluetoothRadioException implements Exception {
  final String message;
  final String code;
  const BluetoothRadioException(this.message, this.code);

  @override
  String toString() => message;
}

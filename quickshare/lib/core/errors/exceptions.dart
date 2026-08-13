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

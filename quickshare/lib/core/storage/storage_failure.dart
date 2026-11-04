import 'dart:io';

import 'package:dio/dio.dart';

import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/storage/disk_space.dart';
import 'package:quickshare/core/storage/safe_path.dart';

/// What went wrong on the receiving disk, in the words the app has for it.
///
/// Every receive path hits the same handful of storage problems — a link in the
/// destination, a full disk, a path Windows cannot open, a transfer that will
/// not fit — and each used to surface as whatever the exception happened to
/// say. This is the one place that recognises them, so the QHTP client, the
/// WebRTC and Bluetooth receivers and the single-file downloader all hand the
/// screen the same [FailureCode] and the same English for the log.
class StorageProblem {
  const StorageProblem(this.message, this.code);

  /// English, for the log and the diagnostics block.
  final String message;

  /// A [FailureCode] the screen turns into the user's language.
  final String code;

  /// The same problem as an exception a transport can complete a future with:
  /// the receiver screen reads [FileException.code] to choose its sentence.
  FileException toException() => FileException(message, code);

  @override
  String toString() => 'StorageProblem($code: $message)';
}

/// The storage problem inside [error], or null when it is something else.
///
/// Looks through a [DioException], since a download that fills the disk
/// reports it as the exception that wraps the filesystem one.
StorageProblem? classifyStorageError(Object? error, {String? os}) {
  switch (error) {
    case UnsafePathException():
      return StorageProblem(error.message, FailureCode.unsafeDestination);
    case PathTooLongException():
      return StorageProblem(error.message, FailureCode.pathTooLong);
    case NotEnoughSpaceException():
      return StorageProblem(error.message, error.failureCode);
    case PathTakenException():
      return StorageProblem(
          'No free name could be found for ${error.path}',
          FailureCode.unsafeDestination);
    case FileException(:final code?) when code.isNotEmpty:
      return StorageProblem(error.message, code);
    case FileSystemException():
      if (isDiskFull(error, os: os)) {
        return StorageProblem(
            'The disk is full while writing ${error.path ?? 'a file'}: '
            '${error.osError?.message ?? error.message}',
            FailureCode.diskFull);
      }
      return null;
    case DioException(:final error):
      return error == null ? null : classifyStorageError(error, os: os);
    default:
      return null;
  }
}

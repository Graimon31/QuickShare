import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/storage/safe_path.dart';
import 'package:quickshare/core/storage/storage_failure.dart';

class HttpFileDownloader {
  final Dio dio;
  CancelToken _cancelToken = CancelToken();

  HttpFileDownloader({Dio? dioClient}) : dio = dioClient ?? Dio() {
    dio.options.connectTimeout = const Duration(seconds: 3);
    dio.options.receiveTimeout = const Duration(seconds: 0);
  }

  /// Downloads [url] to [savePath] and returns the path the file ended up at.
  ///
  /// `dio.download(url, savePath)` truncated whatever was at [savePath] —
  /// through a symbolic link if that is what was there — and left a
  /// half-written file under the final name when the connection broke. The
  /// bytes now go to a guarded `<savePath>.qs.partial` (created exclusively,
  /// never through a link) and are given their name only once whole, without
  /// replacing anything: a file already at [savePath] stays, and the download
  /// lands as `name (1).ext`. The returned path says which.
  Future<String> download({
    required String url,
    required String token,
    required String savePath,
    required String tlsFingerprint,
    void Function(int, int)? onProgress,
  }) async {
    if (tlsFingerprint.isEmpty) {
      // The sender's server is HTTPS-only. A QR with nothing to pin describes
      // a plaintext server that no longer exists.
      throw const NetworkException(
          'This code is from an older version that sends files unencrypted. '
          'Update the sending device.');
    }
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client =
            HttpClient(context: SecurityContext(withTrustedRoots: false));
        client.badCertificateCallback =
            (cert, host, port) => SessionTlsIdentity.matches(cert, tlsFingerprint);
        return client;
      },
    );

    // The folder the caller chose is the destination; everything below it is
    // checked.
    final base = p.dirname(savePath);
    final partialPath = '$savePath$kPartialSuffix';

    int attempts = 0;
    while (attempts < 3) {
      try {
        // Created fresh each attempt: empty, regular, and not a link.
        SafePath.openPartial(base, partialPath, truncate: true).closeSync();
        await dio.download(
          url,
          partialPath,
          options: Options(
            headers: {'Authorization': 'Bearer $token'},
          ),
          onReceiveProgress: onProgress,
          cancelToken: _cancelToken,
        );
        return SafePath.commitFile(base, partialPath, savePath);
      } on DioException catch (e) {
        final storage = classifyStorageError(e);
        if (storage != null) {
          _discard(partialPath);
          throw storage.toException();
        }
        if (e.response != null && e.response!.statusCode != null) {
          if (e.response!.statusCode! >= 400 && e.response!.statusCode! < 500) {
            _discard(partialPath);
            rethrow; // Don't retry client errors
          }
        }
        attempts++;
        if (attempts >= 3) {
          _discard(partialPath);
          throw NetworkException(
              'Download failed after 3 attempts: ${e.message}');
        }
        await Future.delayed(Duration(seconds: attempts));
      } catch (e) {
        _discard(partialPath);
        if (e is NetworkException) rethrow;
        final storage = classifyStorageError(e);
        if (storage != null) throw storage.toException();
        throw const ServerException(
            'Unknown error during download. Please try again.');
      }
    }
    _discard(partialPath);
    throw const NetworkException('Download failed');
  }

  /// Removes what a failed attempt left, link or file; never a link's target.
  void _discard(String partialPath) {
    try {
      if (FileSystemEntity.typeSync(partialPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        File(partialPath).deleteSync();
      }
    } catch (_) {}
  }

  void cancel() {
    _cancelToken.cancel();
    _cancelToken = CancelToken();
  }
}

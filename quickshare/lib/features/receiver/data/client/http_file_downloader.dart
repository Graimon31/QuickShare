import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';

class HttpFileDownloader {
  final Dio dio;
  CancelToken _cancelToken = CancelToken();

  HttpFileDownloader({Dio? dioClient}) : dio = dioClient ?? Dio() {
    dio.options.connectTimeout = const Duration(seconds: 3);
    dio.options.receiveTimeout = const Duration(seconds: 0);
  }

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

    int attempts = 0;
    while (attempts < 3) {
      try {
        await dio.download(
          url,
          savePath,
          options: Options(
            headers: {'Authorization': 'Bearer $token'},
          ),
          onReceiveProgress: onProgress,
          cancelToken: _cancelToken,
        );
        return savePath;
      } on DioException catch (e) {
        if (e.response != null && e.response!.statusCode != null) {
          if (e.response!.statusCode! >= 400 && e.response!.statusCode! < 500) {
            rethrow; // Don't retry client errors
          }
        }
        attempts++;
        if (attempts >= 3) {
          throw NetworkException(
              'Download failed after 3 attempts: ${e.message}');
        }
        await Future.delayed(Duration(seconds: attempts));
      } catch (e) {
        if (e is NetworkException) rethrow;
        throw const ServerException(
            'Unknown error during download. Please try again.');
      }
    }
    throw const NetworkException('Download failed');
  }

  void cancel() {
    _cancelToken.cancel();
    _cancelToken = CancelToken();
  }
}

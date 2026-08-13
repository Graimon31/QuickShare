import 'package:dio/dio.dart';
import 'package:quickshare/core/errors/exceptions.dart';

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
    void Function(int, int)? onProgress,
  }) async {
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
        throw ServerException(
            'Unknown error during download. Please try again.');
      }
    }
    throw NetworkException('Download failed');
  }

  void cancel() {
    _cancelToken.cancel();
    _cancelToken = CancelToken();
  }
}

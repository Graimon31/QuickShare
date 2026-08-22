import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:flutter/foundation.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_receive_result.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_session_preview.dart';
import 'package:quickshare/features/receiver/data/client/http_file_downloader.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/permissions/permission_service.dart';

class ReceiverRepositoryImpl implements ReceiverRepository {
  final HttpFileDownloader downloader;
  final QRPayloadDecoder decoder;
  final QhtpReceiverClient qhtpClient;
  final Dio dio;

  ReceiverRepositoryImpl({
    required this.downloader,
    required this.decoder,
    QhtpReceiverClient? qhtpClient,
    Dio? dioClient,
  })  : qhtpClient = qhtpClient ?? QhtpReceiverClient(),
        dio = dioClient ?? Dio();

  String sanitizeFileName(String fileName) {
    var name = p.basename(fileName);
    name = name.replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_').trim();
    if (name.isEmpty || name.replaceAll('.', '').isEmpty) {
      name = 'received_file';
    }
    return name;
  }

  String sanitizePath(String fileName, String baseDir) {
    final cleanName = sanitizeFileName(fileName);
    final resolvedPath = p.normalize(p.join(baseDir, cleanName));
    if (!p.isWithin(baseDir, resolvedPath) && resolvedPath != baseDir) {
      throw Exception('Path traversal detected');
    }
    return resolvedPath;
  }

  bool validatePrivateIp(String ip) {
    if (ip == 'localhost' || ip == '127.0.0.1') return true;
    final address = InternetAddress.tryParse(ip);
    if (address == null) return false;
    if (address.isLoopback) return true;
    if (address.isLinkLocal || address.isMulticast) return false;
    if (address.type == InternetAddressType.IPv4) {
      final bytes = address.rawAddress;
      if (bytes[0] == 10) return true;
      if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) return true;
      if (bytes[0] == 192 && bytes[1] == 168) return true;
      if (bytes[0] == 127) return true;
    }
    return true; // Allow local network IPs
  }

  @override
  Future<Either<Failure, QRPayload>> parseQRCode(String rawData) async {
    try {
      final payload = decoder.decode(rawData);
      return Right(payload);
    } catch (e) {
      debugPrint('Error details: $e');
      return const Left(FileFailure('Invalid QR Code'));
    }
  }

  @override
  Future<Either<Failure, bool>> checkServerAvailability(
      String ip, int port, String token) async {
    if (!validatePrivateIp(ip)) return const Left(NetworkFailure('Invalid IP'));
    try {
      final response = await dio.get(
        'http://$ip:$port/v2/health',
        options: Options(
          connectTimeout: const Duration(seconds: 3),
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      if (response.statusCode == 200) {
        return const Right(true);
      }
      return const Left(ServerFailure('Server not available'));
    } catch (e) {
      // Fallback check legacy /info route
      try {
        final legacyRes = await dio.get(
          'http://$ip:$port/info',
          options: Options(
            headers: {'Authorization': 'Bearer $token'},
            connectTimeout: const Duration(seconds: 3),
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          ),
        );
        if (legacyRes.statusCode == 200) return const Right(true);
      } catch (_) {}
      return const Left(NetworkFailure('Connection failed. Please check network.'));
    }
  }

  @override
  Future<Either<Failure, QhtpSessionPreview>> fetchQhtpSessionPreview(
      QRPayload payload) async {
    if (!validatePrivateIp(payload.ip)) {
      return const Left(NetworkFailure('Invalid IP'));
    }
    try {
      final response = await dio.get(
        'http://${payload.ip}:${payload.port}/v2/session',
        options: Options(
          headers: {'Authorization': 'Bearer ${payload.token}'},
          // First LAN hop on iOS can wait on the Local Network permission sheet.
          connectTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      if (response.statusCode != 200) {
        return Left(NetworkFailure(
            'Failed to fetch session preview (status ${response.statusCode})'));
      }
      final data = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      final map = data as Map<String, dynamic>;
      return Right(QhtpSessionPreview(
        itemCount: map['itemCount'] as int? ?? 0,
        totalBytes: map['totalBytes'] as int? ?? 0,
      ));
    } catch (e) {
      debugPrint('Error details: $e');
      return const Left(NetworkFailure('Failed to connect to sender.'));
    }
  }

  @override
  Future<Either<Failure, String>> downloadFile(
    QRPayload payload, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (payload.fileSize > AppConstants.maxFileSizeBytes) {
      return const Left(FileFailure(
          'File too large (max ${AppConstants.maxFileSizeBytes ~/ 1024 ~/ 1024 ~/ 1024} GB)'));
    }
    if (!validatePrivateIp(payload.ip)) {
      return const Left(NetworkFailure('Invalid IP'));
    }
    try {
      final tempDir = await getTemporaryDirectory();
      final tempPath = sanitizePath(payload.fileName, tempDir.path);
      final url = 'http://${payload.ip}:${payload.port}/download';

      final resultPath = await downloader.download(
        url: url,
        token: payload.token,
        savePath: tempPath,
        onProgress: onProgress,
      );
      return Right(resultPath);
    } catch (e) {
      debugPrint('Error details: $e');
      return const Left(NetworkFailure('Download failed. Please try again.'));
    }
  }

  @override
  Future<Either<Failure, QhtpReceiveResult>> receiveQhtpSession(
    QRPayload payload,
    String targetDir, {
    void Function(QhtpProgress progress)? onProgress,
  }) async {
    if (!validatePrivateIp(payload.ip)) {
      return const Left(NetworkFailure('Invalid IP'));
    }
    return qhtpClient.downloadSession(
      payload: payload,
      targetBaseDir: targetDir,
      onProgress: onProgress,
    );
  }

  @override
  Future<Either<Failure, bool>> verifyChecksum(
      String filePath, String expectedChecksum) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return const Left(FileFailure('File not found'));

      final stream = file.openRead();
      final hash = await sha256.bind(stream).first;
      final computed = 'sha256:${hash.toString()}';
      final expected = expectedChecksum.contains(':')
          ? expectedChecksum
          : 'sha256:$expectedChecksum';

      if (computed == expected) {
        return const Right(true);
      }
      return const Left(FileFailure('Checksum verification failed'));
    } catch (e) {
      debugPrint('Error details: $e');
      return const Left(FileFailure('Failed to verify checksum.'));
    }
  }

  @override
  Future<Either<Failure, String>> saveToFinalLocation(
      String tempPath, String fileName) async {
    try {
      if (Platform.isAndroid) {
        await sl<PermissionService>().requestStorage();
      }
      final downloadDir = await getDownloadsDirectory();
      final finalDir = Platform.isIOS
          ? (await getApplicationDocumentsDirectory()).path
          : downloadDir?.path ?? (await getTemporaryDirectory()).path;

      final safeName = sanitizeFileName(fileName);
      String destPath = p.join(finalDir, safeName);
      int counter = 1;
      while (await File(destPath).exists()) {
        final ext = p.extension(safeName);
        final base = p.basenameWithoutExtension(safeName);
        destPath = p.join(finalDir, '$base ($counter)$ext');
        counter++;
      }
      final finalPath = destPath;

      final tempFile = File(tempPath);
      await tempFile.copy(finalPath);
      await tempFile.delete();

      return Right(finalPath);
    } catch (e) {
      debugPrint('Error details: $e');
      return const Left(FileFailure('Failed to save file.'));
    }
  }

  @override
  void cancelDownload() {
    downloader.cancel();
    qhtpClient.cancel();
  }
}

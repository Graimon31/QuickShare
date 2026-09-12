import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/security/path_sanitizer.dart';
import 'package:flutter/foundation.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_receive_result.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_session_preview.dart';
import 'package:quickshare/features/receiver/data/client/http_file_downloader.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/client/isolated_qhtp_receiver.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';

class ReceiverRepositoryImpl implements ReceiverRepository {
  final HttpFileDownloader downloader;
  final QRPayloadDecoder decoder;
  final QhtpReceiverClient qhtpClient;
  final Dio dio;

  /// Runs the session in a worker isolate, so decrypting and writing do not
  /// share a thread with drawing the screen. Skipped when a caller supplied
  /// its own [qhtpClient] — a test with a stubbed transport means to watch
  /// that transport, not a copy of it in another isolate that cannot see the
  /// stub.
  final IsolatedQhtpReceiver? _worker;

  ReceiverRepositoryImpl({
    required this.downloader,
    required this.decoder,
    QhtpReceiverClient? qhtpClient,
    Dio? dioClient,
    bool inProcess = false,
  })  : qhtpClient = qhtpClient ?? QhtpReceiverClient(),
        _worker = (qhtpClient != null || inProcess)
            ? null
            : IsolatedQhtpReceiver(),
        dio = dioClient ?? Dio();

  String sanitizeFileName(String fileName) {
    return PathSanitizer.sanitizeSegment(p.basename(fileName),
        defaultName: 'received_file');
  }

  String sanitizePath(String fileName, String baseDir) {
    return PathSanitizer.resolveSafePath(fileName, baseDir,
        defaultName: 'received_file');
  }

  /// Whether [ip] names one machine this device could dial.
  ///
  /// Deliberately permissive: the address is only ever one this device was
  /// handed by a sender it already agreed to collect from — a scanned code, a
  /// typed code, or the return address of an invitation someone accepted — and
  /// the relay the internet mode uses is a public address by design. What is
  /// left to catch here is an address that names no single machine, so a
  /// multicast group and an unparseable string are the refusals.
  ///
  /// Link-local is explicitly allowed. Refusing it had the reasoning exactly
  /// backwards: 169.254/16 and fe80::/10 cannot be routed off the wire they
  /// arrived on, which makes them the most certainly-local addresses there
  /// are. Refusing them broke the case they most obviously covered — an iPhone
  /// on the end of a USB cable, where macOS and iOS both self-assign a 169.254
  /// address and every accepted invitation then died with "Invalid IP".
  bool validatePrivateIp(String ip) {
    if (ip == 'localhost') return true;
    final address = InternetAddress.tryParse(ip);
    if (address == null) return false;
    return !address.isMulticast;
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

  /// A Dio that trusts one server: the one whose certificate hashes to
  /// [fingerprint]. No CA, no hostname check — the QR is the trust anchor.
  Dio _pinnedDio(String fingerprint) {
    return Dio()
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client =
              HttpClient(context: SecurityContext(withTrustedRoots: false));
          client.badCertificateCallback =
              (cert, h, p) => SessionTlsIdentity.matches(cert, fingerprint);
          return client;
        },
      );
  }

  @override
  Future<Either<Failure, bool>> checkServerAvailability(QRPayload payload) async {
    final ip = payload.ip;
    final port = payload.port;
    if (!validatePrivateIp(ip)) return const Left(NetworkFailure('Invalid IP'));
    if (payload.tlsFingerprint.isEmpty) {
      return const Left(NetworkFailure(
          'This code is from an older version that sends files unencrypted. '
          'Update the sending device.'));
    }
    final pinned = _pinnedDio(payload.tlsFingerprint);
    try {
      final response = await pinned.get(
        'https://$ip:$port/v2/health',
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
        final legacyRes = await pinned.get(
          'https://$ip:$port/info',
          options: Options(
            headers: {'Authorization': 'Bearer ${payload.token}'},
            connectTimeout: const Duration(seconds: 3),
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          ),
        );
        if (legacyRes.statusCode == 200) return const Right(true);
      } catch (_) {}
      return const Left(
          NetworkFailure('Connection failed. Please check network.'));
    } finally {
      pinned.close();
    }
  }

  @override
  Future<Either<Failure, QhtpSessionPreview>> fetchQhtpSessionPreview(
      QRPayload payload) async {
    if (!validatePrivateIp(payload.ip)) {
      return const Left(NetworkFailure('Invalid IP'));
    }
    if (payload.tlsFingerprint.isEmpty) {
      return const Left(NetworkFailure(
          'This code is from an older version that sends files unencrypted. '
          'Update the sending device.'));
    }
    final pinned = _pinnedDio(payload.tlsFingerprint);
    try {
      final response = await pinned.get(
        'https://${payload.ip}:${payload.port}/v2/session',
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
    } finally {
      pinned.close();
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
      final url = 'https://${payload.ip}:${payload.port}/download';

      final resultPath = await downloader.download(
        url: url,
        token: payload.token,
        savePath: tempPath,
        tlsFingerprint: payload.tlsFingerprint,
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
    final worker = _worker;
    if (worker != null) {
      return worker.downloadSession(
        payload: payload,
        targetBaseDir: targetDir,
        onProgress: onProgress,
      );
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
      if (!await file.exists()) {
        return const Left(FileFailure('File not found'));
      }

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
      // The transfer cache, not shared storage. Where the file ends up is the
      // completion screen's decision — gallery, Downloads, or somewhere the
      // user picks — and it cannot make that decision about a file this
      // method has already written into Documents behind its back.
      //
      // No storage permission is requested here for the same reason: nothing
      // outside the app's own cache is being written yet.
      final finalDir = (await const TransferCache().sessionDirectory()).path;

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
    _worker?.cancel();
    qhtpClient.cancel();
  }
}

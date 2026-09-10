import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/qr/qr_payload_encoder.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class SenderRepositoryImpl implements SenderRepository {
  final LocalHttpServer localServer;
  final NetworkInfoService networkInfoService;
  final QRPayloadEncoder qrEncoder;
  final FileIndexer indexer;
  final ImagePicker imagePicker;

  final _statusController = StreamController<TransferStatus>.broadcast();

  SenderRepositoryImpl({
    required this.localServer,
    required this.networkInfoService,
    required this.qrEncoder,
    FileIndexer? indexer,
    ImagePicker? imagePicker,
  })  : indexer = indexer ?? FileIndexer(),
        imagePicker = imagePicker ?? ImagePicker();

  @override
  Stream<double> get transferProgress => localServer.transferProgress;

  @override
  InternetAddress? get lastQhtpClientAddress => localServer.lastClientAddress;

  @override
  String? get sessionTlsFingerprint => localServer.tlsFingerprint;

  @override
  Stream<TransferStatus> get statusStream => _statusController.stream;

  void dispose() {
    _statusController.close();
  }

  @override
  Future<Either<Failure, FileMetadata>> pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result != null && result.files.single.path != null) {
        final platformFile = result.files.single;
        final file = File(platformFile.path!);

        final metadata = FileMetadata(
          name: platformFile.name,
          path: file.path,
          size: await file.length(),
          mimeType: lookupMimeType(file.path) ?? 'application/octet-stream',
        );
        return Right(metadata);
      } else {
        return const Left(FileFailure('No file selected'));
      }
    } catch (e) {
      debugPrint('Error details: $e');
      return const Left(FileFailure('Failed to pick file. Please try again.'));
    }
  }

  @override
  Future<Either<Failure, FileMetadata>> pickMedia() async {
    try {
      final media = await imagePicker.pickMedia();
      if (media == null) {
        return const Left(FileFailure('No photo or video selected'));
      }

      final file = File(media.path);
      return Right(FileMetadata(
        name: media.name,
        path: file.path,
        size: await file.length(),
        mimeType: lookupMimeType(file.path) ?? 'application/octet-stream',
      ));
    } catch (e) {
      debugPrint('Error picking media: $e');
      return const Left(
        FileFailure('Failed to pick photo or video. Please try again.'),
      );
    }
  }

  @override
  Future<Either<Failure, TransferSession>> startServer(
      FileMetadata file) async {
    try {
      _statusController.add(TransferStatus.serving);

      final ip = await networkInfoService.getLocalIpAddress();
      if (ip == null) {
        return const Left(NetworkFailure('Could not determine local IP'));
      }

      final token = const Uuid().v4();
      final port = await localServer.start(
        file.path,
        file.name,
        file.mimeType,
        file.size,
        token,
      );

      final session = TransferSession(
        id: const Uuid().v4(),
        fileMetadata: file,
        serverPort: port,
        authToken: token,
        localIp: ip,
        startedAt: DateTime.now(),
        status: TransferStatus.serving,
      );

      return Right(session);
    } catch (e) {
      _statusController.add(TransferStatus.failed);
      debugPrint('Error details: $e');
      return const Left(
          ServerFailure('Failed to start server. Please try again.'));
    }
  }

  @override
  Future<Either<Failure, TransferSession>> startQhtpTransfer(
    List<String> paths, {
    String? authToken,
    void Function(int items, int bytes)? onIndexProgress,
    void Function(int itemCount, int totalBytes)? onIndexed,
    void Function(Object error)? onIndexFailed,
  }) async {
    try {
      _statusController.add(TransferStatus.serving);

      // Every step from here to the QR says how long it took. A session
      // that takes twenty seconds and a session that never starts at all
      // used to leave the same trace in the journal: none.
      final sw = Stopwatch()..start();

      // The address lookup is two syscalls behind a platform channel, and
      // nothing here can recover if the answer never comes — so it is not
      // allowed to be the thing that hangs the session forever.
      final ip = await networkInfoService
          .getLocalIpAddress()
          .timeout(const Duration(seconds: 6), onTimeout: () => null);
      AppLogger.info('Session start: local address in ${sw.elapsedMilliseconds}ms',
          tag: 'SENDER');
      if (ip == null) {
        return const Left(NetworkFailure('Could not determine local IP'));
      }

      final sessionId = const Uuid().v4();
      final token = authToken ?? const Uuid().v4();

      // Started, not awaited.
      //
      // The QR code is an address, a port, a token and a certificate. None
      // of those is in the selection, and waiting for the selection to be
      // described before showing them made the wait proportional to the
      // number of files rather than their size: a terabyte in four files
      // appeared at once, forty thousand small ones took as long as the disk
      // needed to `stat` every one of them. The walk runs behind the QR now
      // and everything that genuinely needs it — the manifest, the session
      // summary, the first byte of any file — waits on it inside the server.
      //
      // Nothing is hashed up front any more either. That was a separate
      // wrong: four worker isolates reading the entire selection off the
      // disk at the exact moment the transfer begins reading the same files
      // off the same disk. The digest now falls out of sending the file —
      // the server hashes each response as it streams it, so by the time the
      // receiver asks, having just finished downloading that item, the
      // answer is already there.
      final index = indexer.buildResult(
        sessionId: sessionId,
        paths: paths,
        includeChecksums: false,
        onProgress: onIndexProgress,
      );

      // Both a listener, so a walk that throws before the server's handlers
      // ask for it is not an unhandled asynchronous error, and the one
      // channel the caller learns the real numbers on.
      unawaited(index.then((result) {
        AppLogger.info(
            'Session start: indexed ${result.manifest.itemCount} item(s), '
            '${result.manifest.totalBytes} bytes, '
            '${sw.elapsedMilliseconds}ms after the selection was handed over',
            tag: 'SENDER');
        onIndexed?.call(
            result.manifest.itemCount, result.manifest.totalBytes);
      }, onError: (Object e) {
        AppLogger.warning('Session start: the selection could not be read: $e',
            tag: 'SENDER');
        onIndexFailed?.call(e);
      }));

      final port = await localServer.startQhtpSessionWhileIndexing(
        sessionId: sessionId,
        index: index,
        authToken: token,
      );
      AppLogger.info(
          'Session start: serving on :$port, ${sw.elapsedMilliseconds}ms since '
          'the selection was handed over',
          tag: 'SENDER');

      // The name comes from what the user picked, which is known without
      // walking anything. Only the count needs the walk, and only when the
      // selection is several things at once — where "N items" is what the
      // screen says anyway, and it says it as soon as N exists.
      final displayName = paths.length == 1
          ? p.basename(paths.first)
          : '${paths.length} items';

      final dummyMetadata = FileMetadata(
        name: displayName,
        path: paths.first,
        // Zero until the walk lands. The screen hides a size it does not
        // have rather than claiming one.
        size: 0,
        mimeType: 'application/octet-stream',
      );

      final session = TransferSession(
        id: sessionId,
        fileMetadata: dummyMetadata,
        serverPort: port,
        authToken: token,
        localIp: ip,
        startedAt: DateTime.now(),
        status: TransferStatus.serving,
        isQhtp: true,
        // Not known yet; [onIndexed] carries the real one.
        itemCount: 0,
      );

      return Right(session);
    } catch (e) {
      _statusController.add(TransferStatus.failed);
      debugPrint('Error starting QHTP transfer: $e');
      return Left(
          ServerFailure('Failed to start QHTP transfer: ${e.toString()}'));
    }
  }

  Future<String> _computeChecksumStream(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return 'sha256:$digest';
  }

  @override
  Future<Either<Failure, String>> generateQRPayload(TransferSession session,
      {String? hostOverride}) async {
    try {
      // The receiver pins the HTTPS connection to this. It is set the moment
      // the server binds, which every path here has already done.
      final fingerprint = localServer.tlsFingerprint;
      if (fingerprint == null || fingerprint.isEmpty) {
        return const Left(
            ServerFailure('The local server did not come up with a '
                'certificate — cannot make a safe QR code.'));
      }

      // Legacy single-file session path
      if (!session.isQhtp) {
        final file = File(session.fileMetadata.path);
        final checksum = await _computeChecksumStream(file);
        final qrData = qrEncoder.encode(
          ip: hostOverride ?? session.localIp,
          port: session.serverPort,
          token: session.authToken,
          fileName: session.fileMetadata.name,
          fileSize: session.fileMetadata.size,
          checksum: checksum,
          tlsFingerprint: fingerprint,
        );
        return Right(qrData);
      }

      // QHTP v2 QR locator — include display name + total size so the phone
      // can show "folder size" immediately after scan without waiting on LAN.
      final qrPayload = QRPayload(
        version: 2,
        ip: hostOverride ?? session.localIp,
        port: session.serverPort,
        token: session.authToken,
        sessionId: session.id,
        mode: 'http-lan',
        fileName: session.fileMetadata.name,
        fileSize: session.fileMetadata.size,
        itemCount: session.itemCount,
        tlsFingerprint: fingerprint,
      );

      return Right(qrPayload.encode());
    } catch (e) {
      debugPrint('Error details: $e');
      return const Left(ServerFailure('Failed to generate QR payload.'));
    }
  }

  @override
  Future<Either<Failure, void>> stopServer({bool force = false}) async {
    try {
      await localServer.stop(force: force);
      _statusController.add(TransferStatus.cancelled);
      return const Right(null);
    } catch (e) {
      debugPrint('Error details: $e');
      return const Left(ServerFailure('Failed to stop server.'));
    }
  }
}

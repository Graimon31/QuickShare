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
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/qr/qr_payload_encoder.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/core/network/auto_tunnel_service.dart';
import 'package:quickshare/core/utils/app_logger.dart';
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
        return Left(FileFailure('No file selected'));
      }
    } catch (e) {
      debugPrint('Error details: $e');
      return Left(FileFailure('Failed to pick file. Please try again.'));
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
        return Left(NetworkFailure('Could not determine local IP'));
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
      return Left(ServerFailure('Failed to start server. Please try again.'));
    }
  }

  @override
  Future<Either<Failure, TransferSession>> startQhtpTransfer(
      List<String> paths) async {
    try {
      _statusController.add(TransferStatus.serving);

      final ip = await networkInfoService.getLocalIpAddress();
      if (ip == null) {
        return Left(NetworkFailure('Could not determine local IP'));
      }

      final sessionId = const Uuid().v4();
      final token = const Uuid().v4();

      final indexResult = await indexer.buildResult(
        sessionId: sessionId,
        paths: paths,
      );

      final port = await localServer.startQhtpSession(
        manifest: indexResult.manifest,
        itemIdToAbsPathMap: indexResult.itemIdToAbsPathMap,
        authToken: token,
      );

      // Prefer the original folder/file basename so receivers can show a real
      // name instead of a generic "N items" / Documents label.
      String displayName;
      if (paths.length == 1) {
        displayName = p.basename(paths.first);
        if (displayName.isEmpty) {
          displayName = indexResult.manifest.itemCount == 1
              ? indexResult.manifest.items.first.path
              : '${indexResult.manifest.itemCount} items';
        }
      } else if (indexResult.manifest.itemCount == 1) {
        displayName = indexResult.manifest.items.first.path;
      } else {
        displayName = '${indexResult.manifest.itemCount} items';
      }

      final dummyMetadata = FileMetadata(
        name: displayName,
        path: paths.first,
        size: indexResult.manifest.totalBytes,
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
        itemCount: indexResult.manifest.itemCount,
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
  Future<Either<Failure, String>> generateQRPayload(
      TransferSession session) async {
    try {
      // Legacy single-file session path
      if (!session.isQhtp) {
        final file = File(session.fileMetadata.path);
        final checksum = await _computeChecksumStream(file);
        final qrData = qrEncoder.encode(
          ip: session.localIp,
          port: session.serverPort,
          token: session.authToken,
          fileName: session.fileMetadata.name,
          fileSize: session.fileMetadata.size,
          checksum: checksum,
        );
        return Right(qrData);
      }

      // QHTP v2 QR locator — include display name + total size so the phone
      // can show "folder size" immediately after scan without waiting on LAN.
      final qrPayload = QRPayload(
        version: 2,
        ip: session.localIp,
        port: session.serverPort,
        token: session.authToken,
        sessionId: session.id,
        mode: 'http-lan',
        fileName: session.fileMetadata.name,
        fileSize: session.fileMetadata.size,
        itemCount: session.itemCount,
      );

      return Right(qrPayload.encode());
    } catch (e) {
      debugPrint('Error details: $e');
      return Left(ServerFailure('Failed to generate QR payload.'));
    }
  }

  @override
  Future<Either<Failure, String>> generateServerlessQRPayload({
    required TransferSession session,
    required String sdpOffer,
  }) async {
    try {
      final autoTunnel = AutoTunnelService();
      final publicIp = await autoTunnel.getPublicIpAddress() ?? session.localIp;
      final upnpResult = await autoTunnel.checkServerlessReachability(localPort: session.serverPort);
      final effectiveIp = (upnpResult.success && upnpResult.publicIp != null)
          ? upnpResult.publicIp!
          : publicIp;
      final effectivePort = upnpResult.externalPort ?? session.serverPort;

      AppLogger.info(
        'Generating serverless QR Payload: IP=$effectiveIp, Port=$effectivePort, File=${session.fileMetadata.name}',
        tag: 'SENDER_REPO',
      );

      final qrPayload = QRPayload(
        version: 2,
        ip: effectiveIp,
        port: effectivePort,
        token: session.authToken,
        sessionId: session.id,
        mode: 'webrtc-sdp',
        sdpOffer: sdpOffer,
        fileName: session.fileMetadata.name,
        fileSize: session.fileMetadata.size,
        itemCount: session.itemCount,
      );
      return Right(qrPayload.encode());
    } catch (e, st) {
      AppLogger.error('Failed to generate serverless QR payload', error: e, stackTrace: st, tag: 'SENDER_REPO');
      return Left(ServerFailure('Failed to generate serverless QR payload: $e'));
    }
  }

  @override
  void setActiveWebRtcTransport(dynamic transport) {
    if (transport == null || transport is WebRtcTransferTransport) {
      localServer.activeWebRtcTransport = transport as WebRtcTransferTransport?;
    }
  }

  @override
  Future<Either<Failure, void>> stopServer() async {
    try {
      await localServer.stop();
      _statusController.add(TransferStatus.cancelled);
      return const Right(null);
    } catch (e) {
      debugPrint('Error details: $e');
      return Left(ServerFailure('Failed to stop server.'));
    }
  }
}

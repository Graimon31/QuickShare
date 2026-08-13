import 'dart:async';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/core/network/network_info_service.dart';

class HttpTransferTransport implements TransferTransport {
  final LocalHttpServer _localHttpServer;
  final NetworkInfoService _networkInfoService;

  final StreamController<TransferStatus> _statusController =
      StreamController<TransferStatus>.broadcast();

  HttpTransferTransport(this._localHttpServer, this._networkInfoService);

  @override
  Stream<double> get progressStream => _localHttpServer.transferProgress;

  @override
  Stream<TransferStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _statusController.add(TransferStatus.initial);
  }

  @override
  Future<String> startSharing(FileMetadata file, String token) async {
    try {
      _statusController.add(TransferStatus.connecting);

      final port = await _localHttpServer.start(
          file.path, file.name, file.mimeType, file.size, token);

      final String? ipAddress = await _networkInfoService.getLocalIpAddress();
      if (ipAddress == null) {
        throw Exception("Could not determine Wi-Fi IP address");
      }

      _statusController.add(TransferStatus.transferring);

      return "$ipAddress:$port";
    } catch (e) {
      _statusController.add(TransferStatus.failed);
      throw Exception("Failed to start HTTP sharing: $e");
    }
  }

  @override
  Future<void> stopSharing() async {
    try {
      await _localHttpServer.stop();
      _statusController
          .add(TransferStatus.cancelled); // Or completed if naturally finished
    } catch (e) {
      // Handle gracefully
    } finally {
      // Don't close streams here if they might be reused, but for a single transfer:
      // _statusController.close();
    }
  }
}

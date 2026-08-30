import 'package:equatable/equatable.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

enum DownloadStatus {
  idle,
  connecting,
  downloading,
  verifying,
  completed,
  failed,
  cancelled
}

class DownloadSession extends Equatable {
  final String id;
  final QRPayload payload;
  final String? localSavePath;
  final int downloadedBytes;
  final int totalBytes;
  final DownloadStatus status;
  final DateTime? startedAt;

  const DownloadSession({
    required this.id,
    required this.payload,
    this.localSavePath,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.status = DownloadStatus.idle,
    this.startedAt,
  });

  double get progressPercent =>
      totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;

  @override
  List<Object?> get props => [
        id,
        payload,
        localSavePath,
        downloadedBytes,
        totalBytes,
        status,
        startedAt,
      ];
}

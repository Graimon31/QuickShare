import 'package:equatable/equatable.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

enum TransferStatus {
  initial,
  idle,
  connecting,
  serving,
  transferring,
  completed,
  failed,
  cancelled,
  timedOut,
}

class TransferSession extends Equatable {
  final String id;
  final FileMetadata fileMetadata;
  final int serverPort;
  final String authToken;
  final String localIp;
  final DateTime startedAt;
  final TransferStatus status;
  final bool isQhtp;
  final int itemCount;

  const TransferSession({
    required this.id,
    required this.fileMetadata,
    required this.serverPort,
    required this.authToken,
    required this.localIp,
    required this.startedAt,
    this.status = TransferStatus.idle,
    this.isQhtp = false,
    this.itemCount = 0,
  });

  TransferSession copyWith({
    String? id,
    FileMetadata? fileMetadata,
    int? serverPort,
    String? authToken,
    String? localIp,
    DateTime? startedAt,
    TransferStatus? status,
    bool? isQhtp,
    int? itemCount,
  }) {
    return TransferSession(
      id: id ?? this.id,
      fileMetadata: fileMetadata ?? this.fileMetadata,
      serverPort: serverPort ?? this.serverPort,
      authToken: authToken ?? this.authToken,
      localIp: localIp ?? this.localIp,
      startedAt: startedAt ?? this.startedAt,
      status: status ?? this.status,
      isQhtp: isQhtp ?? this.isQhtp,
      itemCount: itemCount ?? this.itemCount,
    );
  }

  @override
  List<Object?> get props => [
        id,
        fileMetadata,
        serverPort,
        authToken,
        localIp,
        startedAt,
        status,
        isQhtp,
        itemCount,
      ];
}

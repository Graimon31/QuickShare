import 'dart:async';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';

/// Defines the types of transport available
enum TransportType { wifi, bluetooth, internet }

abstract class TransferTransport {
  /// Initialize the transport mechanism
  Future<void> initialize();

  /// Start sharing the file
  /// Returns payload string: IP/Port for Wi-Fi, WebRTC room link URL for Internet.
  /// Bluetooth does not use this call — see [BluetoothTransferTransport], whose
  /// UX is device discovery, not a shareable code.
  Future<String> startSharing(FileMetadata file, String token);

  /// Stop sharing the file and clean up resources
  Future<void> stopSharing();

  /// Stream of transfer progress (0.0 to 1.0)
  Stream<double> get progressStream;

  /// Stream of current transfer status
  Stream<TransferStatus> get statusStream;
}

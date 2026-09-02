import 'dart:io' show InternetAddress;

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';

abstract class SenderRepository {
  /// Picks a file from the device storage.
  Future<Either<Failure, FileMetadata>> pickFile();

  /// Picks an image or video from the device media library.
  Future<Either<Failure, FileMetadata>> pickMedia();

  /// Starts the local HTTP server to serve the given single file.
  Future<Either<Failure, TransferSession>> startServer(FileMetadata file);

  /// Starts a QHTP heavy transfer session for files and/or directories.
  ///
  /// [authToken] fixes the token the session will accept, for the callers that
  /// already told the far side what to present. The Bluetooth fast path is
  /// one: the receiver has only the Bluetooth session token, so a session
  /// minting its own would reject the very device it was started for.
  Future<Either<Failure, TransferSession>> startQhtpTransfer(
    List<String> paths, {
    String? authToken,
  });

  /// Generates the QR payload string for the given transfer session.
  /// [hostOverride] replaces the address written into the QR code.
  ///
  /// Needed on a local-only hotspot: the session's localIp comes from the
  /// Wi-Fi client interface, which is exactly the one that is not carrying
  /// this transfer.
  Future<Either<Failure, String>> generateQRPayload(TransferSession session,
      {String? hostOverride});

  /// Generates a serverless SDP-in-QR payload string for WebRTC transfers.
  /// [sdpOffer] is raw SDP text — the whole QR payload is compressed once by
  /// [QRPayload.encode], so pre-compressing the offer here only inflates it.

  /// Sets the active WebRTC transfer transport for direct HTTP SDP answer routing.

  /// Stops the local HTTP server.
  /// [force]: destroy an actively-streaming connection immediately instead
  /// of letting it finish — see [LocalHttpServer.stop]. Only the user's own
  /// explicit Cancel means this; every other caller wants the graceful
  /// default.
  Future<Either<Failure, void>> stopServer({bool force = false});

  /// The real address that just downloaded a byte of the active QHTP
  /// session — ground truth for which route actually carried it, as opposed
  /// to which one was merely offered. Null until something has connected.
  InternetAddress? get lastQhtpClientAddress;

  /// A stream of transfer progress values from 0.0 to 1.0.
  Stream<double> get transferProgress;

  /// A stream of current transfer statuses.
  Stream<TransferStatus> get statusStream;
}

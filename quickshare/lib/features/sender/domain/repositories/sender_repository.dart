import 'dart:io' show InternetAddress;

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
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
  /// [onIndexProgress] is called while the selection is being walked, with
  /// how many items and bytes have been seen so far. It exists so the screen
  /// can show that a slow folder is being read rather than a stuck one.
  ///
  /// Returns as soon as the server is listening, which is before the walk
  /// has finished. The session it hands back is therefore incomplete on
  /// purpose: `itemCount` is zero and `fileMetadata.size` is zero until
  /// [onIndexed] says otherwise. Everything the QR code needs — address,
  /// port, token, certificate — is real from the first moment, and the file
  /// list is not one of those things. Walking a selection costs one
  /// directory read after another and a `stat` per file, so waiting for it
  /// made the QR appear after a delay proportional to how many files there
  /// were rather than how large they were.
  ///
  /// [onIndexed] fires once with the real counts when the walk lands.
  /// [onIndexFailed] fires instead if it throws — an unreadable folder, a
  /// selection past the size or depth ceiling — and the session is then
  /// serving something that does not exist, so the caller must end it.
  Future<Either<Failure, TransferSession>> startQhtpTransfer(
    List<String> paths, {
    String? authToken,
    String? sessionPublicId,
    void Function(int items, int bytes)? onIndexProgress,
    void Function(int itemCount, int totalBytes)? onIndexed,
    void Function(Object error)? onIndexFailed,
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

  /// The running session's certificate fingerprint, or null when no session
  /// is serving.
  ///
  /// The QR carries this so a scanner can pin the connection; a transfer that
  /// hands its address over some other way — the Bluetooth rendezvous, which
  /// never shows a QR — needs the same value by the same reasoning, and has
  /// nowhere else to read it from.
  String? get sessionTlsFingerprint;

  /// A stream of transfer progress values from 0.0 to 1.0.
  Stream<double> get transferProgress;

  /// A stream of current transfer statuses.
  Stream<TransferStatus> get statusStream;

  /// Waits until the first client connects to the local server, or returns
  /// false if [timeout] expires first.
  Future<bool> waitForFirstClient({Duration timeout = const Duration(seconds: 10)});

  /// A stream of human-approval requests from receivers attempting LAN code entry.
  Stream<TransferApprovalRequest> get approvalRequests;

  /// Responds to a pending human-approval request.
  void respondToApproval(String requestId, bool accepted);
}

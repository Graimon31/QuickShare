import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:uuid/uuid.dart';

import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/data/repositories/sender_repository_impl.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive_io.dart';
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/rendezvous_channels.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/mime_compression.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

// Events
abstract class SenderEvent extends Equatable {
  const SenderEvent();
  @override
  List<Object?> get props => [];
}

class PickFile extends SenderEvent {}

class PickMedia extends SenderEvent {}

class StartSending extends SenderEvent {
  final FileMetadata file;
  const StartSending(this.file);
  @override
  List<Object?> get props => [file];
}

class SelectTransportMode extends SenderEvent {
  final TransportType mode;
  const SelectTransportMode(this.mode);
  @override
  List<Object?> get props => [mode];
}

class StartSendingWithTransport extends SenderEvent {
  final FileMetadata file;
  final TransportType mode;
  const StartSendingWithTransport(this.file, this.mode);
  @override
  List<Object?> get props => [file, mode];
}

class StartQhtpSend extends SenderEvent {
  final List<String> paths;
  final TransportType? mode;
  const StartQhtpSend(this.paths, {this.mode});
  @override
  List<Object?> get props => [paths, mode];
}

/// The user chose to build a local network instead of fighting the one they
/// are on. Raised from the network fallback screen.
class StartLocalNetwork extends SenderEvent {}

class CancelSending extends SenderEvent {}

class TransferCompleted extends SenderEvent {}

class TransferFailed extends SenderEvent {
  final String error;
  const TransferFailed(this.error);
  @override
  List<Object?> get props => [error];
}

class RelayBlocked extends SenderEvent {
  final int sessionBytes;
  final int limitBytes;
  const RelayBlocked(this.sessionBytes, this.limitBytes);
  @override
  List<Object?> get props => [sessionBytes, limitBytes];
}

class TransferProgressEvent extends SenderEvent {
  final double progress;
  const TransferProgressEvent(this.progress);
  @override
  List<Object?> get props => [progress];
}

// States
abstract class SenderState extends Equatable {
  const SenderState();
  @override
  List<Object?> get props => [];
}

class SenderInitial extends SenderState {}

class FileSelected extends SenderState {
  final FileMetadata file;
  const FileSelected(this.file);
  @override
  List<Object?> get props => [file];
}

class ServerStarting extends SenderState {}

class QRReady extends SenderState {
  final String qrData;
  final TransferSession session;
  final TransportType mode;
  final String? webLinkUrl;

  /// How many files this session carries, and how many bytes in total.
  ///
  /// [session] describes only the first one — it predates the manifest and
  /// still exists because the LAN path is built around a single
  /// [TransferSession]. Showing that alone made a multi-file send look like a
  /// single-file one, which read as "only one of my files is going".
  final int itemCount;
  final int totalBytes;

  const QRReady(
    this.qrData,
    this.session,
    this.mode, {
    this.webLinkUrl,
    this.itemCount = 1,
    this.totalBytes = 0,
  });

  @override
  List<Object?> get props =>
      [qrData, session, mode, webLinkUrl, itemCount, totalBytes];
}

/// Bluetooth is advertising and waiting for a receiver that scanned [qrData].
class BluetoothAdvertising extends SenderState {
  final TransferSession session;
  final String qrData;
  const BluetoothAdvertising(this.session, {required this.qrData});
  @override
  List<Object?> get props => [session, qrData];
}

class Transferring extends SenderState {
  final double progress;
  final int speedBps;
  const Transferring(this.progress, this.speedBps);
  @override
  List<Object?> get props => [progress, speedBps];
}

class TransferComplete extends SenderState {
  final FileMetadata file;
  const TransferComplete(this.file);
  @override
  List<Object?> get props => [file];
}

/// The connection came up, but only through a relay, and the session is too
/// large to push through somebody else's bandwidth. Nothing has been sent.
///
/// Distinct from [SenderError] because there is a concrete way out — put both
/// devices on one network — and the UI should offer it instead of an apology.
class RelayTooExpensive extends SenderState {
  final int sessionBytes;
  final int limitBytes;
  const RelayTooExpensive(this.sessionBytes, this.limitBytes);
  @override
  List<Object?> get props => [sessionBytes, limitBytes];
}

/// ICE finished without a single candidate a peer on another network could
/// use. Usually a VPN holding the default route, or a symmetric NAT.
class NoUsablePathFound extends SenderState {
  const NoUsablePathFound();
}

class HotspotStarting extends SenderState {
  const HotspotStarting();
}

/// A local-only hotspot is up and the transfer is being served on it.
///
/// Two codes, because they are two different things to two different readers:
/// [wifiQr] is the standard `WIFI:` payload any phone camera understands and
/// joins, and [transferQr] is the QHTP locator the app scans afterwards.
class LocalNetworkReady extends SenderState {
  final HotspotCredentials credentials;
  final String wifiQr;
  final String transferQr;
  final TransferSession session;

  const LocalNetworkReady({
    required this.credentials,
    required this.wifiQr,
    required this.transferQr,
    required this.session,
  });

  @override
  List<Object?> get props => [credentials.ssid, wifiQr, transferQr, session];
}

class SenderError extends SenderState {
  final String message;
  const SenderError(this.message);
  @override
  List<Object?> get props => [message];
}

// BLoC
/// Runs [writeTransferBundle] on an isolate of its own.
///
/// A plain `Isolate.run(() => ...)` written inside the bloc's own async
/// method does not work: a closure captures its whole enclosing context, and
/// inside an `async` body that context holds the completer driving it, which
/// is not sendable. The send fails at runtime with "object is unsendable",
/// the bundling is reported as a failed archive, and the transfer never
/// starts. Building the closure out here keeps two strings and a list of
/// strings as the only things it can capture.
Future<int> bundleForTransfer(List<String> paths, String zipPath) =>
    Isolate.run(() => writeTransferBundle(paths, zipPath));

/// Packs [paths] into a zip at [zipPath] and reports the finished size.
///
/// Top level and free of any reference to the bloc so it can be handed to
/// [Isolate.run]. That is the whole point: `ZipFileEncoder` deflates on
/// whichever isolate calls it, at roughly 55 MB/s here for the media that
/// does not compress at all. On the UI isolate a gigabyte of photos was
/// therefore about eighteen seconds with the interface completely frozen and
/// nothing moving on screen — which nobody reads as "slow", they read it as a
/// hung app, and that is exactly how it came back.
///
/// The awaits matter as much as the isolate. Every one of these returns a
/// future and none of them used to be awaited, so the central directory was
/// still being flushed while the caller was already measuring the file and
/// telling the receiver how many bytes to expect.
Future<int> writeTransferBundle(List<String> paths, String zipPath) async {
  final encoder = ZipFileEncoder();
  encoder.create(zipPath);
  for (final path in paths) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      await _addTree(encoder, Directory(path), p.basename(path));
    } else if (type == FileSystemEntityType.file) {
      await _addOne(encoder, File(path), p.basename(path));
    }
  }
  await encoder.close();
  return File(zipPath).lengthSync();
}

/// Walks [directory] itself rather than handing it to `addDirectory`, which
/// takes one compression level for a whole tree — and a tree of holiday
/// photos is exactly where that decision has to be made per file.
Future<void> _addTree(
    ZipFileEncoder encoder, Directory directory, String prefix) async {
  for (final entity in directory.listSync(followLinks: false)) {
    final name = '$prefix/${p.basename(entity.path)}';
    if (entity is Directory) {
      await _addTree(encoder, entity, name);
    } else if (entity is File) {
      await _addOne(encoder, entity, name);
    }
  }
}

/// Stores already-compressed files instead of deflating them again.
///
/// Deflate on a JPEG or an H.264 stream buys nothing — the format has done
/// the compressing already — and costs a full pass over every byte at about
/// 55 MB/s. Storing them is a straight copy, so a 600 MB selection of photos
/// stops being ten seconds of work and becomes as fast as the disk. It also
/// keeps the promise the whole app is built on: photos and videos are not
/// re-encoded on the way out, and a bundle that deflated them was quietly
/// breaking that even though zip is lossless.
Future<void> _addOne(
    ZipFileEncoder encoder, File file, String nameInArchive) async {
  final compressible = shouldCompressForTransfer(
    lookupMimeType(file.path),
    p.basename(file.path),
  );
  await encoder.addFile(
    file,
    nameInArchive,
    compressible ? ZipFileEncoder.GZIP : ZipFileEncoder.STORE,
  );
}

class SenderBloc extends Bloc<SenderEvent, SenderState> {
  final SenderRepository repository;
  StreamSubscription<double>? _progressSubscription;

  /// Progress of the direct-Wi-Fi route offered beside a Bluetooth session.
  ///
  /// Its own subscription because the Bluetooth branch has already claimed
  /// [_progressSubscription] for the radio. Both are live at once by design:
  /// only one of them will ever carry bytes, and which one is not known until
  /// the receiver decides.
  StreamSubscription<double>? _fastPathSubscription;
  StreamSubscription<TransferStatus>? _statusSubscription;

  FileMetadata? _currentFile;


  /// Every file this session will send.

  ///

  /// The wire protocol carries a manifest, so a session is a list even when

  /// it happens to hold one item. [_currentFile] stays alongside it because

  /// the QR and progress screens still show a single name and size.

  List<FileMetadata>? _sessionFiles;
  TransportType _selectedMode = TransportType.wifi;
  DateTime? _lastProgressUpdate;
  int _lastBytes = 0;

  WebRtcTransferTransport? _activeWebRtcTransport;
  BluetoothTransferTransport? _activeBluetoothTransport;
  StreamSubscription<RelayLimitExceeded>? _relayBlockedSubscription;

  final LocalHotspotService hotspot;

  /// Offers the running QHTP session over direct Wi-Fi as well as the LAN.
  final PeerLinkService peerLink;

  /// Facts about the last transfer, for the settings screen to show.
  final TransferDiagnostics _diagnostics = const TransferDiagnostics();
  DateTime? _sendStartedAt;
  bool _directLinkOffered = false;
  List<String>? _currentPaths;

  AnswerChannel? _answerChannel;
  StreamSubscription<Uint8List>? _answerSubscription;

  SenderBloc({
    required this.repository,
    LocalHotspotService? hotspotService,
    PeerLinkService? peerLinkService,
  })  : hotspot = hotspotService ?? LocalHotspotService(),
        peerLink = peerLinkService ?? const PeerLinkService(),
        super(SenderInitial()) {
    on<PickFile>(_onPickFile);
    on<PickMedia>(_onPickMedia);
    on<StartSending>(_onStartSending);
    on<SelectTransportMode>(_onSelectTransportMode);
    on<StartSendingWithTransport>(_onStartSendingWithTransport);
    on<StartQhtpSend>(_onStartQhtpSend);
    on<StartLocalNetwork>(_onStartLocalNetwork);
    on<CancelSending>(_onCancelSending);
    on<TransferCompleted>(_onTransferCompleted);
    on<TransferFailed>(_onTransferFailed);
    on<TransferProgressEvent>(_onTransferProgress);
    on<RelayBlocked>((event, emit) async {
      await _closeAnswerChannel();
      await _activeWebRtcTransport?.stopSharing();
      _activeWebRtcTransport = null;
      _subscribeToWifiProgress();
      emit(RelayTooExpensive(event.sessionBytes, event.limitBytes));
    });

    _progressSubscription = repository.transferProgress.listen((progress) {
      add(TransferProgressEvent(progress));
      if (progress >= 1.0) {
        add(TransferCompleted());
      }
    });

    _statusSubscription = repository.statusStream.listen((status) {
      if (status == TransferStatus.failed) {
        add(const TransferFailed('Transfer failed unexpectedly'));
      }
    });
  }

  Future<void> _closeAnswerChannel() async {
    await _answerSubscription?.cancel();
    _answerSubscription = null;
    await _relayBlockedSubscription?.cancel();
    _relayBlockedSubscription = null;
    await _answerChannel?.close();
    _answerChannel = null;
  }

  /// Builds the QR the desktop shows and starts listening for the answer.
  ///
  /// Subscription happens before the code appears, so the phone can never
  /// answer into a channel nobody is watching. Returns null if no public
  /// channel could be reached; the caller then fails the share outright rather
  /// than showing a code that leads nowhere.
  Future<String?> _prepareServerlessQr(String offerSdp) async {
    try {
      final qr = ServerlessQr(
        seed: SealedEnvelope.newSeed(),
        offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(offerSdp)),
      );
      final topic = await qr.topic;

      final channel = buildRendezvousChannel();
      await channel.subscribe(topic);
      _answerChannel = channel;

      _answerSubscription = channel.answers.listen((sealed) async {
        try {
          final opened = await SealedEnvelope.open(
            envelope: sealed,
            seed: qr.seed,
            offerFingerprint: qr.offerFingerprint,
          );
          final answer = CompactSdp.fromBytes(opened);
          AppLogger.info(
              'Sender: sealed answer opened, ${answer.candidates.length} '
              'candidates',
              tag: 'SENDER_BLOC');
          await _activeWebRtcTransport?.handleDirectAnswer(
              answer.toSdp(isOffer: false), 'answer');
        } catch (e) {
          // Public topics carry other people's traffic, and a payload sealed
          // for a different offer fails authentication by design.
          AppLogger.warning('Sender: discarded an answer payload: $e',
              tag: 'SENDER_BLOC');
        }
      });

      final encoded = qr.encode();
      AppLogger.info(
          'Sender: serverless QR ready, ${encoded.length} chars, '
          '${qr.offer.candidates.length} candidates, channel ${channel.name}',
          tag: 'SENDER_BLOC');
      return encoded;
    } catch (e, st) {
      AppLogger.error('Sender: could not prepare the serverless channel',
          error: e, stackTrace: st, tag: 'SENDER_BLOC');
      return null;
    }
  }

  TransferSession _makeDummySession(FileMetadata file) {
    return TransferSession(
      id: 'webrtc_session',
      fileMetadata: file,
      serverPort: 3000,
      authToken: 'webrtc_token',
      localIp: '0.0.0.0',
      startedAt: DateTime.now(),
      status: TransferStatus.serving,
    );
  }

  Future<void> _onPickFile(PickFile event, Emitter<SenderState> emit) async {
    final result = await repository.pickFile();
    result.fold(
      (failure) => emit(SenderError(failure.message)),
      (file) {
        _currentFile = file;
        emit(FileSelected(file));
      },
    );
  }

  Future<void> _onPickMedia(PickMedia event, Emitter<SenderState> emit) async {
    final result = await repository.pickMedia();
    result.fold(
      (failure) => emit(SenderError(failure.message)),
      (file) {
        _currentFile = file;
        emit(FileSelected(file));
      },
    );
  }

  Future<void> _onSelectTransportMode(
      SelectTransportMode event, Emitter<SenderState> emit) async {
    _selectedMode = event.mode;
  }

  Future<void> _onStartSending(
      StartSending event, Emitter<SenderState> emit) async {
    await _startSendingInternal(event.file, _selectedMode, emit);
  }

  Future<void> _onStartSendingWithTransport(
      StartSendingWithTransport event, Emitter<SenderState> emit) async {
    _selectedMode = event.mode;
    await _startSendingInternal(event.file, event.mode, emit);
  }

  void _subscribeToWifiProgress() {
    _progressSubscription?.cancel();
    _progressSubscription = repository.transferProgress.listen((progress) {
      add(TransferProgressEvent(progress));
      if (progress >= 1.0) {
        add(TransferCompleted());
      }
    });

    _statusSubscription?.cancel();
    _statusSubscription = repository.statusStream.listen((status) {
      if (status == TransferStatus.failed) {
        add(const TransferFailed('Transfer failed unexpectedly'));
      }
    });
  }

  Future<void> _startSendingInternal(
      FileMetadata file, TransportType mode, Emitter<SenderState> emit) async {
    emit(ServerStarting());

    if (mode == TransportType.internet) {
      try {
        _activeWebRtcTransport = WebRtcTransferTransport();
        await _activeWebRtcTransport!.initialize();

        _progressSubscription?.cancel();
        _progressSubscription =
            _activeWebRtcTransport!.progressStream.listen((progress) {
          add(TransferProgressEvent(progress));
        });

        _statusSubscription?.cancel();
        _statusSubscription =
            _activeWebRtcTransport!.statusStream.listen((status) {
          if (status == TransferStatus.failed) {
            add(const TransferFailed('Transfer failed unexpectedly'));
          } else if (status == TransferStatus.completed) {
            add(TransferCompleted());
          }
        });

        _relayBlockedSubscription?.cancel();
        _relayBlockedSubscription = _activeWebRtcTransport!.relayBlockedStream
            .listen((blocked) => add(
                RelayBlocked(blocked.sessionBytes, blocked.limitBytes)));

        await _activeWebRtcTransport!
            .startSharingServerless(file, files: _sessionFiles ?? [file]);

        final offerSdp = await _activeWebRtcTransport!.createLocalOfferSdp();
        if (offerSdp == null || offerSdp.isEmpty) {
          throw Exception('WebRTC produced no local offer to put in the QR');
        }

        final qrPayloadData = await _prepareServerlessQr(offerSdp);
        if (qrPayloadData == null) {
          // Better a clear failure than a QR code pointing at a rendezvous
          // nobody is listening on.
          throw Exception(
              'No public rendezvous channel could be reached. Check the '
              'internet connection and try again.');
        }

        final session = _sessionFiles ?? [file];
        emit(QRReady(
          qrPayloadData,
          _makeDummySession(file),
          mode,
          itemCount: session.length,
          totalBytes: session.fold<int>(0, (sum, f) => sum + f.size),
        ));
      } catch (e) {
        debugPrint('WebRTC init error: $e');
        await _closeAnswerChannel();
        await _activeWebRtcTransport?.stopSharing();
        _activeWebRtcTransport = null;
        _subscribeToWifiProgress();
        emit(SenderError('Failed to start internet transfer: $e'));
      }
      return;
    }

    if (mode == TransportType.bluetooth) {
      try {
        _activeBluetoothTransport = BluetoothTransferTransport();
        await _activeBluetoothTransport!.initialize();

        _progressSubscription?.cancel();
        _progressSubscription =
            _activeBluetoothTransport!.progressStream.listen((progress) {
          add(TransferProgressEvent(progress));
          if (progress >= 1.0) add(TransferCompleted());
        });

        _statusSubscription?.cancel();
        _statusSubscription =
            _activeBluetoothTransport!.statusStream.listen((status) {
          if (status == TransferStatus.failed) {
            add(const TransferFailed('Bluetooth transfer failed unexpectedly'));
          }
        });

        final token = const Uuid().v4();
        await _activeBluetoothTransport!.startSharing(file, token);
        await _offerBluetoothFastPath(token);
        emit(BluetoothAdvertising(
          _makeDummySession(file),
          qrData: BluetoothQrPayload(token: token).encode(),
        ));
      } catch (e) {
        debugPrint('Bluetooth init error: $e');
        await _activeBluetoothTransport?.stopSharing();
        _activeBluetoothTransport = null;
        _subscribeToWifiProgress();
        emit(SenderError('Failed to start Bluetooth sharing: $e'));
      }
      return;
    }

    _subscribeToWifiProgress();
    final result = await repository.startServer(file);

    await result.fold(
      (failure) async => emit(SenderError(failure.message)),
      (session) async {
        final qrResult = await repository.generateQRPayload(session);
        qrResult.fold(
          (failure) => emit(SenderError(failure.message)),
          (qrData) {
            emit(QRReady(qrData, session, mode));
          },
        );
      },
    );
  }

  Future<void> _onStartQhtpSend(
      StartQhtpSend event, Emitter<SenderState> emit) async {
    _currentPaths = event.paths;
    // A fresh session: forget the last one's timing and route.
    _sendStartedAt = null;
    _directLinkOffered = false;
    final mode = event.mode ?? _selectedMode;
    if (mode == TransportType.internet || mode == TransportType.bluetooth) {
      if (event.paths.isEmpty) {
        emit(const SenderError('No files or folders selected.'));
        return;
      }

      // Several plain files are never bundled. Both the DataChannel protocol
      // and QHTP carry a manifest, so a .zip buys nothing and costs plenty:
      // the recipient gets an archive to unpack instead of photos that land
      // in their gallery, and the sender waits while it is written.
      //
      // Zipping survives only for a *directory*, which is the one case a
      // single-file channel genuinely cannot express.
      //
      // Bluetooth included, which leaves a known gap: its native bridge
      // carries one file, so a multi-file selection reaches a receiver that
      // cannot take the direct Wi-Fi link as the first file only. That path
      // is the fallback of a fallback — a non-Apple device, in the same room,
      // with no network — and papering over it with an archive made every
      // ordinary multi-file send worse to fix a rare one.
      final allPlainFiles =
          event.paths.every((path) => FileSystemEntity.isFileSync(path));

      if (allPlainFiles && event.paths.length > 1) {
        final files = <FileMetadata>[];
        for (final path in event.paths) {
          files.add(FileMetadata(
            name: p.basename(path),
            path: path,
            size: await File(path).length(),
            mimeType: lookupMimeType(path) ?? 'application/octet-stream',
          ));
        }
        _sessionFiles = files;
        _currentFile = files.first;
        await _startSendingInternal(files.first, mode, emit);
        return;
      }

      final isSingleFile = event.paths.length == 1 &&
          FileSystemEntity.isFileSync(event.paths.first);

      FileMetadata targetMetadata;

      if (isSingleFile) {
        final filePath = event.paths.first;
        final file = File(filePath);
        final size = await file.length();
        final name = p.basename(filePath);

        targetMetadata = FileMetadata(
          name: name,
          path: filePath,
          // A real type, not a blanket octet-stream: it decides whether the
          // payload is compressed in flight and whether the far side files it
          // as a photo or as a document.
          mimeType: lookupMimeType(filePath) ?? 'application/octet-stream',
          size: size,
        );
      } else {
        emit(ServerStarting());
        String? zipPath;
        try {
          final tempDir = Directory.systemTemp;
          final String folderOrBundleName = event.paths.length == 1
              ? p.basename(event.paths.first)
              : 'quickshare_bundle';
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final zipName = '${folderOrBundleName}_$timestamp.zip';
          zipPath = p.join(tempDir.path, zipName);

          final zipSize =
              await bundleForTransfer(List<String>.from(event.paths), zipPath);

          targetMetadata = FileMetadata(
            name: zipName,
            path: zipPath,
            size: zipSize,
            mimeType: 'application/zip',
          );
        } catch (e) {
          if (zipPath != null) {
            try {
              final orphan = File(zipPath);
              if (await orphan.exists()) await orphan.delete();
            } catch (_) {}
          }
          emit(SenderError('Failed to archive folder for transfer: $e'));
          return;
        }
      }

      _currentFile = targetMetadata;
      // Both branches above end with exactly one thing to send, and this has
      // to be said for both: leaving the previous send's list in place made
      // the next transfer offer a manifest of files it was not sending.
      _sessionFiles = [targetMetadata];
      await _startSendingInternal(targetMetadata, mode, emit);
      return;
    }

    emit(ServerStarting());
    _subscribeToWifiProgress();
    final result = await repository.startQhtpTransfer(event.paths);
    await result.fold(
      (failure) async => emit(SenderError(failure.message)),
      (session) async {
        _currentFile = session.fileMetadata;
        await _offerOverDirectWiFi(session);
        final qrResult = await repository.generateQRPayload(session);
        qrResult.fold(
          (failure) => emit(SenderError(failure.message)),
          (qrData) {
            emit(QRReady(qrData, session, mode));
          },
        );
      },
    );
  }

  /// Serves the same selection over the direct Wi-Fi link while Bluetooth
  /// advertises.
  ///
  /// This is the shape AirDrop has: Bluetooth finds the device, Wi-Fi carries
  /// the file. It is not a workaround for a slow implementation — the whole
  /// Bluetooth standard tops out at 3 Mbit/s for Classic, which Apple does not
  /// expose to third-party apps at all, and 2 Mbit/s for BLE, which is what is
  /// left. 200 MB over that is twenty minutes at the theoretical best. No
  /// amount of tuning changes the radio.
  ///
  /// So the button keeps its name and its promise — find what is nearby, send
  /// without a network — and the bytes take the only path that can carry them
  /// at speed. If the link does not come up, the Bluetooth transfer that is
  /// already advertising carries them instead, slowly but surely.
  ///
  /// The QHTP session is built from the original paths rather than the bundle
  /// the Bluetooth path needs, so photos arrive as photos and land in the
  /// recipient's gallery instead of inside a .zip.
  Future<void> _offerBluetoothFastPath(String sessionToken) async {
    if (!PeerLinkService.isSupported) return;
    final paths = _currentPaths;
    if (paths == null || paths.isEmpty) return;

    // Nothing in here may escape. This is an optional faster route offered
    // beside a Bluetooth transfer that is already advertising and already
    // works; letting a failure out would mean the extra route took down the
    // one the user actually asked for. A bluetooth test caught exactly that.
    try {
      // The same token the Bluetooth session advertises. The receiver has no
      // other, so a session minting its own would answer 401 to the one
      // device it exists to serve — which is exactly what happened: the link
      // came up, the transfer failed, and the screen said "connection
      // failed" before falling back to Bluetooth on the retry.
      final result = await repository.startQhtpTransfer(
        paths,
        authToken: sessionToken,
      );
      await result.fold(
        (failure) async => AppLogger.info(
            'No fast path alongside Bluetooth: ${failure.message}',
            tag: 'PEERLINK'),
        (session) async {
          await peerLink.host(
            serviceName: PeerLinkService.serviceNameFor(sessionToken),
            localPort: session.serverPort,
          );
          // Without this the sender screen sits on its QR code while the
          // file goes out over the fast route and finishes — no progress, no
          // completion, nothing to say it worked. Functionally fine and
          // indistinguishable from a hung app, which is not a distinction
          // worth asking anyone to make.
          _directLinkOffered = true;
          _fastPathSubscription?.cancel();
          _fastPathSubscription =
              repository.transferProgress.listen((progress) {
            add(TransferProgressEvent(progress));
            if (progress >= 1.0) add(TransferCompleted());
          });

          AppLogger.info(
              'Bluetooth is advertising; the file is also on the direct '
              'Wi-Fi link at :${session.serverPort}',
              tag: 'PEERLINK');
        },
      );
    } catch (e) {
      AppLogger.info('No fast path alongside Bluetooth: $e', tag: 'PEERLINK');
    }
  }

  /// Also serves this session over a direct Wi-Fi link, where one is possible.
  ///
  /// Purely additive: the QHTP server is already listening and the QR already
  /// names the LAN address, so a receiver that cannot use the direct link is
  /// unaffected. What it buys is the pairing nothing else covers — an iPhone
  /// and a Mac with no network between them, which until now had only
  /// Bluetooth at 13 KB/s.
  ///
  /// Best effort by design. If the link will not come up, the transfer still
  /// works over whatever network there is, and saying so in the log is the
  /// right amount of noise for something nobody asked for.
  Future<void> _offerOverDirectWiFi(TransferSession session) async {
    if (!PeerLinkService.isSupported) return;
    try {
      await peerLink.host(
        serviceName: PeerLinkService.serviceNameFor(session.authToken),
        localPort: session.serverPort,
      );
    } on PeerLinkException catch (e) {
      AppLogger.info('No direct Wi-Fi link this time: $e', tag: 'PEERLINK');
    }
  }

  Future<void> _cleanupTempZipIfNeeded(FileMetadata? metadata) async {
    if (metadata != null && metadata.mimeType == 'application/zip') {
      try {
        final zipFile = File(metadata.path);
        if (await zipFile.exists()) {
          await zipFile.delete();
        }
      } catch (_) {}
    }
  }

  /// Builds a network of our own and serves the transfer over it.
  ///
  /// The internet attempt is torn down first — its peer connection and its
  /// rendezvous subscription are of no further use, and leaving the WebRTC
  /// transport registered would keep the unauthenticated answer route alive.
  ///
  /// The file server needs no special handling: it binds every interface, so
  /// once the hotspot exists it is already listening there. What has to wait is
  /// the address printed into the QR code, which appears a few hundred
  /// milliseconds after the hotspot callback fires.
  Future<void> _onStartLocalNetwork(
      StartLocalNetwork event, Emitter<SenderState> emit) async {
    final paths = _currentPaths ??
        (_currentFile != null ? [_currentFile!.path] : const <String>[]);
    if (paths.isEmpty) {
      emit(const SenderError('Nothing is selected to send.'));
      return;
    }

    emit(const HotspotStarting());

    await _closeAnswerChannel();
    await _activeWebRtcTransport?.stopSharing();
    _activeWebRtcTransport = null;
    _subscribeToWifiProgress();

    HotspotCredentials credentials;
    try {
      credentials = await hotspot.startHosting();
    } on HotspotException catch (e) {
      emit(SenderError('Could not create a network: $e'));
      return;
    }

    if (credentials.hostAddress == null) {
      await hotspot.stopHosting();
      emit(const SenderError(
          'The network came up but never got an address, so there is nothing '
          'to point the other device at.'));
      return;
    }

    final result = await repository.startQhtpTransfer(paths);
    await result.fold(
      (failure) async {
        await hotspot.stopHosting();
        emit(SenderError(failure.message));
      },
      (session) async {
        _currentFile = session.fileMetadata;
        final qrResult = await repository.generateQRPayload(
          session,
          hostOverride: credentials.hostAddress,
        );
        await qrResult.fold(
          (failure) async {
            await hotspot.stopHosting();
            emit(SenderError(failure.message));
          },
          (transferQr) async {
            AppLogger.info(
                'Serving over the local hotspot ${credentials.ssid} at '
                '${credentials.hostAddress}:${session.serverPort}',
                tag: 'SENDER_BLOC');
            emit(LocalNetworkReady(
              credentials: credentials,
              wifiQr: credentials.toWifiQrPayload(),
              transferQr: transferQr,
              session: session,
            ));
          },
        );
      },
    );
  }

  Future<void> _onCancelSending(
      CancelSending event, Emitter<SenderState> emit) async {
    await hotspot.stopHosting();
    await _cleanupTempZipIfNeeded(_currentFile);
    await repository.stopServer();
    await peerLink.stop();
    await _fastPathSubscription?.cancel();
    _fastPathSubscription = null;
    await _closeAnswerChannel();
    await _activeWebRtcTransport?.stopSharing();
    _activeWebRtcTransport = null;
    await _activeBluetoothTransport?.stopSharing();
    _activeBluetoothTransport = null;
    _subscribeToWifiProgress();
    _currentFile = null;
    emit(SenderInitial());
  }

  Future<void> _onTransferProgress(
      TransferProgressEvent event, Emitter<SenderState> emit) async {
    // The clock starts at the first byte that actually moves, not when the
    // user pressed send: waiting for somebody to scan a QR code is not
    // transfer time, and counting it turns a fast transfer into a slow-looking
    // number. Measured that way once today and it cost an hour of chasing.
    _sendStartedAt ??= DateTime.now();
    if (state is QRReady ||
        state is BluetoothAdvertising ||
        state is Transferring) {
      if (_currentFile == null) return;
      final totalBytes = _currentFile!.size;
      final currentBytes = (event.progress * totalBytes).round();
      final now = DateTime.now();

      int speedBps = 0;
      if (state is Transferring) {
        speedBps = (state as Transferring).speedBps;
      }

      if (_lastProgressUpdate != null) {
        final deltaSeconds =
            now.difference(_lastProgressUpdate!).inMilliseconds / 1000.0;
        if (deltaSeconds > 0.5) {
          final deltaBytes = currentBytes - _lastBytes;
          speedBps = (deltaBytes / deltaSeconds).round();
          _lastProgressUpdate = now;
          _lastBytes = currentBytes;
        }
      } else {
        _lastProgressUpdate = now;
        _lastBytes = currentBytes;
      }

      emit(Transferring(event.progress, speedBps));
    }
  }

  /// Files away what just happened, in terms that explain a slow transfer.
  ///
  /// The route is the fact that matters: a relayed internet session and a
  /// direct one look identical behind a progress ring and differ by an order
  /// of magnitude. Reading it off a log file on somebody else's machine is
  /// what this replaces.
  Future<void> _reportSend({String failure = ''}) async {
    final started = _sendStartedAt;
    if (started == null) return;
    _sendStartedAt = null;

    final ice = _activeWebRtcTransport?.lastIcePath;
    final route = switch (ice) {
      IcePathKind.relayed => 'Internet (relayed)',
      IcePathKind.peerToPeer => 'Internet (peer to peer)',
      IcePathKind.direct => 'Internet (direct, same network)',
      _ when _activeBluetoothTransport != null && !_directLinkOffered =>
        'Bluetooth',
      _ when _directLinkOffered => 'Direct Wi-Fi link',
      _ => 'Local network',
    };

    await _diagnostics.record(TransferReport(
      at: started,
      role: 'sent',
      route: route,
      bytes: (_sessionFiles ?? const []).fold<int>(0, (sum, f) => sum + f.size),
      took: DateTime.now().difference(started),
      failure: failure,
    ));
  }

  Future<void> _onTransferCompleted(
      TransferCompleted event, Emitter<SenderState> emit) async {
    await _reportSend();
    await repository.stopServer();
    await peerLink.stop();
    await _fastPathSubscription?.cancel();
    _fastPathSubscription = null;
    await _closeAnswerChannel();
    await _activeWebRtcTransport?.stopSharing();
    _activeWebRtcTransport = null;
    await _activeBluetoothTransport?.stopSharing();
    _activeBluetoothTransport = null;
    _subscribeToWifiProgress();
    final completedFile = _currentFile;
    if (completedFile != null) {
      emit(TransferComplete(completedFile));
      await _cleanupTempZipIfNeeded(completedFile);
    } else {
      emit(SenderInitial());
    }
  }

  Future<void> _onTransferFailed(
      TransferFailed event, Emitter<SenderState> emit) async {
    await _cleanupTempZipIfNeeded(_currentFile);
    await repository.stopServer();
    await peerLink.stop();
    await _fastPathSubscription?.cancel();
    _fastPathSubscription = null;
    await _closeAnswerChannel();
    await _activeWebRtcTransport?.stopSharing();
    _activeWebRtcTransport = null;
    await _activeBluetoothTransport?.stopSharing();
    _activeBluetoothTransport = null;
    _subscribeToWifiProgress();
    emit(SenderError(event.error));
  }

  @override
  Future<void> close() async {
    await _cleanupTempZipIfNeeded(_currentFile);
    _progressSubscription?.cancel();
    _statusSubscription?.cancel();
    await _closeAnswerChannel();
    await _activeWebRtcTransport?.stopSharing();
    _activeWebRtcTransport = null;
    await _activeBluetoothTransport?.stopSharing();
    _activeBluetoothTransport = null;
    await repository.stopServer();
    await peerLink.stop();
    await _fastPathSubscription?.cancel();
    _fastPathSubscription = null;
    if (repository is SenderRepositoryImpl) {
      (repository as SenderRepositoryImpl).dispose();
    }
    return super.close();
  }
}

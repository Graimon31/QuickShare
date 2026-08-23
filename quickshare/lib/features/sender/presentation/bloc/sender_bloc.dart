import 'dart:async';
import 'dart:io';
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
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/rendezvous_channels.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
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
class SenderBloc extends Bloc<SenderEvent, SenderState> {
  final SenderRepository repository;
  StreamSubscription<double>? _progressSubscription;
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
  List<String>? _currentPaths;

  AnswerChannel? _answerChannel;
  StreamSubscription<Uint8List>? _answerSubscription;

  SenderBloc({required this.repository, LocalHotspotService? hotspotService})
      : hotspot = hotspotService ?? LocalHotspotService(),
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
    final mode = event.mode ?? _selectedMode;
    if (mode == TransportType.internet || mode == TransportType.bluetooth) {
      if (event.paths.isEmpty) {
        emit(const SenderError('No files or folders selected.'));
        return;
      }

      // Several plain files no longer need bundling: the DataChannel protocol
      // carries a manifest now. Zipping is still the only way to preserve a
      // *directory* tree, and it would also defeat saving photos into the
      // recipient's gallery, so it is reserved for the case that needs it.
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
        _sessionFiles = [targetMetadata];
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

          final encoder = ZipFileEncoder();
          encoder.create(zipPath);

          for (final path in event.paths) {
            final type = FileSystemEntity.typeSync(path);
            if (type == FileSystemEntityType.directory) {
              encoder.addDirectory(Directory(path));
            } else if (type == FileSystemEntityType.file) {
              encoder.addFile(File(path));
            }
          }
          encoder.close();

          final zipFile = File(zipPath);
          final zipSize = await zipFile.length();

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

  Future<void> _onTransferCompleted(
      TransferCompleted event, Emitter<SenderState> emit) async {
    await repository.stopServer();
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
    if (repository is SenderRepositoryImpl) {
      (repository as SenderRepositoryImpl).dispose();
    }
    return super.close();
  }
}

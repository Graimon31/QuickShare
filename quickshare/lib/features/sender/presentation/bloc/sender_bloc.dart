import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:uuid/uuid.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/data/repositories/sender_repository_impl.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive_io.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/mqtt_answer_channel.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
import 'dart:typed_data';
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

class CancelSending extends SenderEvent {}

class TransferCompleted extends SenderEvent {}

class TransferFailed extends SenderEvent {
  final String error;
  const TransferFailed(this.error);
  @override
  List<Object?> get props => [error];
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

  const QRReady(this.qrData, this.session, this.mode, {this.webLinkUrl});

  @override
  List<Object?> get props => [qrData, session, mode, webLinkUrl];
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
  TransportType _selectedMode = TransportType.wifi;
  DateTime? _lastProgressUpdate;
  int _lastBytes = 0;

  WebRtcTransferTransport? _activeWebRtcTransport;
  BluetoothTransferTransport? _activeBluetoothTransport;

  AnswerChannel? _answerChannel;
  StreamSubscription<Uint8List>? _answerSubscription;

  SenderBloc({required this.repository}) : super(SenderInitial()) {
    on<PickFile>(_onPickFile);
    on<PickMedia>(_onPickMedia);
    on<StartSending>(_onStartSending);
    on<SelectTransportMode>(_onSelectTransportMode);
    on<StartSendingWithTransport>(_onStartSendingWithTransport);
    on<StartQhtpSend>(_onStartQhtpSend);
    on<CancelSending>(_onCancelSending);
    on<TransferCompleted>(_onTransferCompleted);
    on<TransferFailed>(_onTransferFailed);
    on<TransferProgressEvent>(_onTransferProgress);

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
    await _answerChannel?.close();
    _answerChannel = null;
  }

  /// Builds the QR the desktop shows and starts listening for the answer.
  ///
  /// Subscription happens before the code appears, so the phone can never
  /// answer into a channel nobody is watching. Returns null if no public
  /// channel could be reached, in which case the caller falls back to the
  /// signaling-server link.
  Future<String?> _prepareServerlessQr(String offerSdp) async {
    try {
      final qr = ServerlessQr(
        seed: SealedEnvelope.newSeed(),
        offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(offerSdp)),
      );
      final topic = await qr.topic;

      final channel = RacingAnswerChannel([MqttAnswerChannel()]);
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

        repository.setActiveWebRtcTransport(_activeWebRtcTransport);

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

        final webLink =
            await _activeWebRtcTransport!.startSharing(file, 'webrtc_token');

        final session = _makeDummySession(file);
        String qrPayloadData = webLink;

        final offerSdp = await _activeWebRtcTransport!.createLocalOfferSdp();
        if (offerSdp != null && offerSdp.isNotEmpty) {
          qrPayloadData = await _prepareServerlessQr(offerSdp) ?? webLink;
        }

        emit(QRReady(qrPayloadData, session, mode, webLinkUrl: webLink));
      } catch (e) {
        debugPrint('WebRTC init error: $e');
        await _activeWebRtcTransport?.stopSharing();
        _activeWebRtcTransport = null;
        _subscribeToWifiProgress();
        final errorMsg = e.toString().contains('Signaling') ||
                e.toString().contains('Cannot reach')
            ? 'Signaling server unreachable (${AppConstants.signalingServerUrl}). Specify a remote server using:\n--dart-define=QUICKSHARE_SIGNALING_URL=wss://your-server.com'
            : 'Failed to start internet transfer: $e';
        emit(SenderError(errorMsg));
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
    final mode = event.mode ?? _selectedMode;
    if (mode == TransportType.internet || mode == TransportType.bluetooth) {
      if (event.paths.isEmpty) {
        emit(const SenderError('No files or folders selected.'));
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
          size: size,
          mimeType: 'application/octet-stream',
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

  Future<void> _onCancelSending(
      CancelSending event, Emitter<SenderState> emit) async {
    await _cleanupTempZipIfNeeded(_currentFile);
    repository.setActiveWebRtcTransport(null);
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

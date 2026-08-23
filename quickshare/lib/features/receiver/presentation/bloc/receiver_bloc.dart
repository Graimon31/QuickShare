import 'dart:async';
import 'dart:io' show File, Platform;
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_session_preview.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart'
    show TransferCancelledBySender, WebRtcReceiveProgress, WebRtcReceiverTransport;
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/core/signaling/rendezvous_channels.dart';
import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/utils/transfer_speed.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';

abstract class ReceiverEvent extends Equatable {
  const ReceiverEvent();
  @override
  List<Object> get props => [];
}

class StartScanning extends ReceiverEvent {}

class QRCodeScanned extends ReceiverEvent {
  final String rawData;
  const QRCodeScanned(this.rawData);
  @override
  List<Object> get props => [rawData];
}

class StartDownload extends ReceiverEvent {
  final QRPayload? payload;

  const StartDownload({this.payload});

  @override
  List<Object> get props => [if (payload != null) payload!];
}

class StartVerifying extends ReceiverEvent {}

class CancelDownload extends ReceiverEvent {}

class DownloadProgressUpdate extends ReceiverEvent {
  final int received;
  final int total;
  final String fileName;
  const DownloadProgressUpdate(this.received, this.total, [this.fileName = '']);
  @override
  List<Object> get props => [received, total, fileName];
}

class DownloadCompleted extends ReceiverEvent {
  final String filePath;
  final String? fileName;

  const DownloadCompleted(this.filePath, {this.fileName});

  @override
  List<Object> get props => [filePath, if (fileName != null) fileName!];
}

class DownloadFailed extends ReceiverEvent {
  final String error;
  const DownloadFailed(this.error);
  @override
  List<Object> get props => [error];
}

abstract class ReceiverState extends Equatable {
  const ReceiverState();
  @override
  List<Object?> get props => [];
}

class ReceiverInitial extends ReceiverState {}

class Scanning extends ReceiverState {}

class QRParsed extends ReceiverState {
  final QRPayload payload;
  final QhtpSessionPreview? qhtpPreview;
  const QRParsed(this.payload, {this.qhtpPreview});
  @override
  List<Object?> get props => [payload, qhtpPreview];
}

class Connecting extends ReceiverState {}

class Downloading extends ReceiverState {
  final double progress;
  final int speedBps;
  final String fileName;
  const Downloading(this.progress, this.speedBps, this.fileName);
  @override
  List<Object> get props => [progress, speedBps, fileName];
}

class Verifying extends ReceiverState {}

class DownloadComplete extends ReceiverState {
  final String filePath;
  final String fileName;

  /// Everything that arrived, still sitting in the transfer cache.
  ///
  /// Empty for the transports that have not been moved onto the cache yet
  /// (QHTP, Bluetooth), which still write straight to their destination; the
  /// completion screen falls back to [filePath] in that case.
  final List<ReceivedItem> items;

  const DownloadComplete(this.filePath, this.fileName,
      {this.items = const []});

  @override
  List<Object> get props => [filePath, fileName, items];
}

class ReceiverError extends ReceiverState {
  final String message;
  final bool canRetry;
  const ReceiverError(this.message, {this.canRetry = true});
  @override
  List<Object> get props => [message, canRetry];
}

class ReceiverBloc extends Bloc<ReceiverEvent, ReceiverState> {
  final DownloadFileUseCase downloadFileUseCase;
  final ReceiverRepository repository;
  QRPayload? _currentPayload;
  /// Smooths the reported speed.
  ///
  /// Progress arrives once per 16 KB chunk, so measuring between consecutive
  /// events divides by a sub-millisecond gap and produces readings that swing
  /// between zero and tens of MB/s on a link running at a steady rate.
  final _speedMeter = TransferSpeed();

  /// Highest fraction shown so far this session.
  ///
  /// A progress ring that ticks backwards reads as data being lost. The
  /// underlying counters only ever grow, so anything lower than what was
  /// already displayed is noise, not news.
  double _progressFloor = 0;
  int _transferAttempt = 0;

  ReceiverBloc({required this.downloadFileUseCase, required this.repository})
      : super(ReceiverInitial()) {
    on<StartScanning>((event, emit) => emit(Scanning()));

    on<QRCodeScanned>((event, emit) async {
      final result = await repository.parseQRCode(event.rawData);
      await result.fold(
        (failure) async => emit(const ReceiverError(
            'Invalid QR Code. Point the camera at the QR on the sender screen — not at the Wi‑Fi address text under it.')),
        (payload) async {
          _currentPayload = payload;
          if (!payload.isQhtp) {
            emit(QRParsed(payload));
            return;
          }
          // Emit IMMEDIATELY with size/name from the QR payload.
          // Never block navigation on LAN /v2/session — that used to freeze
          // the scanner for up to ~20s (or forever on some networks), which
          // looked like "scan does nothing".
          final embeddedPreview =
              (payload.fileSize > 0 || payload.itemCount > 0)
                  ? QhtpSessionPreview(
                      itemCount: payload.itemCount > 0
                          ? payload.itemCount
                          : 0,
                      totalBytes: payload.fileSize,
                    )
                  : null;
          emit(QRParsed(payload, qhtpPreview: embeddedPreview));
        },
      );
    });

    on<StartDownload>((event, emit) async {
      final payload = event.payload ?? _currentPayload;
      if (payload == null) {
        emit(const ReceiverError(
            'Transfer session is missing. Scan the QR code again.'));
        return;
      }
      _currentPayload = payload;
      final transferAttempt = ++_transferAttempt;
      emit(Connecting());
      _speedMeter.reset();
      _progressFloor = 0;
      if (payload.mode == QRPayloadDecoder.serverlessMode &&
          payload.sdpOffer != null) {
        await _runServerlessTransfer(payload, emit);
        return;
      }

      if (payload.isQhtp) {
        // iOS has no writable ~/Downloads directory inside the sandbox. The
        // old fallback returned that path and QHTP then failed while trying
        // to create it (Operation not permitted). Documents is writable and
        // is also the directory used by the repository's final save step.
        final targetDir = Platform.isIOS
            ? (await getApplicationDocumentsDirectory()).path
            : (await getDownloadsDirectory())?.path ??
                (await getTemporaryDirectory()).path;
        if (transferAttempt != _transferAttempt) return;

        final result = await repository.receiveQhtpSession(
          payload,
          targetDir,
          onProgress: (QhtpProgress qp) {
            if (transferAttempt != _transferAttempt) return;
            if (qp.phase == 'verifying') {
              add(StartVerifying());
            } else if (qp.phase == 'transferring') {
              add(DownloadProgressUpdate(
                  qp.sessionReceived, qp.sessionTotal, qp.itemPath));
            }
          },
        );

        if (transferAttempt != _transferAttempt) return;
        result.fold(
          (failure) => add(DownloadFailed(failure.message)),
          (result) => add(DownloadCompleted(
            result.preferredResultPath,
            fileName: result.displayName,
          )),
        );
        return;
      }

      final result = await downloadFileUseCase.call(
        payload,
        onProgress: (received, total) {
          if (transferAttempt != _transferAttempt) return;
          add(DownloadProgressUpdate(received, total));
        },
        onVerifying: () {
          if (transferAttempt != _transferAttempt) return;
          add(StartVerifying());
        },
      );

      if (transferAttempt != _transferAttempt) return;
      result.fold(
        (failure) => add(DownloadFailed(failure.message)),
        (path) => add(DownloadCompleted(path)),
      );
    });

    on<DownloadProgressUpdate>((event, emit) {
      if (_currentPayload == null) return;

      final measured = _speedMeter.update(event.received);

      final raw = event.total > 0 ? event.received / event.total : 0.0;
      final progress = raw > _progressFloor ? raw : _progressFloor;
      _progressFloor = progress;

      final name = event.fileName.isNotEmpty
          ? event.fileName
          : _currentPayload!.fileName;
      emit(Downloading(progress, (measured ?? 0).round(), name));
    });

    on<StartVerifying>((event, emit) {
      emit(Verifying());
    });

    on<DownloadCompleted>((event, emit) {
      final payload = _currentPayload;
      if (payload == null) return;
      final name = event.fileName ??
          (payload.isQhtp ? 'Received files' : payload.fileName);
      emit(DownloadComplete(event.filePath, name));
    });

    on<DownloadFailed>((event, emit) {
      emit(ReceiverError(event.error));
    });

    on<CancelDownload>((event, emit) {
      _transferAttempt++;
      repository.cancelDownload();
      _currentPayload = null;
      emit(ReceiverInitial());
    });
  }

  /// Serverless path: the QR carries a compact offer and a seed. We answer it,
  /// seal the answer under a key derived from that seed, and drop it on a
  /// public channel the sender is already listening to. Nothing we operate is
  /// involved, and the channel operator only ever sees opaque bytes.
  Future<void> _runServerlessTransfer(
      QRPayload payload, Emitter<ReceiverState> emit) async {
    final channel = buildRendezvousChannel();
    StreamSubscription<WebRtcReceiveProgress>? progressSub;
    try {
      final qr = ServerlessQr.decode(payload.sdpOffer!);
      final topic = await qr.topic;
      final transport = WebRtcReceiverTransport();

      // Without this the screen sat on "Connecting" for the whole transfer:
      // the transport reported progress and nobody was listening.
      progressSub = transport.progressStream.listen((p) {
        if (p.phase == 'transferring') {
          add(DownloadProgressUpdate(p.received, p.total, p.fileName));
        }
      });

      AppLogger.info(
          'Receiver: serverless offer with ${qr.offer.candidates.length} '
          'candidates, answering on topic $topic',
          tag: 'WEBRTC_RECEIVER');

      // Everything lands in the transfer cache first, on every platform.
      // Where it goes afterwards is the completion screen's decision, and on
      // a phone that decision belongs to the user.
      final cacheDir = await const TransferCache().directory();

      final savedPath = await transport.receiveWithSdpOffer(
        qr.offer.toSdp(isOffer: true),
        targetDir: cacheDir.path,
        deliverAnswer: (answerSdp) async {
          final sealed = await SealedEnvelope.seal(
            plaintext: ServerlessQr.trimForQr(CompactSdp.fromSdp(answerSdp))
                .toBytes(),
            seed: qr.seed,
            offerFingerprint: qr.offerFingerprint,
          );
          await channel.publish(topic, sealed);
        },
      );
      final items = [
        for (final path in transport.receivedPaths)
          ReceivedItem.fromCacheFile(
            File(path),
            lookupMimeType(path) ?? 'application/octet-stream',
          ),
      ];
      emit(DownloadComplete(
        savedPath,
        items.length == 1 ? items.first.name : payload.fileName,
        items: items,
      ));
    } catch (e, st) {
      // A cancellation is not a fault, and calling it one sends the user
      // looking for a network problem that never existed. A genuine
      // connection failure still reads as one.
      if (e is TransferCancelledBySender) {
        AppLogger.info('Sender cancelled the transfer', tag: 'WEBRTC_RECEIVER');
        emit(const ReceiverError('The sender cancelled the transfer',
            canRetry: false));
      } else {
        AppLogger.error('Serverless transfer failed',
            error: e, stackTrace: st, tag: 'WEBRTC_RECEIVER');
        emit(ReceiverError('Serverless transfer failed: $e'));
      }
    } finally {
      await progressSub?.cancel();
      await channel.close();
    }
  }
}

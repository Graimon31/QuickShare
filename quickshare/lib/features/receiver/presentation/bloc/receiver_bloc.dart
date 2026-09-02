import 'dart:async';
import 'dart:io'
    show
        Directory,
        File,
        FileSystemEntity,
        FileSystemException,
        HttpClient,
        SecurityContext;
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_session_preview.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart'
    show
        TransferCancelledBySender,
        WebRtcReceiveProgress,
        WebRtcReceiverTransport;
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/core/transfer/interruption_guard.dart';
import 'package:quickshare/core/signaling/rendezvous_channels.dart';
import 'package:quickshare/core/storage/receive_destination.dart';
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

  /// True when the payload was pasted or opened as a link, not read by camera.
  /// The error copy has to say so: telling a desktop user to point the
  /// camera at the QR is how a failed paste currently reads as a hang.
  final bool fromPaste;

  const QRCodeScanned(this.rawData, {this.fromPaste = false});
  @override
  List<Object> get props => [rawData, fromPaste];
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

  /// What arrived, for the completion screen to place. Empty only for a
  /// transport that has nothing to hand over.
  final List<ReceivedItem> items;

  /// True when [items] are already at their final home (desktop direct-write)
  /// and the completion screen only reports them, rather than copying them out
  /// of the transfer cache.
  final bool placed;

  const DownloadCompleted(this.filePath,
      {this.fileName, this.items = const [], this.placed = false});

  @override
  List<Object> get props =>
      [filePath, if (fileName != null) fileName!, items, placed];
}

class DownloadFailed extends ReceiverEvent {
  final String error;

  /// See [FailureCode] — carried through from the [Failure] that caused
  /// this, so [ReceiverError] can show a translated sentence instead of
  /// [error] itself.
  final String? code;

  const DownloadFailed(this.error, {this.code});
  @override
  List<Object> get props => [error, if (code != null) code!];
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

  /// Everything that arrived. Empty only if the session left nothing behind,
  /// in which case the screen falls back to [filePath].
  final List<ReceivedItem> items;

  /// True when [items] are already at their final home and the completion
  /// screen only reports them — the desktop direct-write path. False when they
  /// are in the transfer cache and still have to be placed (every phone
  /// transfer, and desktop Wi-Fi/Bluetooth for now).
  final bool placed;

  const DownloadComplete(this.filePath, this.fileName,
      {this.items = const [], this.placed = false});

  @override
  List<Object> get props => [filePath, fileName, items, placed];
}

class ReceiverError extends ReceiverState {
  final String message;
  final bool canRetry;

  /// See [FailureCode]. Null means the screen shows [message] itself, as it
  /// always has; set, it names a sentence the screen translates instead.
  final String? code;

  const ReceiverError(this.message, {this.canRetry = true, this.code});
  @override
  List<Object?> get props => [message, canRetry, code];
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

  /// The direct Wi-Fi link to the sender, when this pairing supports one.
  final PeerLinkService _peerLink = const PeerLinkService();
  bool _directLinkOpen = false;

  /// Holds the transfer's place while the user is looking at something else.
  final TransferInterruptionGuard _interruption;

  /// Facts about the last transfer, so "why was that slow?" has an answer on
  /// screen rather than in a log file on somebody else's machine.
  final TransferDiagnostics _diagnostics = const TransferDiagnostics();
  DateTime? _startedAt;
  String _route = '';

  /// `host:port` this device actually opened the QHTP connection to —
  /// loopback when the direct link took it, the sender's LAN address from
  /// the QR otherwise. [_route]'s label is read off this; this is the
  /// address itself, for anyone who wants to check the label's homework.
  String? _connectedTo;

  ReceiverBloc({
    required this.downloadFileUseCase,
    required this.repository,
    TransferInterruptionGuard? interruptionGuard,
  })  : _interruption = interruptionGuard ?? TransferInterruptionGuard(),
        super(ReceiverInitial()) {
    on<StartScanning>((event, emit) => emit(Scanning()));

    on<QRCodeScanned>((event, emit) async {
      // A second failed paste would otherwise emit the same ReceiverError
      // the bloc already holds, which Equatable swallows — the desktop
      // Receive button stays disabled and the window looks frozen.
      if (state is ReceiverError) {
        emit(ReceiverInitial());
      }
      final result = await repository.parseQRCode(event.rawData);
      await result.fold(
        (failure) async => emit(ReceiverError(
          event.fromPaste
              ? 'That is not a DirectDrop share link. Copy the link under the QR on the sender — not the Wi-Fi address.'
              : 'Invalid QR Code. Point the camera at the QR on the sender screen — not at the Wi‑Fi address text under it.',
        )),
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
                      itemCount: payload.itemCount > 0 ? payload.itemCount : 0,
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
        // Watched from here rather than from the constructor: building a bloc
        // should not require a widget binding, and a receiver that never
        // starts a transfer has no foreground to lose.
        _interruption.attach();
        _interruption.reset();
        // Where the bytes land is [ReceiveDestination]'s decision, the same
        // one the serverless path already asks it to make.
        //
        // On a phone that is still the transfer cache, in a directory of its
        // own: writing straight into Documents there meant a photo received
        // over the local network never reached the photo library and a
        // document was never asked about — the placement rule simply did not
        // run. On desktop there is a real folder to write into, and staging
        // in the cache first bought nothing: every byte was then copied a
        // second time into Downloads while the screen said "saving", which
        // for a gigabyte over an external disk is most of a minute of
        // waiting for work that did not have to happen at all.
        final dest = await ReceiveDestination.resolve();
        if (transferAttempt != _transferAttempt) {
          await dest.release();
          return;
        }

        // Prefer a direct Wi-Fi link to the sender when one can be had. The
        // QHTP session is the same either way — only the address changes.
        _startedAt = DateTime.now();
        final route = await _directRouteOrGiven(payload);
        _route = _directLinkOpen ? 'Direct Wi-Fi link' : 'Local network';
        _connectedTo = '${route.ip}:${route.port}';
        if (transferAttempt != _transferAttempt) return;

        void report(QhtpProgress qp) {
          if (transferAttempt != _transferAttempt) return;
          if (qp.phase == 'verifying') {
            // Checking each file as it lands is ordinary work inside a
            // session, not a phase of its own. Taking the whole screen for it
            // once per file made a ten-file folder look like ten separate
            // transfers: the bar filled to 10%, the screen flipped to
            // "verifying", the bar reappeared at 20%, and so on. The session
            // bar stays up instead; only the last item's check — or the only
            // item's — is a phase worth showing.
            if (qp.itemCount <= 1 || qp.itemIndex >= qp.itemCount) {
              add(StartVerifying());
            }
          } else if (qp.phase == 'transferring') {
            // No per-item name: the screen shows one session and its bar, so
            // the label stays the session's — the folder's name, or whatever
            // the QR carried for a loose selection — never the deep relative
            // path of whichever file is on the wire this instant.
            add(DownloadProgressUpdate(qp.sessionReceived, qp.sessionTotal));
          }
        }

        var result = await repository.receiveQhtpSession(
          route,
          dest.path,
          onProgress: report,
        );

        // A failure that lands while the app was in the background is almost
        // never the network: iOS suspends the process and the open socket dies
        // with it. QHTP keeps its partial files and resumes by byte offset, so
        // the only real question is whether the user still wants this — and
        // that is answered by whether they come back.
        while (result.isLeft && _interruption.wasInterrupted) {
          if (transferAttempt != _transferAttempt) {
            await dest.release();
            return;
          }
          emit(Connecting());
          if (await _interruption.awaitVerdict() == ResumeVerdict.giveUp) {
            add(const DownloadFailed(
                'The transfer stopped while the app was in the background. '
                'Start it again to finish.'));
            await _closeDirectLink();
            await dest.release();
            return;
          }
          if (transferAttempt != _transferAttempt) {
            await dest.release();
            return;
          }
          AppLogger.info('Resuming the transfer where it stopped',
              tag: 'TRANSFER');
          _interruption.reset();
          result = await repository.receiveQhtpSession(
            await _directRouteOrGiven(payload),
            dest.path,
            onProgress: report,
          );
        }

        // The link has done its job either way; holding the radio open past
        // the transfer is nobody's benefit.
        await _closeDirectLink();
        // The security scope a custom save folder opened stays open for the
        // whole transfer and closes here — the files are written by now.
        await dest.release();

        if (transferAttempt != _transferAttempt) return;
        result.fold(
          (failure) {
            unawaited(_report(0, failure: failure.message));
            add(DownloadFailed(failure.message, code: failure.code));
          },
          (result) {
            // Two different questions, depending on where the bytes went.
            //
            // Staged in the cache, the session owns the whole directory and
            // listing it is exact. Written straight into the user's own
            // folder, it does not: that folder holds everything else they
            // have ever downloaded, so the only honest list is the one the
            // transfer kept of what it wrote.
            final items = dest.placed
                ? _placedItems(result.placedPaths)
                : TransferCache.itemsIn(Directory(dest.path));
            unawaited(
                _report(items.fold<int>(0, (sum, item) => sum + item.size)));
            add(DownloadCompleted(
              result.preferredResultPath,
              fileName: result.displayName,
              items: items,
              placed: dest.placed,
            ));
          },
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
        (failure) => add(DownloadFailed(failure.message, code: failure.code)),
        (path) => add(DownloadCompleted(
          path,
          items: [
            ReceivedItem.fromCacheFile(
              File(path),
              lookupMimeType(path) ?? 'application/octet-stream',
            ),
          ],
        )),
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
      emit(DownloadComplete(event.filePath, name,
          items: event.items, placed: event.placed));
    });

    on<DownloadFailed>((event, emit) {
      emit(ReceiverError(event.error, code: event.code));
    });

    on<CancelDownload>((event, emit) {
      _transferAttempt++;
      unawaited(_closeDirectLink());
      repository.cancelDownload();
      _currentPayload = null;
      emit(ReceiverInitial());
    });
  }

  @override
  Future<void> close() async {
    _interruption.detach();
    await _closeDirectLink();
    return super.close();
  }

  /// Files away what just happened, for the settings screen to show.
  Future<void> _report(int bytes, {String failure = ''}) async {
    final started = _startedAt;
    if (started == null) return;
    _startedAt = null;
    await _diagnostics.record(TransferReport(
      at: started,
      role: 'received',
      route: _route.isEmpty ? 'Unknown' : _route,
      bytes: bytes,
      took: DateTime.now().difference(started),
      failure: failure,
      peerAddress: _connectedTo,
    ));
    _connectedTo = null;
  }

  /// Closes the direct link, if one was ever opened.
  ///
  /// Guarded on having opened one rather than called unconditionally: cancel
  /// runs on every abandoned scan, and reaching for a platform channel to
  /// tear down something that was never built is both pointless and, in a
  /// plain unit test with no binding, an outright failure.
  Future<void> _closeDirectLink() async {
    if (!_directLinkOpen) return;
    _directLinkOpen = false;
    await _peerLink.stop();
  }

  /// Swaps the sender's LAN address for a direct Wi-Fi link, if one comes up.
  ///
  /// Nothing in the QR code says whether the sender is offering this: both
  /// ends derive the same name from the session token they already share, so
  /// an older sender simply is not there to be found and the LAN address is
  /// used as before.
  ///
  /// The returned payload points at localhost, where the native side is
  /// forwarding to the sender's QHTP port. Everything downstream — the
  /// client, the manifest, resume, checksums — is unchanged and unaware.
  /// Whether the address in the QR answers, right now, on this network.
  ///
  /// `/v2/health` is unauthenticated and exists for exactly this. Two seconds
  /// is generous for a LAN round trip and short enough that a device with no
  /// route to the sender is not left waiting before the direct link is tried.
  /// Anything at all going wrong counts as "no": the fallback is a working
  /// transfer over the other path, so there is nothing to gain by being
  /// clever about which failure this was.
  Future<bool> _senderAnswersDirectly(QRPayload payload) async {
    if (payload.ip.isEmpty || payload.port <= 0) return false;
    if (payload.tlsFingerprint.isEmpty) return false;

    HttpClient? client;
    try {
      client = HttpClient(context: SecurityContext(withTrustedRoots: false))
        ..connectionTimeout = const Duration(seconds: 2)
        ..badCertificateCallback = (certificate, host, port) =>
            SessionTlsIdentity.matches(certificate, payload.tlsFingerprint);

      final request = await client
          .getUrl(Uri.parse(
              'https://${payload.ip}:${payload.port}/v2/health'))
          .timeout(const Duration(seconds: 2));
      final response =
          await request.close().timeout(const Duration(seconds: 2));
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  Future<QRPayload> _directRouteOrGiven(QRPayload payload) async {
    if (!PeerLinkService.isSupported) return payload;

    // The network first, the direct link only if there is no network.
    //
    // This used to take the direct link whenever it came up, which on two
    // devices sitting on the same good router is the slower of the two paths
    // by a wide margin: AWDL is a time-sliced side channel, and every byte
    // additionally crosses a userspace bridge and a loopback socket at both
    // ends. Measured on a gigabit network it delivered 11–19 MB/s where the
    // router itself does several times that.
    //
    // What the direct link is for is the pairing nothing else covers — an
    // iPhone and a Mac with no shared network — and that case is exactly the
    // one where this probe fails. `/v2/health` needs no auth and exists to
    // be asked this question.
    if (await _senderAnswersDirectly(payload)) {
      AppLogger.info(
          'The sender is reachable on the network; leaving the direct link '
          'alone',
          tag: 'PEERLINK');
      return payload;
    }

    try {
      final port = await _peerLink.join(
        serviceName: PeerLinkService.serviceNameFor(payload.token),
        timeout: const Duration(seconds: 6),
      );
      _directLinkOpen = true;
      AppLogger.info('Taking the direct Wi-Fi link to the sender',
          tag: 'PEERLINK');
      // Only the address changes — the same session, the same token, and the
      // same certificate fingerprint to pin (the tunnel forwards to the very
      // server the QR describes).
      return payload.copyWith(ip: '127.0.0.1', port: port);
    } on PeerLinkException catch (e) {
      // Expected whenever the sender is on another platform, is an older
      // build, or the two are already on one network: the LAN address in the
      // QR is then the right answer anyway.
      AppLogger.info('No direct Wi-Fi link, using the address in the QR: $e',
          tag: 'PEERLINK');
      return payload;
    }
  }

  /// Serverless path: the QR carries a compact offer and a seed. We answer it,
  /// seal the answer under a key derived from that seed, and drop it on a
  /// public channel the sender is already listening to. Nothing we operate is
  /// involved, and the channel operator only ever sees opaque bytes.
  Future<void> _runServerlessTransfer(
      QRPayload payload, Emitter<ReceiverState> emit) async {
    final channel = buildRendezvousChannel();
    StreamSubscription<WebRtcReceiveProgress>? progressSub;
    ReceiveDestination? dest;
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

      // Desktop writes straight into the folder the user keeps things in —
      // the file is crash-safe on the way (`.qs.partial` + rename), so there
      // is nothing a staging copy would buy. A phone has no such folder and
      // still lands in the cache for the completion screen to place.
      dest = await ReceiveDestination.resolve();

      await transport.receiveWithSdpOffer(
        qr.offer.toSdp(isOffer: true),
        targetDir: dest.path,
        deliverAnswer: (answerSdp) async {
          final sealed = await SealedEnvelope.seal(
            plaintext:
                ServerlessQr.trimForQr(CompactSdp.fromSdp(answerSdp)).toBytes(),
            seed: qr.seed,
            offerFingerprint: qr.offerFingerprint,
          );
          await channel.publish(topic, sealed);
        },
      );

      if (dest.placed) {
        // Already at its final home: report what the transport wrote, don't
        // walk the destination (it is Downloads now, full of other things).
        final items = _placedItems(transport.receivedPaths);
        emit(DownloadComplete(
          items.length == 1 ? items.first.savedPath! : dest.path,
          items.length == 1 ? items.first.name : payload.fileName,
          items: items,
          placed: true,
        ));
      } else {
        // Read off the filesystem rather than from the transport's own list.
        // A folder arrives as a folder — hundreds of files under one root —
        // and the completion screen has one decision to offer about it, not
        // one per photo. The top level of the session directory is exactly
        // what the sender picked.
        final items = TransferCache.itemsIn(Directory(dest.path));
        emit(DownloadComplete(
          items.length == 1 ? items.first.cachePath : dest.path,
          items.length == 1 ? items.first.name : payload.fileName,
          items: items,
        ));
      }
    } catch (e, st) {
      // A cancellation is not a fault, and calling it one sends the user
      // looking for a network problem that never existed. A genuine
      // connection failure still reads as one.
      if (e is TransferCancelledBySender) {
        AppLogger.info('Sender cancelled the transfer', tag: 'WEBRTC_RECEIVER');
        emit(const ReceiverError('The sender cancelled the transfer',
            canRetry: false, code: FailureCode.cancelledBySender));
      } else {
        AppLogger.error('Serverless transfer failed',
            error: e, stackTrace: st, tag: 'WEBRTC_RECEIVER');
        emit(ReceiverError('Serverless transfer failed: $e'));
      }
    } finally {
      await progressSub?.cancel();
      await channel.close();
      await dest?.release();
    }
  }

  /// Wraps the paths a transport wrote — files or a folder, already in place —
  /// as items the completion screen can show as saved.
  List<ReceivedItem> _placedItems(List<String> paths) {
    return [
      for (final path in paths)
        if (FileSystemEntity.isDirectorySync(path))
          ReceivedItem(
            cachePath: path,
            name: p.basename(path),
            size: _treeSize(Directory(path)),
            mimeType: 'inode/directory',
            isDirectory: true,
            savedPath: path,
          )
        else
          ReceivedItem(
            cachePath: path,
            name: p.basename(path),
            size: File(path).existsSync() ? File(path).lengthSync() : 0,
            mimeType: lookupMimeType(path) ?? 'application/octet-stream',
            savedPath: path,
          ),
    ];
  }

  static int _treeSize(Directory dir) {
    var total = 0;
    try {
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += e.lengthSync();
          } on FileSystemException {
            // Vanished between listing and measuring.
          }
        }
      }
    } on FileSystemException {
      // Unreadable; a size of nothing beats hiding the item.
    }
    return total;
  }
}

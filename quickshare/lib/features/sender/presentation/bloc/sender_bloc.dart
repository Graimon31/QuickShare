import 'dart:async';
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
import 'package:quickshare/features/sender/data/indexer/transfer_selection.dart';
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/rendezvous_channels.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/utils/app_logger.dart';
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

/// Re-creates the session that just expired, with the same payload and
/// transport. Raised by the "Refresh" button on the expired-session panel.
class RestartSession extends SenderEvent {}

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

/// Setting a session up: walking the selection, then starting the server.
///
/// Carries how far the walk has got, because it is the only part of this that
/// can take minutes. A screen that shows a count climbing is a screen nobody
/// mistakes for a frozen one — which is exactly what a motionless "indexing"
/// label was doing over a folder on a slow file provider.
class ServerStarting extends SenderState {
  final int indexedItems;
  final int indexedBytes;

  const ServerStarting({this.indexedItems = 0, this.indexedBytes = 0});

  @override
  List<Object?> get props => [indexedItems, indexedBytes];
}

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

  /// The folder this session is, when it is one.
  ///
  /// A folder should be announced by its own name. "412 files" is true and
  /// useless — it is not what the sender picked and not what the recipient is
  /// about to get.
  final String? folderName;
  final int totalBytes;

  const QRReady(
    this.qrData,
    this.session,
    this.mode, {
    this.webLinkUrl,
    this.itemCount = 1,
    this.folderName,
    this.totalBytes = 0,
  });

  @override
  List<Object?> get props =>
      [qrData, session, mode, webLinkUrl, itemCount, totalBytes, folderName];
}

/// Bluetooth is advertising and waiting for a receiver that scanned [qrData].
class BluetoothAdvertising extends SenderState {
  final TransferSession session;
  final String qrData;

  /// How many files the session holds. More than one since folders stopped
  /// being flattened into an archive to fit this channel.
  final int itemCount;

  const BluetoothAdvertising(this.session,
      {required this.qrData, this.itemCount = 1});
  @override
  List<Object?> get props => [session, qrData, itemCount];
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

  /// What the sender's own screens call this session, and the folder name
  /// behind it when the session is a folder. Not what is sent — the list is —
  /// only how it is described while it goes.
  FileMetadata? _sessionDisplay;
  String? _sessionFolderName;
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
  final TransferDiagnostics _diagnostics;
  DateTime? _sendStartedAt;

  /// This device's own address for the active session — `ip:port`, from the
  /// same session the QR names. Recorded alongside the peer address ground
  /// truth ([SenderRepository.lastQhtpClientAddress]) so a transfer report
  /// can show both ends of the connection, not just a route label.
  String? _sessionLocalAddress;
  List<String>? _currentPaths;

  /// Which session attempt is the live one.
  ///
  /// Setting a session up is a long await — indexing a selection, then
  /// starting the server — and until now nothing could interrupt it. Cancel
  /// arrived as its own event, ran to completion, and then the indexing that
  /// was still in flight came back and emitted [QRReady] over the top of it:
  /// the user was taken to a QR screen for a session they had just abandoned,
  /// serving a folder from an already-closed picker. Every step of setup
  /// checks this counter before it emits, and a bumped counter means the
  /// answer is no longer wanted.
  int _sessionGeneration = 0;

  AnswerChannel? _answerChannel;
  StreamSubscription<Uint8List>? _answerSubscription;

  SenderBloc({
    required this.repository,
    LocalHotspotService? hotspotService,
    PeerLinkService? peerLinkService,
    TransferDiagnostics? diagnostics,
  })  : hotspot = hotspotService ?? LocalHotspotService(),
        peerLink = peerLinkService ?? const PeerLinkService(),
        _diagnostics = diagnostics ?? const TransferDiagnostics(),
        super(SenderInitial()) {
    on<PickFile>(_onPickFile);
    on<PickMedia>(_onPickMedia);
    on<StartSending>(_onStartSending);
    on<SelectTransportMode>(_onSelectTransportMode);
    on<StartSendingWithTransport>(_onStartSendingWithTransport);
    on<StartQhtpSend>(_onStartQhtpSend);
    on<StartLocalNetwork>(_onStartLocalNetwork);
    on<CancelSending>(_onCancelSending);
    on<RestartSession>(_onRestartSession);
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
    // A stale listener from an earlier Bluetooth fast-path attempt otherwise
    // outlives that session: `transferProgress` is one stream shared by
    // every QHTP session this server ever runs, so a fast-path subscription
    // still around when a fresh Wi-Fi send starts hears that send's bytes
    // too, and reports them as a second, spurious completion of whatever
    // send happened to be in flight when it was created — a phantom entry
    // in the transfer history with none of the real send's numbers, because
    // by then this bloc's own session fields already belong to something
    // else.
    _fastPathSubscription?.cancel();
    _fastPathSubscription = null;
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
    emit(const ServerStarting());

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
            .listen((blocked) =>
                add(RelayBlocked(blocked.sessionBytes, blocked.limitBytes)));

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
          _makeDummySession(_sessionDisplay ?? file),
          mode,
          itemCount: session.length,
          totalBytes: session.fold<int>(0, (sum, f) => sum + f.size),
          folderName: _sessionFolderName,
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
            // The transport knows why — an unreadable file, a receiver too
            // old to take a folder — and that reason is the only part the
            // person sending can act on. It used to end in a debugPrint while
            // the screen said "failed unexpectedly".
            add(TransferFailed(_activeBluetoothTransport?.lastFailureReason ??
                'Bluetooth transfer failed unexpectedly'));
          }
        });

        final token = const Uuid().v4();
        await _activeBluetoothTransport!
            .startSharing(file, token, files: _sessionFiles ?? [file]);
        // Awaited on purpose: the fast path subscribes to the repository's
        // progress stream, and that subscription must exist before the QR
        // shows, or the first progress events fall on the floor. It is cheap
        // now that indexing no longer hashes inline.
        await _offerBluetoothFastPath(token);
        emit(BluetoothAdvertising(
          _makeDummySession(_sessionDisplay ?? file),
          qrData: BluetoothQrPayload(token: token).encode(),
          itemCount: (_sessionFiles ?? [file]).length,
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
    final generation = ++_sessionGeneration;
    bool abandoned() => generation != _sessionGeneration;
    _currentPaths = event.paths;
    // A fresh session: forget the last one's timing, route and description.
    _sendStartedAt = null;
    _sessionLocalAddress = null;
    _sessionDisplay = null;
    _sessionFolderName = null;
    final mode = event.mode ?? _selectedMode;
    if (mode == TransportType.internet || mode == TransportType.bluetooth) {
      if (event.paths.isEmpty) {
        emit(const SenderError('No files or folders selected.'));
        return;
      }

      // Nothing is bundled any more, on any channel.
      //
      // A folder is a tree, and every route out of this app now carries one:
      // the DataChannel manifest and QHTP always could, and the Bluetooth
      // bridge was taught to. Each file travels with the relative path it has
      // to keep, so the folder is rebuilt on the far side rather than handed
      // over as an archive to unpack — photos land in a gallery, a project
      // folder arrives as a project folder.
      //
      // The zip that used to stand here was never about structure anyway. It
      // was about turning a tree into one object of a known size because the
      // channel could not express anything else, and it charged for that: a
      // full deflate pass before the first byte could leave, and a .zip at
      // the other end whatever the recipient actually wanted. Walking the
      // selection costs directory reads and no payload pass at all.
      emit(const ServerStarting());
      final List<FileMetadata> files;
      try {
        files = await expandSelection(event.paths);
      } catch (e) {
        // Empty folders, unreadable ones, selections past the size and depth
        // ceilings — all of which used to surface as "failed to archive".
        if (!abandoned()) emit(SenderError('Could not read the selection: $e'));
        return;
      }

      if (abandoned()) return;
      _sessionFiles = files;
      // The first item is what a single-file session is entirely made of, and
      // what the transports lead with. Leaving the previous send's list in
      // place once made the next transfer offer a manifest of files it was
      // not sending, so both are always set here.
      _currentFile = files.first;
      _sessionFolderName = commonRootFolder(files);
      _sessionDisplay = _sessionFolderName == null
          ? files.first
          : FileMetadata(
              name: _sessionFolderName!,
              path: event.paths.first,
              size: files.fold<int>(0, (sum, f) => sum + f.size),
              mimeType: 'inode/directory',
            );
      await _startSendingInternal(files.first, mode, emit);
      return;
    }

    emit(const ServerStarting());
    _subscribeToWifiProgress();
    final result = await repository.startQhtpTransfer(
      event.paths,
      onIndexProgress: (items, bytes) {
        // Safe to emit from here: the walk runs inside this handler's await,
        // so the emitter is still open. The generation check keeps a
        // cancelled session from redrawing the screen it just left.
        if (abandoned() || isClosed) return;
        emit(ServerStarting(indexedItems: items, indexedBytes: bytes));
      },
    );
    await result.fold(
      (failure) async {
        if (!abandoned()) emit(SenderError(failure.message));
      },
      (session) async {
        // Cancelled while the selection was being indexed. The server is
        // already listening by now, so leaving quietly would leave it
        // listening for good — a session nobody can reach and nothing will
        // ever close.
        if (abandoned()) {
          await repository.stopServer(force: true);
          return;
        }
        _currentFile = session.fileMetadata;
        _sessionLocalAddress = '${session.localIp}:${session.serverPort}';
        await _offerOverDirectWiFi(session);
        final qrResult = await repository.generateQRPayload(session);
        if (abandoned()) {
          await repository.stopServer(force: true);
          await peerLink.stop();
          return;
        }
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
  /// Both routes carry the same thing now — the selection itself, folders
  /// and all — so which one wins changes only how long it takes, never what
  /// the recipient ends up holding.
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
          _sessionLocalAddress = '${session.localIp}:${session.serverPort}';
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
    // Read before the server stops, not after: stopping it clears the one
    // fact — which address, if any, ever connected — that says whether this
    // was a send somebody was receiving or a QR nobody had scanned yet. A
    // cancelled send used to leave no trace at all in the history, which
    // read as "nothing happened here" to someone looking for why a transfer
    // never finished.
    // Anything still setting a session up is now setting up a session
    // nobody wants; see [_sessionGeneration].
    _sessionGeneration++;
    await _reportSend(failure: 'Cancelled');
    // The HTTP server goes down first, forced, and before either network
    // path that carries it: a receiver mid-download is inside a socket read
    // right now, and force-closing that socket while the hotspot or peer
    // link is still up lands a TCP reset while there is still a network to
    // carry it. Stopping the hotspot or peer link first was the bug —
    // tearing down the radio out from under an open connection leaves the
    // receiver's packets going nowhere and answered by nothing, which reads
    // as a stall, not a reset, and used to cost the receiver most of a
    // minute of retries before it gave up.
    await repository.stopServer(force: true);
    await hotspot.stopHosting();
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

  /// `_currentPaths` deliberately survives CancelSending: expiry is the one
  /// flow that must start over with the same selection, and it gets here only
  /// from the expired-session panel.
  Future<void> _onRestartSession(
      RestartSession event, Emitter<SenderState> emit) async {
    final paths = _currentPaths;
    if (paths != null && paths.isNotEmpty) {
      await _onStartQhtpSend(StartQhtpSend(paths, mode: _selectedMode), emit);
      return;
    }
    emit(const SenderError('Nothing to restart.'));
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

    // Ground truth, not intent: whether `peerLink.host()` returned without
    // throwing says the direct link came up, not which address the far side
    // actually opened a socket to. The two used to be treated as the same
    // thing, which is how a session the receiver took over plain Wi-Fi still
    // came out labelled "Direct Wi-Fi link" — the offer had succeeded, the
    // receiver just never took it.
    final clientAddress = repository.lastQhtpClientAddress;
    final ice = _activeWebRtcTransport?.lastIcePath;
    final route = switch (ice) {
      IcePathKind.relayed => 'Internet (relayed)',
      IcePathKind.peerToPeer => 'Internet (peer to peer)',
      IcePathKind.direct => 'Internet (direct, same network)',
      _ when _activeBluetoothTransport != null && clientAddress == null =>
        'Bluetooth',
      _ when clientAddress != null && clientAddress.isLoopback =>
        'Direct Wi-Fi link',
      _ => 'Local network',
    };

    // `_sessionFiles` only exists for the Bluetooth/internet branch, which
    // hands this bloc the whole file list because it has to flatten folders
    // itself. The plain Wi-Fi branch never sets it — QHTP does its own
    // indexing server-side — but `_currentFile` there is the manifest's own
    // total size, set from the session the server actually opened, so it is
    // just as good a number and it is the one that was missing.
    final bytes = (_sessionFiles != null && _sessionFiles!.isNotEmpty)
        ? _sessionFiles!.fold<int>(0, (sum, f) => sum + f.size)
        : (_currentFile?.size ?? 0);

    await _diagnostics.record(TransferReport(
      at: started,
      role: 'sent',
      route: route,
      bytes: bytes,
      took: DateTime.now().difference(started),
      failure: failure,
      localAddress: _sessionLocalAddress,
      peerAddress: clientAddress?.address,
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
    } else {
      emit(SenderInitial());
    }
  }

  Future<void> _onTransferFailed(
      TransferFailed event, Emitter<SenderState> emit) async {
    // Same ordering as cancel, same reason: the server still knows who was
    // connected, if anyone was, until it stops.
    await _reportSend(failure: event.error);
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

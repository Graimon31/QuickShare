// An offer that replaces itself every five minutes.
//
// The code and the QR on the sender's screen are good for five minutes. The
// bloc owns that clock — not the page — because the page is gone the moment a
// transfer starts and the clock must stop with it, and because a rotation has
// to do the same things whichever screen asked for it: new secrets, a new QR,
// a new announcement, and the old ones dead.
//
// Time is `fake_async`; the wall clock the bloc reads is the same clock plus
// whatever a test says the machine spent asleep.
//
// The fakes below hold stream controllers for the length of a test and let the
// test's end collect them.
// ignore_for_file: close_sinks
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/signaling/worker_answer_channel.dart'
    show PayloadAcceptor;
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

// ─── Fakes ───────────────────────────────────────────────────────────────

class _NoDiagnostics extends TransferDiagnostics {
  const _NoDiagnostics();
  @override
  Future<void> record(TransferReport report) async {}
}

/// The native side, silenced: the tests are about the offer, not the radios.
class _SilentPeerLink extends PeerLinkService {
  const _SilentPeerLink();
  @override
  Future<void> stop() async {}
}

class _MockHotspot extends Mock implements LocalHotspotService {}

/// Records what the bloc asked the network to say.
class _Advertiser implements RendezvousAdvertiser {
  final List<({int port, String hint})> advertised = [];
  int stops = 0;
  ({int port, String hint})? onAir;

  @override
  Future<void> advertise({required int port, required String hint}) async {
    advertised.add((port: port, hint: hint));
    onAir = (port: port, hint: hint);
  }

  @override
  Future<void> stop() async {
    stops++;
    onAir = null;
  }
}

class _Repository implements SenderRepository {
  final approvals = StreamController<TransferApprovalRequest>.broadcast();
  final progress = StreamController<double>.broadcast();

  /// Every token a session was started or rotated with, oldest first.
  final List<String> tokens = [];
  final List<SessionCode?> codes = [];
  int starts = 0;
  int rotations = 0;
  int stops = 0;
  bool serverAlive = true;
  bool healthy = true;
  Completer<void>? holdStart;

  TransferSession _session(String token) => TransferSession(
        id: 'session-$starts',
        fileMetadata: const FileMetadata(
          name: 'offer.bin',
          path: '/tmp/offer.bin',
          size: 0,
          mimeType: 'application/octet-stream',
        ),
        serverPort: 8123,
        authToken: token,
        localIp: '192.168.1.10',
        startedAt: DateTime.utc(2026),
        status: TransferStatus.serving,
        isQhtp: true,
      );

  @override
  Future<Either<Failure, TransferSession>> startQhtpTransfer(
    List<String> paths, {
    String? authToken,
    SessionCode? sessionCode,
    void Function(int items, int bytes)? onIndexProgress,
    void Function(int itemCount, int totalBytes)? onIndexed,
    void Function(Object error)? onIndexFailed,
  }) async {
    starts++;
    tokens.add(authToken!);
    codes.add(sessionCode);
    if (holdStart != null) await holdStart!.future;
    return Right(_session(authToken));
  }

  @override
  Future<Either<Failure, TransferSession>> rotateSession(
    TransferSession session, {
    required String authToken,
    SessionCode? sessionCode,
  }) async {
    if (!serverAlive) {
      return const Left(ServerFailure('The session is no longer running.'));
    }
    rotations++;
    tokens.add(authToken);
    codes.add(sessionCode);
    return Right(session.copyWith(authToken: authToken));
  }

  @override
  Future<bool> verifyServing() async => healthy;

  @override
  Future<Either<Failure, String>> generateQRPayload(TransferSession session,
          {String? hostOverride}) async =>
      Right('QR|${session.authToken}');

  @override
  Future<Either<Failure, void>> stopServer({bool force = false}) async {
    stops++;
    return const Right(null);
  }

  @override
  Stream<TransferApprovalRequest> get approvalRequests => approvals.stream;

  @override
  void respondToApproval(String requestId, bool accepted) {
    for (final r in _open) {
      if (r.id == requestId) r.complete(accepted);
    }
  }

  final List<TransferApprovalRequest> _open = [];

  /// A receiver that proved the code asks to be let in.
  TransferApprovalRequest ask() {
    final request = TransferApprovalRequest(
      id: 'req-${_open.length}',
      remoteAddress: InternetAddress('192.168.1.99'),
      deviceName: 'Alice laptop',
      itemCount: 1,
      totalBytes: 10,
    );
    _open.add(request);
    approvals.add(request);
    return request;
  }

  @override
  Stream<double> get transferProgress => progress.stream;
  @override
  Stream<TransferStatus> get statusStream => const Stream.empty();
  @override
  InternetAddress? get lastQhtpClientAddress => null;
  @override
  String? get sessionTlsFingerprint => 'AA:BB';
  @override
  Future<bool> waitForFirstClient({Duration timeout = const Duration(seconds: 10)}) async => true;

  @override
  Future<Either<Failure, FileMetadata>> pickFile() => throw UnimplementedError();
  @override
  Future<Either<Failure, FileMetadata>> pickMedia() => throw UnimplementedError();
  @override
  Future<Either<Failure, TransferSession>> startServer(FileMetadata file) =>
      throw UnimplementedError();
}

/// A bloc whose state a test can set, for the transitions production has no
/// event for.
class _Bloc extends SenderBloc {
  _Bloc({
    required super.repository,
    super.advertiser,
    super.now,
    super.webRtcTransportFactory,
    super.bluetoothTransportFactory,
    super.rendezvousChannelFactory,
    super.diagnostics,
    super.hotspotService,
    super.peerLinkService,
  });

  void force(SenderState s) => emit(s);
}

class _Harness {
  _Harness(this.async,
      {_Repository? repo,
      WebRtcTransferTransport Function()? webRtc,
      BluetoothTransferTransport Function()? bluetooth,
      AnswerChannel Function({PayloadAcceptor? acceptPayload})? channels})
      : repo = repo ?? _Repository() {
    final hotspot = _MockHotspot();
    when(hotspot.stopHosting).thenAnswer((_) async {});
    bloc = _Bloc(
      hotspotService: hotspot,
      peerLinkService: const _SilentPeerLink(),
      repository: this.repo,
      advertiser: advertiser,
      now: now,
      diagnostics: const _NoDiagnostics(),
      webRtcTransportFactory: webRtc,
      bluetoothTransportFactory: bluetooth,
      rendezvousChannelFactory: channels,
    );
  }

  static final epoch = DateTime.utc(2026, 11, 4, 12);

  final FakeAsync async;
  final _Repository repo;
  final advertiser = _Advertiser();
  late final _Bloc bloc;
  Duration asleep = Duration.zero;

  DateTime now() => epoch.add(async.elapsed + asleep);

  void settle() => async.flushMicrotasks();

  void pass(Duration d) {
    async.elapse(d);
    async.flushMicrotasks();
  }

  QRReady get offer {
    final s = bloc.state;
    expect(s, isA<QRReady>(), reason: 'expected an offer on screen, got $s');
    return s as QRReady;
  }

  /// The walk has said how much there is, which is what lets progress mean
  /// anything.
  void sizeKnown() {
    bloc.add(const IndexProgressed(1, 1000, generation: 1, complete: true));
    settle();
  }

  void startWifi() {
    bloc.add(const StartQhtpSend(['/tmp/offer.bin'], mode: TransportType.wifi));
    settle();
  }
}

const _five = AppConstants.sessionCodeLifetime;
final _almost = _five - const Duration(milliseconds: 1);

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  group('with no offer open', () {
    test('nothing is advertised, before or while a session is being set up',
        () {
      fakeAsync((async) {
        final t = _Harness(async);
        t.repo.holdStart = Completer<void>();

        expect(t.advertiser.advertised, isEmpty);
        t.bloc.add(const StartQhtpSend(['/tmp/offer.bin']));
        t.settle();
        expect(t.bloc.state, isA<ServerStarting>());
        expect(t.advertiser.advertised, isEmpty,
            reason: 'there is nothing to find yet');
        expect(t.advertiser.onAir, isNull);
      });
    });
  });

  group('a Wi-Fi offer', () {
    test('is advertised by its hint and port while it is on screen, and '
        'withdrawn when it ends', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        final offer = t.offer;

        expect(t.advertiser.onAir,
            (port: 8123, hint: offer.code!.discoveryHint));

        t.bloc.add(CancelSending());
        t.settle();

        expect(t.advertiser.onAir, isNull);
        expect(t.advertiser.stops, greaterThan(0));
      });
    });

    test('carries the time its code lasts, from the moment it appeared', () {
      fakeAsync((async) {
        final t = _Harness(async);
        t.pass(const Duration(seconds: 7));
        t.startWifi();

        expect(t.offer.expiresAt, _Harness.epoch.add(const Duration(seconds: 7)).add(_five));
      });
    });

    test('rotates at exactly five minutes: new code, new token, new QR, new '
        'hint on the air', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        final before = t.offer;

        t.pass(_almost);
        expect(t.offer.code, before.code, reason: 'one millisecond early');
        expect(t.repo.rotations, 0);

        t.pass(const Duration(milliseconds: 1));
        final after = t.offer;

        expect(t.repo.rotations, 1);
        expect(after.code, isNot(before.code));
        expect(after.qrData, isNot(before.qrData));
        expect(after.session.authToken, isNot(before.session.authToken));
        expect(t.repo.tokens, hasLength(2));
        expect(t.repo.tokens.toSet(), hasLength(2));
        expect(after.session.serverPort, before.session.serverPort,
            reason: 'same server, same port');
        expect(after.expiresAt, before.expiresAt!.add(_five));

        expect(t.advertiser.advertised, hasLength(2));
        expect(t.advertiser.onAir,
            (port: 8123, hint: after.code!.discoveryHint));
      });
    });

    test('the QR carries the new token and the receiver-typed code is the new '
        'one', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        final first = t.offer;
        t.pass(_five);
        final second = t.offer;

        expect(first.qrData, 'QR|${first.session.authToken}');
        expect(second.qrData, 'QR|${second.session.authToken}');
        expect(t.repo.codes.last, second.code);
        expect(t.repo.tokens.last, second.session.authToken);
      });
    });

    test('keeps rotating, every five minutes, for as long as the screen is up',
        () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        final codes = {t.offer.code};
        for (var i = 0; i < 4; i++) {
          t.pass(_five);
          codes.add(t.offer.code);
        }
        expect(t.repo.rotations, 4);
        expect(codes, hasLength(5));
      });
    });

    test('keeps what the walk found out: the totals survive a rotation', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        t.bloc.add(const IndexProgressed(12, 3456, generation: 1, complete: true));
        t.settle();
        expect(t.offer.itemCount, 12);

        t.pass(_five);

        expect(t.offer.itemCount, 12);
        expect(t.offer.totalBytes, 3456);
        expect(t.offer.indexing, isFalse);
      });
    });

    test('after the machine slept through the deadline it rotates when the '
        'screen comes back, not when a timer next fires', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        final before = t.offer;

        t.asleep = const Duration(minutes: 30);
        t.bloc.add(OfferResumed());
        t.settle();

        expect(t.repo.rotations, 1);
        expect(t.offer.code, isNot(before.code));
        expect(t.offer.expiresAt!.isAfter(t.now()), isTrue);
      });
    });

    test('coming back before the deadline rotates nothing', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        t.pass(const Duration(minutes: 2));

        t.bloc.add(OfferResumed());
        t.settle();

        expect(t.repo.rotations, 0);
      });
    });

    test('coming back to a server the system took away starts the offer over '
        'with fresh secrets', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        final before = t.offer;
        t.repo.healthy = false;

        t.bloc.add(OfferResumed());
        t.settle();

        expect(t.repo.starts, 2, reason: 'a new server was started');
        expect(t.offer.code, isNot(before.code));
        expect(t.offer.session.authToken, isNot(before.session.authToken));
      });
    });

    test('a session that has ended on its own says so instead of showing a '
        'dead code', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        t.repo.serverAlive = false;

        t.pass(_five);

        final state = t.bloc.state;
        expect(state, isA<SenderError>());
        expect((state as SenderError).code, FailureCode.offerEnded);
        expect(t.advertiser.onAir, isNull);
      });
    });
  });

  group('while a person is being asked', () {
    test('rotation waits, and happens as soon as the answer is given', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        final request = t.repo.ask();
        t.settle();
        expect(t.bloc.state, isA<InviteApprovalRequested>());
        final before = (t.bloc.state as InviteApprovalRequested).previousState;

        t.pass(const Duration(minutes: 9));
        expect(t.repo.rotations, 0,
            reason: 'the dialog is open; nothing underneath it moves');

        t.bloc.add(RespondToInviteApproval(
            requestId: request.id, accepted: true));
        t.settle();

        expect(t.repo.rotations, 1);
        expect(t.offer.code, isNot(before.code));
      });
    });

    test('a request nobody answered stops holding when the server gives up on '
        'it', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        final request = t.repo.ask();
        t.settle();

        t.pass(const Duration(minutes: 7));
        expect(t.repo.rotations, 0);

        // The server's own ninety seconds ran out.
        request.complete(false);
        t.settle();

        expect(t.repo.rotations, 1);
      });
    });
  });

  group('once a transfer has started', () {
    test('rotation stops, the announcement goes, and nothing fires later', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();

        t.sizeKnown();
        t.repo.progress.add(0.1);
        t.settle();
        expect(t.bloc.state, isA<Transferring>());
        expect(t.advertiser.onAir, isNull);

        t.pass(const Duration(hours: 1));

        expect(t.repo.rotations, 0);
        expect(t.bloc.state, isA<Transferring>());
      });
    });

    test('if the screen is back on an offer afterwards, rotation resumes — '
        'immediately when the deadline passed meanwhile', () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        final offer = t.offer;
        t.sizeKnown();
        t.repo.progress.add(0.1);
        t.settle();
        expect(t.bloc.state, isA<Transferring>());
        t.pass(const Duration(minutes: 12));
        expect(t.repo.rotations, 0);

        t.bloc.force(offer);
        t.settle();

        expect(t.repo.rotations, 1);
        expect(t.advertiser.onAir, isNotNull);
      });
    });

    test('a cancelled offer is gone for good, and the next one rotates afresh',
        () {
      fakeAsync((async) {
        final t = _Harness(async)..startWifi();
        t.bloc.add(CancelSending());
        t.settle();
        t.pass(const Duration(minutes: 30));
        expect(t.repo.rotations, 0, reason: 'nothing left to rotate');

        t.startWifi();
        t.pass(_five);
        t.pass(const Duration(milliseconds: 50));
        expect(t.repo.rotations, 1);
      });
    });
  });

  group('the Internet tab', () {
    late List<_FakeWebRtc> transports;
    late List<_FakeChannel> channels;

    setUp(() {
      transports = [];
      channels = [];
    });

    _Harness internet(FakeAsync async) => _Harness(
          async,
          webRtc: () => _FakeWebRtc()..also(transports.add),
          channels: ({PayloadAcceptor? acceptPayload}) =>
              _FakeChannel()..also(channels.add),
        );

    const file = FileMetadata(
      name: 'offer.bin',
      path: '/tmp/offer.bin',
      size: 5,
      mimeType: 'application/octet-stream',
    );

    void start(_Harness t) {
      t.bloc.add(const StartSendingWithTransport(file, TransportType.internet));
      t.settle();
      t.pass(const Duration(milliseconds: 50));
    }

    test('an offer that nobody answered is replaced by a fresh one, and the '
        'old subscription and peer connection are closed', () {
      fakeAsync((async) {
        final t = internet(async);
        start(t);
        final first = t.offer;
        expect(transports, hasLength(1));
        expect(channels, hasLength(1));

        t.pass(_five);
        t.pass(const Duration(milliseconds: 50));

        final second = t.offer;
        expect(second.qrData, isNot(first.qrData));
        expect(transports, hasLength(2));
        expect(transports.first.stopped, isTrue,
            reason: 'the old peer connection is closed');
        expect(transports.last.stopped, isFalse);
        expect(channels.first.closed, isTrue,
            reason: 'the old rendezvous subscription is closed');
        expect(channels.last.closed, isFalse);
        expect(channels.last.topic, isNot(channels.first.topic),
            reason: 'a fresh seed, so a fresh topic');
        expect(second.expiresAt!.isAfter(first.expiresAt!), isTrue);
      });
    });

    test('the old link leads nowhere: an answer on the old channel is not '
        'applied', () {
      fakeAsync((async) {
        final t = internet(async);
        start(t);
        final oldQr = ServerlessQr.decode(t.offer.qrData);
        t.pass(_five);
        t.pass(const Duration(milliseconds: 50));
        final oldTransport = transports.first;
        final oldChannel = channels.first;

        unawaited(() async {
          final sealed = await SealedEnvelope.seal(
            plaintext: oldQr.offer.toBytes(),
            seed: oldQr.seed,
            offerFingerprint: oldQr.offerFingerprint,
          );
          oldChannel.deliver(sealed);
        }());
        t.pass(const Duration(milliseconds: 50));

        expect(oldTransport.answers, isEmpty);
        expect(transports.last.answers, isEmpty);
      });
    });

    test('an answer arrived: the offer is held, however long it takes', () {
      fakeAsync((async) {
        final t = internet(async);
        start(t);
        final qr = ServerlessQr.decode(t.offer.qrData);

        unawaited(() async {
          final sealed = await SealedEnvelope.seal(
            plaintext: qr.offer.toBytes(),
            seed: qr.seed,
            offerFingerprint: qr.offerFingerprint,
          );
          channels.single.deliver(sealed);
        }());
        t.pass(const Duration(milliseconds: 50));
        expect(transports.single.answers, hasLength(1),
            reason: 'the answer was applied');

        t.pass(const Duration(hours: 1));

        expect(transports, hasLength(1), reason: 'no new offer mid-negotiation');
        expect(transports.single.stopped, isFalse);
        expect(channels.single.closed, isFalse);
      });
    });
  });

  group('the Bluetooth tab', () {
    late List<_FakeBluetooth> radios;

    setUp(() => radios = []);

    _Harness bluetooth(FakeAsync async) => _Harness(
          async,
          bluetooth: () => _FakeBluetooth()..also(radios.add),
        );

    const file = FileMetadata(
      name: 'offer.bin',
      path: '/tmp/offer.bin',
      size: 5,
      mimeType: 'application/octet-stream',
    );

    void start(_Harness t) {
      t.bloc.add(const StartSendingWithTransport(file, TransportType.bluetooth));
      t.settle();
    }

    BluetoothAdvertising adv(_Harness t) {
      final s = t.bloc.state;
      expect(s, isA<BluetoothAdvertising>(), reason: '$s');
      return s as BluetoothAdvertising;
    }

    test('a lone advertisement is restarted under a new code at five minutes',
        () {
      fakeAsync((async) {
        final t = bluetooth(async);
        start(t);
        final first = adv(t);
        expect(first.expiresAt, _Harness.epoch.add(_five));

        t.pass(_five);
        t.pass(const Duration(milliseconds: 50));
        t.pass(const Duration(milliseconds: 1));

        final second = adv(t);
        expect(second.code, isNot(first.code));
        expect(second.qrData, isNot(first.qrData));
        expect(radios, hasLength(2));
        expect(radios.first.stopped, isTrue, reason: 'the old advertisement');
        expect(radios.last.started.single.publicId, second.code!.publicId,
            reason: 'what is on the air now is derived from the new code');
        expect(radios.last.started.single.token, second.code!.sessionToken);
        expect(BluetoothQrPayload.tryDecode(second.qrData)!.token,
            second.code!.sessionToken);
      });
    });

    test('a receiver that is connected holds it, and it moves on when that '
        'ends', () {
      fakeAsync((async) {
        final t = bluetooth(async);
        start(t);

        radios.single.ready.add(null);
        t.settle();
        t.pass(const Duration(minutes: 20));

        expect(radios, hasLength(1), reason: 'never mid-connection');
        expect(radios.single.stopped, isFalse);
      });
    });

    test('a receiver that is merely connecting holds it until it goes away',
        () {
      fakeAsync((async) {
        final t = bluetooth(async);
        start(t);

        radios.single.status.add(TransferStatus.connecting);
        t.settle();
        t.pass(const Duration(minutes: 9));
        expect(radios, hasLength(1));

        radios.single.status.add(TransferStatus.serving);
        t.settle();
        expect(radios, hasLength(2), reason: 'the deadline passed meanwhile');
      });
    });
  });
}

// ─── Fakes for the other two transports ────────────────────────────────

extension _Also<T> on T {
  void also(void Function(T) f) => f(this);
}

class _FakeChannel implements AnswerChannel {
  final _answers = StreamController<Uint8List>.broadcast();
  String? topic;
  bool closed = false;

  void deliver(Uint8List payload) {
    if (!_answers.isClosed) _answers.add(payload);
  }

  @override
  String get name => 'fake';
  @override
  Stream<Uint8List> get answers => _answers.stream;
  @override
  Future<void> subscribe(String topic) async => this.topic = topic;
  @override
  Future<void> publish(String topic, Uint8List payload) async {}
  @override
  Future<void> close() async {
    closed = true;
    await _answers.close();
  }
}

class _FakeWebRtc extends WebRtcTransferTransport {
  bool stopped = false;
  final List<String> answers = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> startSharingServerless(FileMetadata file,
      {List<FileMetadata>? files,
      Future<List<FileMetadata>>? filesReady}) async {}

  @override
  Future<String?> createLocalOfferSdp() async => _offerSdp();

  @override
  Future<void> handleDirectAnswer(String sdp, String type) async =>
      answers.add(sdp);

  @override
  Future<void> stopSharing() async => stopped = true;
}

String _offerSdp() => '''v=0
o=- 4611731400430051336 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=ice-ufrag:F7gI
a=ice-pwd:x9cO/TDwjM9zPCTFEJUUS9nJ
a=fingerprint:sha-256 8F:BF:9A:F5:5A:AE:1C:2C:1D:BE:1E:1A:33:6C:A1:9B:11:B2:CE:1B:4A:36:1E:4B:1B:6A:1C:F1:0E:2B:3A:5C
a=setup:actpass
a=mid:0
a=sctp-port:5000
a=candidate:0 1 udp 2122260223 192.168.3.1 40000 typ host generation 0
''';

class _FakeBluetooth extends BluetoothTransferTransport {
  bool stopped = false;
  final List<({String token, String publicId})> started = [];
  final ready = StreamController<void>.broadcast();
  final status = StreamController<TransferStatus>.broadcast();
  final progress = StreamController<double>.broadcast();

  @override
  Stream<void> get receiverReady => ready.stream;
  @override
  Stream<TransferStatus> get statusStream => status.stream;
  @override
  Stream<double> get progressStream => progress.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<String> startSharing(FileMetadata file, String token,
      {List<FileMetadata>? files, String publicId = ''}) async {
    started.add((token: token, publicId: publicId));
    return file.name;
  }

  @override
  Future<void> stopSharing() async => stopped = true;
}

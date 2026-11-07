import 'dart:async';
import 'dart:io';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';

import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';

import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';

class MockSenderRepository extends Mock implements SenderRepository {}

/// How long a test waits for something it is certain will happen before it
/// says so. This is not a delay anything depends on: a test that finds what it
/// waits for goes on at once, and one that never does fails with a sentence
/// instead of hanging until the runner's own limit.
const _patience = Duration(seconds: 20);

/// The first state of type [S] that [bloc] emits from here on, once [where]
/// accepts it.
///
/// Call it *before* the thing that causes the state: the stream is a
/// broadcast one, so a state emitted while nobody listens is gone.
///
/// The tests below used to wait a fixed 20 or 30 milliseconds after each step
/// and then read what the bloc had written to disk. A bloc does not wait for
/// its handlers when it closes (`Bloc.close` cancels the emitters, which
/// completes their futures at once), so a report whose write took longer than
/// the last of those pauses was read before it existed — an empty history —
/// and one that landed late was written into the *next* test's folder. Waiting
/// for the state a handler ends on has neither problem: `TransferComplete`,
/// `SenderError` and `SenderInitial` are emitted only after the report is on
/// disk.
Future<S> _next<S extends SenderState>(SenderBloc bloc,
        {bool Function(S state)? where}) =>
    bloc.stream
        .where((state) => state is S && (where?.call(state) ?? true))
        .cast<S>()
        .first
        .timeout(_patience,
            onTimeout: () => throw TimeoutException(
                'no $S state came from the bloc within $_patience'));

/// Starts a Wi-Fi send and returns once the offer is on screen: the server is
/// up, the progress listener is subscribed and a progress event will be seen.
Future<void> _startWifiSend(SenderBloc bloc) async {
  final shown = _next<QRReady>(bloc);
  bloc.add(const StartQhtpSend(['/tmp/whatever'], mode: TransportType.wifi));
  await shown;
}

/// A future for "the bloc has made this call", to be completed from inside a
/// stub: waiting for the call itself instead of for a pause long enough that it
/// has surely happened.
Future<void> _within(Future<void> event) => event.timeout(_patience,
    onTimeout: () =>
        throw TimeoutException('the call never came within $_patience'));

class _MockLocalHotspotService extends Mock implements LocalHotspotService {}

/// Stands in for the native side and remembers whether it was asked to host.
///
/// `supported` is forced true so the question is asked on every host, not
/// just an Apple one — otherwise the assertion below passes on Linux CI for
/// the wrong reason.
class _RecordingPeerLink extends PeerLinkService {
  _RecordingPeerLink();

  final List<String> hosted = [];

  @override
  bool get supported => true;

  @override
  Future<void> host({
    required String serviceName,
    required int localPort,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    hosted.add(serviceName);
  }

  @override
  Future<void> stop() async {}
}

void main() {
  late MockSenderRepository mockRepository;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(const FileMetadata(
      name: 'dummy',
      path: '/tmp/dummy',
      size: 0,
      mimeType: 'text/plain',
    ));
    registerFallbackValue(TransportType.internet);
    registerFallbackValue(TransferSession(
      id: 'dummy',
      fileMetadata: const FileMetadata(
        name: 'dummy',
        path: '/tmp/dummy',
        size: 0,
        mimeType: 'text/plain',
      ),
      serverPort: 8080,
      authToken: 'dummy',
      localIp: '127.0.0.1',
      startedAt: DateTime.now(),
    ));
    registerFallbackValue(const Duration(seconds: 1));
  });

  setUp(() {
    mockRepository = MockSenderRepository();
    when(() => mockRepository.transferProgress)
        .thenAnswer((_) => const Stream.empty());
    when(() => mockRepository.statusStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => mockRepository.stopServer())
        .thenAnswer((_) async => const Right(null));
    when(() => mockRepository.stopServer(force: true))
        .thenAnswer((_) async => const Right(null));
    when(() =>
            mockRepository.waitForFirstClient(timeout: any(named: 'timeout')))
        .thenAnswer((_) async => true);
    when(() => mockRepository.approvalRequests)
        .thenAnswer((_) => const Stream.empty());
  });

  group('SenderBloc', () {
    blocTest<SenderBloc, SenderState>(
      'a queued reconnect status preserves the highest displayed progress',
      build: () => SenderBloc(repository: mockRepository),
      seed: () => const Transferring(0.6, 0),
      act: (bloc) async {
        var next = _next<Transferring>(bloc);
        bloc.add(const TransferProgressEvent(0.5, reconnecting: true));
        await next;
        next = _next<Transferring>(bloc);
        bloc.add(const TransferProgressEvent(0.7));
        await next;
        next = _next<Transferring>(bloc);
        bloc.add(const TransferProgressEvent(0.6, reconnecting: false));
        await next;
      },
      expect: () => [
        const Transferring(0.6, 0, reconnecting: true),
        const Transferring(0.7, 0, reconnecting: true),
        const Transferring(0.7, 0),
      ],
    );

    blocTest<SenderBloc, SenderState>(
      'emits [SenderError] when pickFile fails',
      build: () {
        when(() => mockRepository.pickFile()).thenAnswer(
            (_) async => const Left(FileFailure('No file selected')));
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) => bloc.add(PickFile()),
      expect: () => [isA<SenderError>()],
    );

    // DD-17. The screen shows the code, not the sentence: a message composed
    // here is English forever, whatever the interface is set to afterwards.
    blocTest<SenderBloc, SenderState>(
      'a send with nothing chosen names the reason as a code',
      build: () => SenderBloc(repository: mockRepository),
      act: (bloc) =>
          bloc.add(const StartQhtpSend([], mode: TransportType.bluetooth)),
      expect: () => [
        isA<SenderError>()
            .having((s) => s.code, 'code', FailureCode.nothingSelected),
      ],
    );

    blocTest<SenderBloc, SenderState>(
      'a restart with nothing left to restart names its own reason',
      build: () => SenderBloc(repository: mockRepository),
      act: (bloc) => bloc.add(RestartSession()),
      expect: () => [
        isA<SenderError>()
            .having((s) => s.code, 'code', FailureCode.nothingToRestart),
      ],
    );

    blocTest<SenderBloc, SenderState>(
      'a domain failure hands its code straight through',
      build: () {
        when(() => mockRepository.pickFile()).thenAnswer((_) async =>
            const Left(FileFailure('DioException: closed',
                code: FailureCode.senderUnreachable)));
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) => bloc.add(PickFile()),
      expect: () => [
        isA<SenderError>()
            .having((s) => s.code, 'code', FailureCode.senderUnreachable)
            .having((s) => s.message, 'message', 'DioException: closed'),
      ],
    );

    blocTest<SenderBloc, SenderState>(
      'emits [FileSelected] when pickFile succeeds',
      build: () {
        when(() => mockRepository.pickFile())
            .thenAnswer((_) async => const Right(
                  FileMetadata(
                    name: 'test.txt',
                    path: '/tmp/test.txt',
                    size: 100,
                    mimeType: 'text/plain',
                  ),
                ));
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) => bloc.add(PickFile()),
      expect: () => [isA<FileSelected>()],
    );

    blocTest<SenderBloc, SenderState>(
      'emits [FileSelected] when pickMedia succeeds',
      build: () {
        when(() => mockRepository.pickMedia())
            .thenAnswer((_) async => const Right(
                  FileMetadata(
                    name: 'video.mov',
                    path: '/tmp/video.mov',
                    size: 100,
                    mimeType: 'video/quicktime',
                  ),
                ));
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) => bloc.add(PickMedia()),
      expect: () => [
        const FileSelected(
          FileMetadata(
            name: 'video.mov',
            path: '/tmp/video.mov',
            size: 100,
            mimeType: 'video/quicktime',
          ),
        ),
      ],
      verify: (_) => verify(() => mockRepository.pickMedia()).called(1),
    );

    final testDir =
        Directory.systemTemp.createTempSync('quickshare_test_folder');
    File('${testDir.path}/test_file.txt').writeAsStringSync('hello world');

    blocTest<SenderBloc, SenderState>(
      'emits [ServerStarting, QRReady] when StartQhtpSend succeeds for Wifi mode',
      build: () {
        final dummySession = TransferSession(
          id: 'test_session',
          fileMetadata: const FileMetadata(
            name: 'folder',
            path: '/tmp/folder',
            size: 100,
            mimeType: 'application/octet-stream',
          ),
          serverPort: 8080,
          authToken: 'test_token',
          localIp: '192.168.1.100',
          startedAt: DateTime.now(),
        );
        when(() => mockRepository.startQhtpTransfer(any(),
                authToken: any(named: 'authToken'),
                sessionCode: any(named: 'sessionCode'),
                onIndexProgress: any(named: 'onIndexProgress'),
                onIndexed: any(named: 'onIndexed'),
                onIndexFailed: any(named: 'onIndexFailed')))
            .thenAnswer((_) async => Right(dummySession));
        when(() => mockRepository.generateQRPayload(any())).thenAnswer(
            (_) async => const Right('quickshare://join?room=123456'));
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) =>
          bloc.add(StartQhtpSend([testDir.path], mode: TransportType.wifi)),
      expect: () => [
        isA<ServerStarting>(),
        isA<QRReady>(),
      ],
    );

    blocTest<SenderBloc, SenderState>(
      // An invitation is built from these two fields. Left at their defaults,
      // the other device was asked to accept "1 item, 0 bytes" — the one thing
      // somebody needs in order to decide whether to accept at all.
      'the session tells QRReady how much it is sending',
      build: () {
        final session = TransferSession(
          id: 'test_session',
          fileMetadata: const FileMetadata(
            name: 'Holiday',
            path: '/tmp/Holiday',
            size: 4200000,
            mimeType: 'application/octet-stream',
          ),
          serverPort: 8080,
          authToken: 'test_token',
          localIp: '192.168.1.100',
          startedAt: DateTime.now(),
          isQhtp: true,
          itemCount: 12,
        );
        when(() => mockRepository.startQhtpTransfer(any(),
                authToken: any(named: 'authToken'),
                sessionCode: any(named: 'sessionCode'),
                onIndexProgress: any(named: 'onIndexProgress'),
                onIndexed: any(named: 'onIndexed'),
                onIndexFailed: any(named: 'onIndexFailed')))
            .thenAnswer((_) async => Right(session));
        when(() => mockRepository.generateQRPayload(any())).thenAnswer(
            (_) async => const Right('quickshare://join?room=123456'));
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) =>
          bloc.add(StartQhtpSend([testDir.path], mode: TransportType.wifi)),
      expect: () => [
        isA<ServerStarting>(),
        isA<QRReady>()
            .having((s) => s.itemCount, 'itemCount', 12)
            .having((s) => s.totalBytes, 'totalBytes', 4200000),
      ],
    );

    blocTest<SenderBloc, SenderState>(
      // The receiver's socket read only fails fast if the server is torn
      // down forced — see [LocalHttpServer.stop]. A plain stopServer() here
      // used to leave an active download's stream blocked on a 30-second
      // idle timeout before it ever noticed the sender was gone.
      'CancelSending force-closes the server rather than closing it gracefully',
      build: () => SenderBloc(repository: mockRepository),
      act: (bloc) => bloc.add(CancelSending()),
      verify: (_) =>
          verify(() => mockRepository.stopServer(force: true)).called(1),
    );

    // Everything below exercises the transfer-history record a completed,
    // cancelled, or failed Wi-Fi send leaves behind — the "Recent Transfers"
    // list on the settings screen reads exactly this file back.
    late Directory diagDir;
    late TransferDiagnostics diagnostics;
    late _RecordingPeerLink peerLink;
    late StreamController<double> progress;

    setUp(() {
      // Bound to the folder made *here*, not to the variable that the next
      // test's setUp reassigns: a report written late by one test used to
      // land in the following test's folder and be read there as its own.
      final folder =
          Directory.systemTemp.createTempSync('quickshare_diag_test_');
      diagDir = folder;
      diagnostics = TransferDiagnostics(overrideDir: () => folder);
      peerLink = _RecordingPeerLink();
      progress = StreamController<double>.broadcast();
      when(() => mockRepository.transferProgress)
          .thenAnswer((_) => progress.stream);
    });

    tearDown(() async {
      await progress.close();
      if (await diagDir.exists()) await diagDir.delete(recursive: true);
    });

    TransferSession wifiSession({int size = 123456789}) => TransferSession(
          id: 'diag-session',
          fileMetadata: FileMetadata(
            name: '3 items',
            path: '/tmp/folder',
            size: size,
            mimeType: 'application/octet-stream',
          ),
          serverPort: 8000,
          authToken: 'diag-token',
          localIp: '192.168.1.50',
          startedAt: DateTime.now(),
        );

    blocTest<SenderBloc, SenderState>(
      // `_sessionFiles` is only ever populated on the Bluetooth/internet
      // branch, which flattens folders itself; QHTP indexes server-side, so
      // a plain Wi-Fi send left it null and the report recorded 0 bytes for
      // a transfer that moved 123 MB. The total has to come from the
      // session the server actually opened instead.
      'a completed Wi-Fi send records its real byte count and both addresses '
      '— not zero bytes and a guessed route',
      build: () {
        when(() => mockRepository.startQhtpTransfer(any(),
                authToken: any(named: 'authToken'),
                sessionCode: any(named: 'sessionCode'),
                onIndexProgress: any(named: 'onIndexProgress'),
                onIndexed: any(named: 'onIndexed'),
                onIndexFailed: any(named: 'onIndexFailed')))
            .thenAnswer((_) async => Right(wifiSession()));
        when(() => mockRepository.generateQRPayload(any()))
            .thenAnswer((_) async => const Right('qr-payload'));
        when(() => mockRepository.lastQhtpClientAddress)
            .thenReturn(InternetAddress('192.168.1.77'));
        return SenderBloc(repository: mockRepository, diagnostics: diagnostics);
      },
      act: (bloc) async {
        // Each step waits for the state the bloc reaches because of the one
        // before. `TransferComplete` is emitted after the report is written,
        // so by the time it is seen the history can be read.
        await _startWifiSend(bloc);
        final moving = _next<Transferring>(bloc);
        progress.add(0.4);
        await moving;
        final done = _next<TransferComplete>(bloc);
        progress.add(1.0);
        await done;
      },
      verify: (_) async {
        final recorded = await diagnostics.recent();
        expect(recorded, isNotEmpty);
        final report = recorded.first;
        expect(report.succeeded, isTrue);
        expect(report.bytes, 123456789);
        expect(report.route, TransferRoute.localNetwork,
            reason: 'a real (non-loopback) client address means the plain '
                'network carried it, not the direct link');
        expect(report.peerAddress, '192.168.1.77');
        expect(report.localAddress, '192.168.1.50:8000');
      },
    );

    // Failure reports must show observed progress, not the total advertised
    // in a manifest. In particular, an ICE failure can occur before even
    // one byte is put on the wire.
    for (final progressFraction in <double>[0.0, 0.25]) {
      blocTest<SenderBloc, SenderState>(
        'a failed Wi-Fi transfer reports only its observed progress '
        '($progressFraction)',
        build: () {
          when(() => mockRepository.startQhtpTransfer(any(),
                  authToken: any(named: 'authToken'),
                  sessionCode: any(named: 'sessionCode'),
                  onIndexProgress: any(named: 'onIndexProgress'),
                  onIndexed: any(named: 'onIndexed'),
                  onIndexFailed: any(named: 'onIndexFailed')))
              .thenAnswer((_) async => Right(wifiSession(size: 100000)));
          when(() => mockRepository.generateQRPayload(any()))
              .thenAnswer((_) async => const Right('qr-payload'));
          return SenderBloc(
              repository: mockRepository, diagnostics: diagnostics);
        },
        act: (bloc) async {
          await _startWifiSend(bloc);
          // The progress has been seen when the bloc shows it. Nothing is
          // reported before that, so the failure below cannot overtake it.
          final moving = _next<Transferring>(bloc);
          progress.add(progressFraction);
          await moving;
          final ended = _next<SenderError>(bloc);
          bloc.add(const TransferFailed('connection lost'));
          await ended;
        },
        verify: (_) async {
          final recorded = await diagnostics.recent();
          expect(recorded, isNotEmpty);
          expect(recorded.first.succeeded, isFalse);
          expect(recorded.first.bytes, (progressFraction * 100000).round());
        },
      );
    }

    blocTest<SenderBloc, SenderState>(
      // A Wi-Fi send goes over the router or it does not go. The direct link
      // used to be offered here too, silently, so a session on a network that
      // isolates its clients still completed — over a route the transport the
      // user picked does not describe. It belongs to the Bluetooth fast path,
      // where it is the whole point, and nowhere else.
      'a Wi-Fi send raises no direct link of its own',
      build: () {
        when(() => mockRepository.startQhtpTransfer(any(),
                authToken: any(named: 'authToken'),
                sessionCode: any(named: 'sessionCode'),
                onIndexProgress: any(named: 'onIndexProgress'),
                onIndexed: any(named: 'onIndexed'),
                onIndexFailed: any(named: 'onIndexFailed')))
            .thenAnswer((_) async => Right(wifiSession()));
        when(() => mockRepository.generateQRPayload(any()))
            .thenAnswer((_) async => const Right('qr-payload'));
        return SenderBloc(
          repository: mockRepository,
          diagnostics: diagnostics,
          peerLinkService: peerLink,
        );
      },
      // The offer on screen is the end of the start-up: the server is up and
      // the QR is built, and a link raised on the way would have been raised
      // before it. Nothing more is going to happen, so there is nothing more
      // to wait for.
      act: _startWifiSend,
      verify: (_) async {
        expect(peerLink.hosted, isEmpty,
            reason: 'the QR names the LAN address and that is the only route '
                'a Wi-Fi session offers');
      },
    );

    blocTest<SenderBloc, SenderState>(
      // The Wi-Fi flow no longer raises a link of its own, so this pairing of
      // inputs is synthetic: in the app a loopback client can only be the
      // fast path offered beside a Bluetooth transfer. What is under test is
      // the labelling itself — that it reads the address the far side
      // actually connected from, and never assumes the plain network.
      'a loopback client is labelled the direct link, whatever raised it',
      build: () {
        when(() => mockRepository.startQhtpTransfer(any(),
                authToken: any(named: 'authToken'),
                sessionCode: any(named: 'sessionCode'),
                onIndexProgress: any(named: 'onIndexProgress'),
                onIndexed: any(named: 'onIndexed'),
                onIndexFailed: any(named: 'onIndexFailed')))
            .thenAnswer((_) async => Right(wifiSession()));
        when(() => mockRepository.generateQRPayload(any()))
            .thenAnswer((_) async => const Right('qr-payload'));
        // Loopback is what the receiver's dio connects to when it goes
        // through the peer-link bridge instead of the plain LAN address —
        // the one fact that used to be guessed from whether hosting merely
        // succeeded, which says nothing about which route the receiver
        // actually took.
        when(() => mockRepository.lastQhtpClientAddress)
            .thenReturn(InternetAddress.loopbackIPv4);
        return SenderBloc(repository: mockRepository, diagnostics: diagnostics);
      },
      act: (bloc) async {
        await _startWifiSend(bloc);
        final done = _next<TransferComplete>(bloc);
        progress.add(1.0);
        await done;
      },
      verify: (_) async {
        final recorded = await diagnostics.recent();
        expect(recorded, isNotEmpty);
        expect(recorded.first.route, TransferRoute.directWifiLink);
      },
    );

    blocTest<SenderBloc, SenderState>(
      // Cancelling mid-transfer used to leave no trace at all: `_reportSend`
      // was only ever called from the completion path. A cancelled send is
      // still a fact worth a line in the history, with a real reason instead
      // of the screen simply going back to the start as if nothing had run.
      'cancelling mid-transfer still leaves a record, not silence',
      build: () {
        when(() => mockRepository.startQhtpTransfer(any(),
                authToken: any(named: 'authToken'),
                sessionCode: any(named: 'sessionCode'),
                onIndexProgress: any(named: 'onIndexProgress'),
                onIndexed: any(named: 'onIndexed'),
                onIndexFailed: any(named: 'onIndexFailed')))
            .thenAnswer((_) async => Right(wifiSession()));
        when(() => mockRepository.generateQRPayload(any()))
            .thenAnswer((_) async => const Right('qr-payload'));
        when(() => mockRepository.lastQhtpClientAddress)
            .thenReturn(InternetAddress('192.168.1.77'));
        // Cancelling lets go of whatever network the send used. Where the
        // platform can host a hotspot (Android, Windows, Linux) the real
        // service asks the native side to stop it, and a test has no native
        // side: the call would come back as a missing plugin, long after the
        // test, as an error of its own. The record is what is under test.
        final hotspot = _MockLocalHotspotService();
        when(() => hotspot.stopHosting()).thenAnswer((_) async {});
        when(() => hotspot.leaveNetwork()).thenAnswer((_) async {});
        return SenderBloc(
            repository: mockRepository,
            diagnostics: diagnostics,
            hotspotService: hotspot);
      },
      act: (bloc) async {
        await _startWifiSend(bloc);
        // A receiver has to have actually started pulling bytes for this to
        // count as a transfer worth recording — an untouched QR the user
        // dismisses is not a failed transfer, it is a change of mind.
        final moving = _next<Transferring>(bloc);
        progress.add(0.2);
        await moving;
        // The screen goes back to the start only after the record is filed.
        final over = _next<SenderInitial>(bloc);
        bloc.add(CancelSending());
        await over;
      },
      verify: (_) async {
        final recorded = await diagnostics.recent();
        expect(recorded, isNotEmpty);
        final report = recorded.first;
        expect(report.succeeded, isFalse);
        expect(report.peerAddress, '192.168.1.77');
      },
    );

    test('guest teardown invokes leaveNetwork on cancel', () async {
      final mockHotspot = _MockLocalHotspotService();
      final left = Completer<void>();
      when(() => mockHotspot.stopHosting()).thenAnswer((_) async {});
      when(() => mockHotspot.leaveNetwork()).thenAnswer((_) async {
        if (!left.isCompleted) left.complete();
      });

      final bloc = SenderBloc(
        repository: mockRepository,
        hotspotService: mockHotspot,
      );

      bloc.setJoinedAsGuestForTesting(true);
      expect(bloc.joinedAsGuestForTesting, isTrue);

      bloc.add(CancelSending());
      await _within(left.future);

      expect(bloc.joinedAsGuestForTesting, isFalse);
      verify(() => mockHotspot.leaveNetwork()).called(1);
      await bloc.close();
    });

    test('guest teardown invokes leaveNetwork on completion and failure',
        () async {
      final mockHotspot = _MockLocalHotspotService();
      var left = Completer<void>();
      when(() => mockHotspot.stopHosting()).thenAnswer((_) async {});
      when(() => mockHotspot.leaveNetwork()).thenAnswer((_) async {
        if (!left.isCompleted) left.complete();
      });

      final bloc = SenderBloc(
        repository: mockRepository,
        hotspotService: mockHotspot,
      );

      bloc.setJoinedAsGuestForTesting(true);
      bloc.add(TransferCompleted());
      await _within(left.future);

      expect(bloc.joinedAsGuestForTesting, isFalse);
      verify(() => mockHotspot.leaveNetwork()).called(1);

      left = Completer<void>();
      bloc.setJoinedAsGuestForTesting(true);
      bloc.add(const TransferFailed('failed'));
      await _within(left.future);

      expect(bloc.joinedAsGuestForTesting, isFalse);
      verify(() => mockHotspot.leaveNetwork()).called(1);
      await bloc.close();
    });

    test('auto-declines invite approval when state is not QRReady', () async {
      final declined = Completer<void>();
      when(() => mockRepository.respondToApproval(any(), any()))
          .thenAnswer((_) {
        if (!declined.isCompleted) declined.complete();
      });

      final bloc = SenderBloc(
        repository: mockRepository,
      );

      final req = TransferApprovalRequest(
        id: 'test-req-id',
        remoteAddress: InternetAddress.loopbackIPv4,
        deviceName: 'Pixel',
        itemCount: 1,
        totalBytes: 100,
      );

      bloc.add(InviteApprovalReceived(req));
      await _within(declined.future);

      verify(() => mockRepository.respondToApproval('test-req-id', false))
          .called(1);
      await bloc.close();
    });

    // B3 — sender_bloc.dart:643-654 (_onInviteApprovalReceived). The plain
    // `test` above pins the regression from 47c4919 (an approval arriving off
    // QRReady must not sit for 90s); these two blocTest cases pin both halves
    // of the branch it lives in, in the idiom the rest of this file uses.
    blocTest<SenderBloc, SenderState>(
      // B3(a) — on QRReady, an approval request must surface the dialog
      // state rather than being silently auto-declined.
      'B3(a): QRReady + InviteApprovalReceived emits InviteApprovalRequested',
      seed: () => QRReady(
        'qr-data',
        TransferSession(
          id: 'seeded-session',
          fileMetadata: const FileMetadata(
            name: 'seeded.txt',
            path: '/tmp/seeded.txt',
            size: 10,
            mimeType: 'text/plain',
          ),
          serverPort: 8000,
          authToken: 'seed-token',
          localIp: '192.168.1.10',
          startedAt: DateTime.now(),
        ),
        TransportType.wifi,
      ),
      build: () => SenderBloc(repository: mockRepository),
      act: (bloc) => bloc.add(InviteApprovalReceived(TransferApprovalRequest(
        id: 'req-a',
        remoteAddress: InternetAddress.loopbackIPv4,
        deviceName: 'Pixel',
        itemCount: 2,
        totalBytes: 4096,
      ))),
      expect: () => [
        isA<InviteApprovalRequested>()
            .having((s) => s.request.id, 'request.id', 'req-a')
            .having((s) => s.previousState, 'previousState', isA<QRReady>()),
      ],
      verify: (_) {
        // Accepted onto the dialog, not auto-declined behind the scenes.
        verifyNever(() => mockRepository.respondToApproval(any(), any()));
      },
    );

    blocTest<SenderBloc, SenderState>(
      // B3(b) — the same event, off QRReady (mid-transfer here rather than
      // the default initial state, so this is not just a copy of the plain
      // test above): no dialog state, and the request is declined through
      // the repository instead of being left to expire after 90s.
      'B3(b): a state other than QRReady + InviteApprovalReceived does NOT '
      'emit InviteApprovalRequested, and declines via the repository',
      seed: () => const Transferring(0.5, 1000),
      build: () {
        when(() => mockRepository.respondToApproval(any(), any()))
            .thenReturn(null);
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) => bloc.add(InviteApprovalReceived(TransferApprovalRequest(
        id: 'req-b',
        remoteAddress: InternetAddress.loopbackIPv4,
        deviceName: 'Pixel',
        itemCount: 1,
        totalBytes: 100,
      ))),
      expect: () => <SenderState>[],
      verify: (_) {
        verify(() => mockRepository.respondToApproval('req-b', false))
            .called(1);
      },
    );
  });
}

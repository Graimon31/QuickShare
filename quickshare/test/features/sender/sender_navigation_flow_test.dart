import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/features/sender/presentation/pages/network_fallback_page.dart';
import 'package:quickshare/features/sender/presentation/pages/qr_display_page.dart';
import 'package:quickshare/features/sender/presentation/pages/sender_progress_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/widgets/progress_indicator_widget.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

class MockSenderRepository extends Mock implements SenderRepository {}
class _MockLocalHotspotService extends Mock implements LocalHotspotService {}

class _RecordingPeerLink extends PeerLinkService {
  @override
  bool get supported => true;

  @override
  Future<void> host({
    required String serviceName,
    required int localPort,
    Duration timeout = const Duration(seconds: 5),
  }) async {}

  @override
  Future<void> stop() async {}
}

void main() {
  late MockSenderRepository mockRepository;
  late StreamController<TransferApprovalRequest> approvalController;

  setUpAll(() {
    registerFallbackValue(TransferSession(
      id: 'flow-test-session',
      fileMetadata: const FileMetadata(
        name: 'flow-test.txt',
        path: '/tmp/flow-test.txt',
        size: 1024,
        mimeType: 'text/plain',
      ),
      serverPort: 8080,
      authToken: 'flow-token',
      localIp: '127.0.0.1',
      startedAt: DateTime.now(),
    ));
  });

  TransferSession testSession() => TransferSession(
        id: 'session-nav-1',
        fileMetadata: const FileMetadata(
          name: 'project_notes.pdf',
          path: '/tmp/project_notes.pdf',
          size: 2048,
          mimeType: 'application/pdf',
        ),
        serverPort: 8000,
        authToken: 'token-nav-1',
        localIp: '192.168.1.100',
        startedAt: DateTime.now(),
        isQhtp: true,
        itemCount: 1,
      );

  setUp(() {
    mockRepository = MockSenderRepository();
    approvalController = StreamController<TransferApprovalRequest>.broadcast();

    when(() => mockRepository.transferProgress)
        .thenAnswer((_) => const Stream.empty());
    when(() => mockRepository.statusStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => mockRepository.approvalRequests)
        .thenAnswer((_) => approvalController.stream);
    when(() => mockRepository.respondToApproval(any(), any())).thenReturn(null);
    when(() => mockRepository.stopServer(force: any(named: 'force')))
        .thenAnswer((_) async => const Right(null));
    when(() => mockRepository.stopServer())
        .thenAnswer((_) async => const Right(null));
    when(() => mockRepository.startQhtpTransfer(
          any(),
          authToken: any(named: 'authToken'),
          sessionPublicId: any(named: 'sessionPublicId'),
          onIndexProgress: any(named: 'onIndexProgress'),
          onIndexed: any(named: 'onIndexed'),
          onIndexFailed: any(named: 'onIndexFailed'),
        )).thenAnswer((_) async => Right(testSession()));
    when(() => mockRepository.generateQRPayload(any()))
        .thenAnswer((_) async => const Right('qr-flow-payload'));
  });

  tearDown(() async {
    await approvalController.close();
  });

  SenderBloc createTestBloc() {
    final mockHotspot = _MockLocalHotspotService();
    when(() => mockHotspot.leaveNetwork()).thenAnswer((_) async => true);
    when(() => mockHotspot.stopHosting()).thenAnswer((_) async {});
    return SenderBloc(
      repository: mockRepository,
      peerLinkService: _RecordingPeerLink(),
      hotspotService: mockHotspot,
    );
  }

  Widget wrapWithRouterAndBloc(Widget child, SenderBloc bloc) {
    final router = GoRouter(
      initialLocation: '/current',
      routes: [
        GoRoute(
          path: '/current',
          builder: (_, __) => child,
        ),
        GoRoute(
          path: '/send',
          builder: (_, __) => const Scaffold(body: Text('send_page')),
        ),
        GoRoute(
          path: '/send/progress',
          builder: (_, __) => const Scaffold(body: Text('progress_page')),
        ),
      ],
    );

    return BlocProvider<SenderBloc>.value(
      value: bloc,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
  }

  group('Sender Navigation & UI Flow', () {
    testWidgets(
        'QRDisplayPage renders QrImageView and cancel button in QRReady state',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final bloc = createTestBloc();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester.pumpWidget(wrapWithRouterAndBloc(const QRDisplayPage(), bloc));

      bloc.add(const StartQhtpSend(['/tmp/project_notes.pdf'], mode: TransportType.wifi));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(bloc.state, isA<QRReady>());
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.byType(OutlinedButton), findsOneWidget);
    });

    testWidgets(
        'a session that fails after the QR route is entered leaves the screen',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // The server comes up, the QR route is entered, and only then does the
      // session end — an unreadable selection here, but a dropped server or a
      // certificate that never arrived look identical from this page: the
      // state leaves QRReady and never returns to it.
      when(() => mockRepository.startQhtpTransfer(
            any(),
            authToken: any(named: 'authToken'),
            sessionPublicId: any(named: 'sessionPublicId'),
            onIndexProgress: any(named: 'onIndexProgress'),
            onIndexed: any(named: 'onIndexed'),
            onIndexFailed: any(named: 'onIndexFailed'),
          )).thenAnswer((invocation) async {
        final onIndexFailed = invocation.namedArguments[#onIndexFailed]
            as void Function(Object)?;
        onIndexFailed?.call(Exception('the selection could not be read'));
        return Right(testSession());
      });

      final bloc = createTestBloc();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester
          .pumpWidget(wrapWithRouterAndBloc(const QRDisplayPage(), bloc));

      bloc.add(const StartQhtpSend(['/tmp/project_notes.pdf'],
          mode: TransportType.wifi));
      // Long enough for the route transition to finish as well as the
      // session to fail: while it is still animating both pages are in the
      // tree, and the old one's spinner is still findable.
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(bloc.state, isA<SenderError>());
      // Every state that is not QRReady draws "Preparing share...", and
      // SenderError was the one this page's listener never handled. So a
      // dead session kept a spinner turning with no way forward and no way
      // to tell it apart from a slow one.
      expect(find.byType(TransferPhaseLoader), findsNothing);
      expect(find.text('send_page'), findsOneWidget);
    });

    testWidgets(
        'QRDisplayPage cancel button triggers CancelSending on SenderBloc',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final bloc = createTestBloc();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester.pumpWidget(wrapWithRouterAndBloc(const QRDisplayPage(), bloc));

      bloc.add(const StartQhtpSend(['/tmp/project_notes.pdf'], mode: TransportType.wifi));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(bloc.state, isA<QRReady>());
      final cancelButton = find.byType(OutlinedButton);
      expect(cancelButton, findsOneWidget);

      await tester.ensureVisible(cancelButton);
      await tester.tap(cancelButton);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      verify(() => mockRepository.stopServer(force: any(named: 'force')))
          .called(greaterThanOrEqualTo(1));
    });

    testWidgets(
        'SenderProgressPage renders CustomProgressIndicator during Transferring state',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final bloc = createTestBloc();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester.pumpWidget(
          wrapWithRouterAndBloc(const SenderProgressPage(), bloc));

      bloc.emit(const Transferring(0.45, 1048576));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(CustomProgressIndicator), findsOneWidget);
      final indicator =
          tester.widget<CustomProgressIndicator>(find.byType(CustomProgressIndicator));
      expect(indicator.progress, 0.45);
      expect(indicator.speedBytesPerSec, 1048576.0);
    });

    testWidgets(
        'SenderProgressPage renders completion checkmark and send another button on TransferComplete',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final bloc = createTestBloc();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester.pumpWidget(
          wrapWithRouterAndBloc(const SenderProgressPage(), bloc));

      bloc.emit(const TransferComplete(FileMetadata(
        name: 'vacation.zip',
        path: '/tmp/vacation.zip',
        size: 5000000,
        mimeType: 'application/zip',
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(find.text('vacation.zip'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
    });

    testWidgets(
        'SenderProgressPage renders error details on SenderError state',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final bloc = createTestBloc();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester.pumpWidget(
          wrapWithRouterAndBloc(const SenderProgressPage(), bloc));

      bloc.emit(const SenderError(
        'Network path unreachable',
        code: FailureCode.networkCreateFailed,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(TransferPhaseLoader), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });

    testWidgets(
        'NetworkFallbackPage renders size-limited layout when limit is exceeded',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      var localNetworkTapped = false;

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NetworkFallbackPage(
          sessionBytes: 75 * 1024 * 1024, // 75 MB
          limitBytes: 50 * 1024 * 1024,   // 50 MB
          onUseLocalNetwork: () => localNetworkTapped = true,
        ),
      ));

      expect(find.byIcon(Icons.speed_rounded), findsOneWidget);
      final textButton = find.byType(TextButton);
      expect(textButton, findsOneWidget);

      await tester.ensureVisible(textButton);
      await tester.tap(textButton);
      await tester.pump();
      expect(localNetworkTapped, isTrue);
    });

    testWidgets(
        'NetworkFallbackPage renders no-route guidance and creation button when can host',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      var createNetworkTapped = false;

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NetworkFallbackPage(
          onCreateNetwork: () => createNetworkTapped = true,
        ),
      ));

      expect(find.byIcon(Icons.vpn_lock_rounded), findsOneWidget);
      expect(find.byIcon(Icons.wifi_tethering_rounded), findsOneWidget);
      final filledButton = find.byType(FilledButton);
      expect(filledButton, findsOneWidget);

      await tester.ensureVisible(filledButton);
      await tester.tap(filledButton);
      await tester.pump();
      expect(createNetworkTapped, isTrue);
    });
  });
}

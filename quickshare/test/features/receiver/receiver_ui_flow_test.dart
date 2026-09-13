import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_announcer.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/receiver/presentation/pages/complete_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/download_progress_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/transfer_preview_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/shared/widgets/progress_indicator_widget.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

class _FakeWakelockPlusPlatform extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

class _MockDownloadFileUseCase extends Mock implements DownloadFileUseCase {}
class _MockReceiverRepository extends Mock implements ReceiverRepository {}
class _MockBluetoothReceiverAnnouncer extends Mock
    implements BluetoothReceiverAnnouncer {}

class _TestReceiverBloc extends ReceiverBloc {
  _TestReceiverBloc({
    required super.downloadFileUseCase,
    required super.repository,
  }) : super(
          bluetoothAnnouncerFactory: ({onServeReceived}) {
            final mock = _MockBluetoothReceiverAnnouncer();
            when(() => mock.start()).thenAnswer((_) async {});
            when(() => mock.stop()).thenAnswer((_) async {});
            when(() => mock.detachForTransfer()).thenAnswer((_) async {});
            when(() => mock.isActive).thenReturn(false);
            return mock;
          },
        );

  final List<ReceiverEvent> recordedEvents = [];

  @override
  void add(ReceiverEvent event) {
    recordedEvents.add(event);
    if (event is StartDownload) {
      return; // Do not execute actual network download in widget tests
    }
    super.add(event);
  }
}

void main() {
  setUpAll(() {
    wakelockPlusPlatformInstance = _FakeWakelockPlusPlatform();
  });

  const testPayload = QRPayload(
    version: 2,
    ip: '192.168.1.55',
    port: 8080,
    token: 'test-rec-token',
    fileName: 'Vacation Photos',
    fileSize: 10485760, // 10 MB
    itemCount: 8,
    mode: 'http-lan',
    tlsFingerprint: 'dummy-cert-fingerprint',
  );

  Widget wrapWithRouterAndBloc({
    required Widget child,
    required ReceiverBloc bloc,
    String initialLocation = '/current',
  }) {
    final router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/current',
          builder: (_, __) => child,
        ),
        GoRoute(
          path: '/receive/preview',
          builder: (_, __) => const TransferPreviewPage(),
        ),
        GoRoute(
          path: '/receive/download',
          builder: (_, __) => const DownloadProgressPage(),
        ),
        GoRoute(
          path: '/receive',
          builder: (_, __) => const Scaffold(body: Text('scanner_page')),
        ),
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('home_page')),
        ),
      ],
    );

    return BlocProvider<ReceiverBloc>.value(
      value: bloc,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
  }

  group('Receiver Navigation & UI Flow', () {
    testWidgets(
        'TransferPreviewPage displays folder icon, item count and receive button for QHTP session',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final bloc = _TestReceiverBloc(
        downloadFileUseCase: _MockDownloadFileUseCase(),
        repository: _MockReceiverRepository(),
      );
      bloc.emit(const QRParsed(testPayload));

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester.pumpWidget(wrapWithRouterAndBloc(
        child: const TransferPreviewPage(),
        bloc: bloc,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byIcon(Icons.folder_rounded), findsOneWidget);
      expect(find.text('Vacation Photos'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsOneWidget);
      expect(find.byType(OutlinedButton), findsOneWidget);
    });

    testWidgets(
        'TransferPreviewPage displays Bluetooth icon, sender name, and receive button for Bluetooth session',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const btPayload = QRPayload(
        version: 2,
        ip: 'bt',
        port: 0,
        token: 'test-bt-token',
        sessionId: 'cid-pub-123',
        fileName: 'ProjectArchive.zip',
        fileSize: 52428800, // 50 MB
        itemCount: 1,
        mode: 'bluetooth',
        senderName: 'MacBook Pro — Mr.Graimon',
      );

      final bloc = _TestReceiverBloc(
        downloadFileUseCase: _MockDownloadFileUseCase(),
        repository: _MockReceiverRepository(),
      );
      bloc.emit(const QRParsed(btPayload));

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester.pumpWidget(wrapWithRouterAndBloc(
        child: const TransferPreviewPage(),
        bloc: bloc,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byIcon(Icons.bluetooth_rounded), findsOneWidget);
      expect(find.text('ProjectArchive.zip'), findsOneWidget);
      expect(find.textContaining('MacBook Pro — Mr.Graimon'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsOneWidget);
      expect(find.byType(OutlinedButton), findsOneWidget);

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(bloc.recordedEvents.any((e) => e is StartDownload && e.payload == btPayload), isTrue);
      expect(find.byType(DownloadProgressPage), findsOneWidget);
    });

    testWidgets(
        'TransferPreviewPage cancel button adds CancelDownload and navigates home',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final bloc = _TestReceiverBloc(
        downloadFileUseCase: _MockDownloadFileUseCase(),
        repository: _MockReceiverRepository(),
      );
      bloc.emit(const QRParsed(testPayload));

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester.pumpWidget(wrapWithRouterAndBloc(
        child: const TransferPreviewPage(),
        bloc: bloc,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final cancelButton = find.byType(OutlinedButton);
      expect(cancelButton, findsOneWidget);

      await tester.tap(cancelButton);
      await tester.pumpAndSettle();

      expect(bloc.recordedEvents.any((e) => e is CancelDownload), isTrue);
      expect(find.text('home_page'), findsOneWidget);
    });

    testWidgets(
        'DownloadProgressPage renders CustomProgressIndicator during Downloading state',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final bloc = _TestReceiverBloc(
        downloadFileUseCase: _MockDownloadFileUseCase(),
        repository: _MockReceiverRepository(),
      );
      bloc.emit(const Downloading(0.65, 2097152, 'archive.tar'));

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester.pumpWidget(wrapWithRouterAndBloc(
        child: const DownloadProgressPage(),
        bloc: bloc,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(CustomProgressIndicator), findsOneWidget);
      final indicator =
          tester.widget<CustomProgressIndicator>(find.byType(CustomProgressIndicator));
      expect(indicator.progress, 0.65);
      expect(indicator.fileName, 'archive.tar');
    });

    testWidgets(
        'DownloadProgressPage renders TransferPhaseLoader during Connecting and Verifying states',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final bloc = _TestReceiverBloc(
        downloadFileUseCase: _MockDownloadFileUseCase(),
        repository: _MockReceiverRepository(),
      );
      bloc.emit(Connecting());

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await bloc.close();
      });

      await tester.pumpWidget(wrapWithRouterAndBloc(
        child: const DownloadProgressPage(),
        bloc: bloc,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(TransferPhaseLoader), findsOneWidget);
      expect(find.byIcon(Icons.link_rounded), findsOneWidget);

      bloc.emit(Verifying());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(TransferPhaseLoader), findsOneWidget);
      expect(find.byIcon(Icons.verified_outlined), findsOneWidget);
    });

    testWidgets(
        'CompletePage renders checkmark, received item list, and Done button when placed',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final items = [
        const ReceivedItem(
          cachePath: '/tmp/cache/doc1.pdf',
          name: 'doc1.pdf',
          size: 1024,
          mimeType: 'application/pdf',
          savedPath: '/downloads/doc1.pdf',
        ),
        const ReceivedItem(
          cachePath: '/tmp/cache/doc2.pdf',
          name: 'doc2.pdf',
          size: 2048,
          mimeType: 'application/pdf',
          savedPath: '/downloads/doc2.pdf',
        ),
      ];

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CompletePage(
          fileName: 'documents.zip',
          filePath: '/downloads/documents.zip',
          items: items,
          placed: true,
        ),
      ));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(find.text('doc1.pdf'), findsOneWidget);
      expect(find.text('doc2.pdf'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
    });
  });
}

// Scanning a code says which device to talk to. It does not say yes.
//
// DD-18. The preview screen showed what was being sent and started sending it
// a second and a bit later, on a timer — so the size and the item count on it
// were decoration, read after the fact if at all. Every other way in asks
// first: the device list waits for a tap, the typed code waits for a button.
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/features/receiver/domain/entities/qhtp_session_preview.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/receiver/presentation/pages/transfer_preview_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class _MockDownloadFileUseCase extends Mock implements DownloadFileUseCase {}

class _MockReceiverRepository extends Mock implements ReceiverRepository {}

/// A bloc already holding a parsed session, which is the state the preview
/// screen is opened in.
class _ParsedBloc extends ReceiverBloc {
  _ParsedBloc({required super.downloadFileUseCase, required super.repository});

  final started = <QRPayload>[];

  @override
  void add(ReceiverEvent event) {
    if (event is StartDownload && event.payload != null) {
      started.add(event.payload!);
      return; // Recorded, not run: nothing here should reach the network.
    }
    super.add(event);
  }
}

void main() {
  const payload = QRPayload(
    version: 2,
    ip: '192.168.3.5',
    port: 8000,
    token: 'session-token',
    fileName: 'Holiday',
    fileSize: 4200000,
    itemCount: 12,
    mode: 'http-lan',
    tlsFingerprint: 'sender-cert',
  );

  late _ParsedBloc bloc;

  setUp(() {
    bloc = _ParsedBloc(
      downloadFileUseCase: _MockDownloadFileUseCase(),
      repository: _MockReceiverRepository(),
    );
    bloc.emit(const QRParsed(payload));
  });

  tearDown(() => bloc.close());

  /// Agreeing navigates, so the screen needs somewhere to navigate to.
  Widget underTest() {
    final router = GoRouter(
      initialLocation: '/receive/preview',
      routes: [
        GoRoute(
          path: '/receive/preview',
          builder: (_, __) => const TransferPreviewPage(),
        ),
        GoRoute(
          path: '/receive/download',
          builder: (_, __) => const Scaffold(body: Text('downloading')),
        ),
        GoRoute(
          path: '/receive',
          builder: (_, __) => const Scaffold(body: Text('scanner')),
        ),
        GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('home'))),
      ],
    );
    addTearDown(router.dispose);

    return BlocProvider<ReceiverBloc>.value(
      value: bloc,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
  }

  testWidgets('waiting does not start the transfer', (tester) async {
    await tester.pumpWidget(underTest());
    await tester.pump(); // the post-frame read of the bloc's state

    // Comfortably past the second-and-a-bit the timer used to wait.
    await tester.pump(const Duration(seconds: 5));

    expect(bloc.started, isEmpty,
        reason: 'nobody agreed to anything yet');
  });

  testWidgets('what is on offer is readable before agreeing', (tester) async {
    // The numbers are the point of the screen: they are what the person is
    // being asked about.
    await tester.pumpWidget(underTest());
    await tester.pump();

    expect(find.text('Holiday'), findsOneWidget);
    expect(find.textContaining('4'), findsWidgets);
  });

  testWidgets('agreeing starts it, with the session that was shown',
      (tester) async {
    await tester.pumpWidget(underTest());
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.codeReceiveReceiveButton));
    await tester.pumpAndSettle();

    expect(bloc.started.single, equals(payload));
  });

  testWidgets('shows sender name when available from preview', (tester) async {
    bloc.emit(const QRParsed(
      payload,
      qhtpPreview: QhtpSessionPreview(
        itemCount: 12,
        totalBytes: 4200000,
        senderName: 'Alice iPhone',
      ),
    ));

    await tester.pumpWidget(underTest());
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.previewSenderLabel('Alice iPhone')), findsOneWidget);
  });
}

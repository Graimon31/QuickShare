// B2 — the `_ApprovalDialog` shown from qr_display_page.dart once the sender
// receives an `InviteApprovalRequested` state.
//
// The server-side 90s auto-decline is covered from the wire side by
// invite_security_test.dart ("declines when approver does not answer in
// time"), but nothing exercised the sender's own screen: the dialog text,
// its countdown, and what Accept/Decline/timeout actually send back to the
// bloc. `_ApprovalDialog` is private to qr_display_page.dart, so the only way
// to reach it is through the real `QRDisplayPage`, wired to a real
// `SenderBloc` over a mocked `SenderRepository` — the same double
// sender_bloc_test.dart uses. Each test drives the bloc to `QRReady` and then
// pushes a `TransferApprovalRequest` through the repository's
// `approvalRequests` stream, exactly the path a real receiver's LAN
// code-entry request takes in production (see local_http_server.dart).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/features/sender/presentation/pages/qr_display_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

class MockSenderRepository extends Mock implements SenderRepository {}

void main() {
  late MockSenderRepository mockRepository;
  late StreamController<TransferApprovalRequest> approvalController;
  late SenderBloc bloc;

  setUpAll(() {
    registerFallbackValue(TransferSession(
      id: 'fallback-session',
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
  });

  TransferSession session() => TransferSession(
        id: 'approval-test-session',
        fileMetadata: const FileMetadata(
          name: 'Holiday photos',
          path: '/tmp/Holiday photos',
          size: 1500000,
          mimeType: 'application/octet-stream',
        ),
        serverPort: 8000,
        authToken: 'approval-test-token',
        localIp: '192.168.1.50',
        startedAt: DateTime.now(),
        isQhtp: true,
        itemCount: 3,
      );

  final req = TransferApprovalRequest(
    id: 'approval-req-1',
    remoteAddress: InternetAddress('192.168.1.77'),
    deviceName: 'Pixel 8',
    code: '1234567890',
    itemCount: 3,
    totalBytes: 1500000,
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
    when(() => mockRepository.respondToApproval(any(), any()))
        .thenReturn(null);
    when(() => mockRepository.stopServer())
        .thenAnswer((_) async => const Right(null));
    when(() => mockRepository.stopServer(force: true))
        .thenAnswer((_) async => const Right(null));
    when(() => mockRepository.startQhtpTransfer(any(),
            authToken: any(named: 'authToken'),
            sessionPublicId: any(named: 'sessionPublicId'),
            onIndexProgress: any(named: 'onIndexProgress'),
            onIndexed: any(named: 'onIndexed'),
            onIndexFailed: any(named: 'onIndexFailed')))
        .thenAnswer((_) async => Right(session()));
    when(() => mockRepository.generateQRPayload(any()))
        .thenAnswer((_) async => const Right('qr-payload-data'));
  });

  tearDown(() async {
    await approvalController.close();
    await bloc.close();
  });

  /// Pumps `QRDisplayPage` wired to a fresh `SenderBloc`, drives it to
  /// `QRReady`, then pushes [request] through the mocked `approvalRequests`
  /// stream so the dialog appears exactly as it would for a real invite.
  ///
  /// The bloc is built here rather than in `setUp` deliberately: `setUp`
  /// runs outside the `FakeAsync` zone `testWidgets` wraps its body in, so a
  /// bloc constructed there has its internal stream subscriptions bound to
  /// that outer zone — `tester.pump()` then flushes the *wrong* zone's
  /// microtasks, and the mocked repository's futures never appear to
  /// resolve (state sits on `ServerStarting` forever). Building the bloc
  /// inside the `testWidgets` callback keeps it in the zone `pump()` drives.
  Future<void> pumpToApprovalDialog(
    WidgetTester tester, {
    TransferApprovalRequest? request,
  }) async {
    bloc = SenderBloc(repository: mockRepository);
    addTearDown(() async {
      // Both QRDisplayPage and the dialog run their own Timer.periodic
      // (session countdown; approval countdown). Nothing else disposes them
      // once the test stops interacting, and flutter_test fails a test that
      // ends with a Timer still pending.
      await tester.pumpWidget(const SizedBox());
    });

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider<SenderBloc>.value(
        value: bloc,
        child: const QRDisplayPage(),
      ),
    ));

    bloc.add(const StartQhtpSend(['/tmp/whatever'], mode: TransportType.wifi));
    // Deliberately not pumpAndSettle: the pre-QRReady phase shows a
    // continuously shimmering skeleton loader that never settles on its own.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(bloc.state, isA<QRReady>(),
        reason: 'the dialog only ever appears from QRReady — set up failed '
            'to reach it');

    approvalController.add(request ?? req);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  group('B2 — approval dialog', () {
    testWidgets(
        'shows sender/device name, size, item count and a countdown',
        (tester) async {
      await pumpToApprovalDialog(tester);

      expect(bloc.state, isA<InviteApprovalRequested>());
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Accept files?'), findsOneWidget);
      // Device name, address, item count and size, all in the one sentence
      // the dialog composes from the request.
      expect(
        find.text(
            'Pixel 8 (192.168.1.77) wants to receive 3 files (1.5 MB).'),
        findsOneWidget,
      );
      expect(find.textContaining('Request expires in'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    });

    testWidgets(
        'Accept adds RespondToInviteApproval(accepted: true) and returns to QRReady',
        (tester) async {
      await pumpToApprovalDialog(tester);

      await tester.tap(find.text('Accept'));
      // Not pumpAndSettle: QRDisplayPage's own session-countdown
      // Timer.periodic(1s) never stops on its own, and pumpAndSettle waits
      // out real time against it rather than the fake clock, so it never
      // reports settled. A fixed, generous number of steps covers the
      // dialog's pop transition instead.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      verify(() => mockRepository.respondToApproval('approval-req-1', true))
          .called(1);
      expect(bloc.state, isA<QRReady>());
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'Decline adds RespondToInviteApproval(accepted: false) and returns to QRReady',
        (tester) async {
      await pumpToApprovalDialog(tester);

      await tester.tap(find.text('Decline'));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      verify(() => mockRepository.respondToApproval('approval-req-1', false))
          .called(1);
      expect(bloc.state, isA<QRReady>());
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'the countdown reaching 0 auto-declines, exactly like tapping Decline',
        (tester) async {
      await pumpToApprovalDialog(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      // Starts at 90s and pops(false) once it reaches zero. Elapse past that
      // without ever tapping a button, then give the pop transition and the
      // bloc's response a fixed, generous number of steps to land.
      await tester.pump(const Duration(seconds: 91));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      verify(() => mockRepository.respondToApproval('approval-req-1', false))
          .called(1);
      expect(bloc.state, isA<QRReady>());
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}

// The share link still opens a transfer.
//
// `directdrop://join?p=…` is not an interface control: it is how an internet
// transfer reaches a desktop, which has no camera to scan the QR with and no
// digit code to type for that path. So the handler stays, and what changes is
// where it lands — not on the code-entry screen, which takes ten digits and
// nothing else, but on a screen of its own that hands the link to the
// receiver and moves on to the preview.
import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/app.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/platform/device_platform.dart';
import 'package:quickshare/core/router/app_router.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/receiver/presentation/pages/code_receive_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/link_receive_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class _MockReceiverBloc extends MockBloc<ReceiverEvent, ReceiverState>
    implements ReceiverBloc {}

class _Links extends DeepLinkService {
  final controller = StreamController<ShareLinkContents>.broadcast();

  @override
  Stream<ShareLinkContents> get sharePayloads => controller.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async => controller.close();
}

String get _location =>
    AppRouter.router.routerDelegate.currentConfiguration.uri.toString();

Future<void> _frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late _MockReceiverBloc bloc;
  late _Links links;

  setUpAll(() => registerFallbackValue(const QRCodeScanned('')));

  setUp(() async {
    await ServiceLocator.init();
    bloc = _MockReceiverBloc();
    whenListen(bloc, const Stream<ReceiverState>.empty(),
        initialState: ReceiverInitial());
    sl.unregister<ReceiverBloc>();
    sl.registerFactory<ReceiverBloc>(() => bloc);
    links = _Links();
    DevicePlatform.debugIsDesktop = true;
  });

  tearDown(() async {
    DevicePlatform.debugIsDesktop = null;
    await links.dispose();
    await sl.reset();
  });

  testWidgets('a share link opened on a desktop reaches the receiver, not the '
      'code screen', (tester) async {
    await tester.pumpWidget(DirectDropApp(deepLinks: links));
    await _frames(tester);

    final link = DeepLinkService.buildPayloadLink(
      const QRPayload(
        version: 2,
        ip: '192.168.1.5',
        port: 8000,
        token: 'tok',
        sessionId: 's',
        mode: 'http-lan',
        tlsFingerprint: 'AA',
      ).encode(),
      name: 'Holiday',
      bytes: 10,
      itemCount: 2,
    );
    links.controller.add(DeepLinkService.parseShareLink(link)!);
    await _frames(tester);

    expect(_location, startsWith('/receive/link'));
    expect(find.byType(LinkReceivePage), findsOneWidget);
    expect(find.byType(CodeReceivePage), findsNothing);

    final sent = verify(() => bloc.add(captureAny())).captured.single;
    expect(sent, isA<QRCodeScanned>());
    expect((sent as QRCodeScanned).rawData, startsWith('directdrop://join?p='));
    expect(sent.rawData, contains('n=Holiday'),
        reason: 'the preview fields travel with the link');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('once the receiver has understood it, the preview opens',
      (tester) async {
    const payload = QRPayload(
      version: 2,
      ip: '192.168.1.5',
      port: 8000,
      token: 'tok',
      sessionId: 's',
      mode: 'http-lan',
      tlsFingerprint: 'AA',
    );
    final states = StreamController<ReceiverState>();
    whenListen(bloc, states.stream, initialState: ReceiverInitial());

    await tester.pumpWidget(MaterialApp.router(
      routerConfig: AppRouter.router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ));
    AppRouter.router.go('/receive/link?p=${Uri.encodeQueryComponent('x')}');
    await _frames(tester);

    states.add(const QRParsed(payload));
    await _frames(tester);

    expect(_location, '/receive/preview');
    await states.close();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a link the receiver cannot read says so and offers the way '
      'out', (tester) async {
    final states = StreamController<ReceiverState>();
    whenListen(bloc, states.stream, initialState: ReceiverInitial());

    await tester.pumpWidget(MaterialApp.router(
      routerConfig: AppRouter.router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ));
    AppRouter.router.go('/receive/link?p=garbage');
    await _frames(tester);

    states.add(const ReceiverError('That link is not a DirectDrop link.'));
    await _frames(tester);

    expect(find.textContaining('not a DirectDrop link'), findsOneWidget);
    expect(find.byType(LinkReceivePage), findsOneWidget);
    await states.close();
    await tester.pumpWidget(const SizedBox());
  });

  test('a link with no payload is not routed anywhere', () {
    expect(DeepLinkService.parseShareLink('directdrop://join'), isNull);
    expect(DeepLinkService.parseShareLink('https://example.com/?p=abc'), isNull);
  });
}

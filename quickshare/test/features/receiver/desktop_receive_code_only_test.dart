// Receiving: a desktop types a code, a phone may also scan.
//
// The owner's rule is that a connection happens through a QR code or a digit
// code and nothing else, and that a desktop — which has no camera worth
// pointing at a screen — only ever types the digits. So on a desktop there is
// no scan button anywhere, the scanner route is not reachable, and the
// code-entry screen takes ten digits and nothing else: no pasted link, no raw
// QR text, no `directdrop://` field.
//
// The platform is overridden rather than read off the machine running the
// tests, so the same suite proves both sides.
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/platform/device_platform.dart';
import 'package:quickshare/core/router/app_router.dart';
import 'package:quickshare/features/receiver/data/client/code_lookup.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/receiver/presentation/pages/code_receive_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/qr_scan_page.dart';
import 'package:quickshare/features/sender/presentation/widgets/transport_preconditions.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// The radios, answering at once: tapping Receive checks them first, and the
/// real checks talk to a platform a headless test does not have.
class _Radio extends UniversalBlePlatform {
  @override
  Future<bool> enableBluetooth() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _Wifi extends PeerLinkService {
  const _Wifi();
  @override
  Future<bool> enableWifi() async => true;
}

/// What the screen asked the network for, and what it was told.
class _Lookup extends CodeLookup {
  _Lookup() : super(lanOnly: true);

  final List<SessionCode> asked = [];
  CodeSessionOutcome outcome = const CodeSessionNotFound();

  @override
  Future<CodeSessionOutcome> find(SessionCode code,
      {CodeSearchControl? control}) async {
    asked.add(code);
    return outcome;
  }
}

Future<void> _frames(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String get _location =>
    AppRouter.router.routerDelegate.currentConfiguration.uri.toString();

Future<void> _app(WidgetTester tester) async {
  // Tall enough for both cards on the home screen to be on it.
  tester.view
    ..physicalSize = const Size(900, 1400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp.router(
    routerConfig: AppRouter.router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
  ));
  await _frames(tester);
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  final realPeerLink = TransportPreconditions.peerLink;

  setUp(() async {
    await ServiceLocator.init();
    UniversalBle.setInstance(_Radio());
    TransportPreconditions.peerLink = const _Wifi();
  });

  tearDown(() async {
    DevicePlatform.debugIsDesktop = null;
    TransportPreconditions.peerLink = realPeerLink;
    await sl.reset();
  });

  group('on a desktop', () {
    setUp(() => DevicePlatform.debugIsDesktop = true);

    testWidgets('Receive on the home screen leads to code entry', (tester) async {
      await _app(tester);
      AppRouter.router.go('/');
      await _frames(tester);

      await tester.tap(find.text('Receive File'));
      await _frames(tester, 10);

      expect(find.byType(CodeReceivePage), findsOneWidget);
      expect(find.byType(QRScanPage), findsNothing);
      await _teardown(tester);
    });

    testWidgets('the home screen has no scan control and does not talk about '
        'scanning', (tester) async {
      await _app(tester);
      AppRouter.router.go('/');
      await _frames(tester);

      expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
      expect(find.byIcon(Icons.qr_code_scanner_rounded), findsNothing);
      expect(find.textContaining(RegExp('scan', caseSensitive: false)),
          findsNothing);
      expect(find.textContaining(RegExp('nearby', caseSensitive: false)),
          findsNothing);
      await _teardown(tester);
    });

    testWidgets('the scanner route is not reachable: it lands on code entry',
        (tester) async {
      await _app(tester);

      AppRouter.router.go('/receive');
      await _frames(tester, 10);

      expect(_location, '/receive/code');
      expect(find.byType(QRScanPage), findsNothing);
      expect(find.byType(CodeReceivePage), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('code entry takes digits only: no paste control, no link '
        'field, no scan button', (tester) async {
      await _app(tester);
      AppRouter.router.go('/receive/code');
      await _frames(tester);

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.paste_rounded), findsNothing);
      expect(find.text('Paste'), findsNothing);
      expect(find.textContaining('directdrop://'), findsNothing);
      expect(find.textContaining(RegExp('link', caseSensitive: false)),
          findsNothing);
      expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
      expect(find.byIcon(Icons.qr_code_scanner_rounded), findsNothing);
      expect(find.textContaining(RegExp('scan', caseSensitive: false)),
          findsNothing);
      await _teardown(tester);
    });

    testWidgets('a share link in the address (?p=) is not read into the screen',
        (tester) async {
      await _app(tester);

      AppRouter.router.go('/receive/code?p=QS1AAAAAAAA&n=x&s=10&c=2');
      await _frames(tester, 10);

      expect(find.byType(CodeReceivePage), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);
      expect(find.text('File found'), findsNothing);
      await _teardown(tester);
    });
  });

  group('on a phone', () {
    setUp(() => DevicePlatform.debugIsDesktop = false);

    testWidgets('Receive on the home screen leads to the scanner',
        (tester) async {
      await _app(tester);
      AppRouter.router.go('/');
      await _frames(tester);

      await tester.tap(find.text('Receive File'));
      await _frames(tester, 10);

      expect(find.byType(QRScanPage), findsOneWidget);
      expect(find.byType(CodeReceivePage), findsNothing);
      await _teardown(tester);
    });

    testWidgets('the scanner keeps its "Enter Code" way into code entry',
        (tester) async {
      await _app(tester);
      AppRouter.router.go('/receive');
      await _frames(tester, 10);

      expect(find.text('Enter Code'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('code entry is the same digits-only screen', (tester) async {
      await _app(tester);
      AppRouter.router.go('/receive/code');
      await _frames(tester);

      expect(find.byType(CodeReceivePage), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.paste_rounded), findsNothing);
      expect(find.textContaining('directdrop://'), findsNothing);
      await _teardown(tester);
    });
  });

  group('the code-entry screen', () {
    late _Lookup lookup;

    Future<void> mount(WidgetTester tester) async {
      lookup = _Lookup();
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<ReceiverBloc>(
          create: (_) => sl<ReceiverBloc>(),
          child: CodeReceivePage(lookup: lookup),
        ),
      ));
      await _frames(tester, 2);
    }

    testWidgets('looks for nothing while the code is being typed or '
        'incomplete', (tester) async {
      await mount(tester);

      await tester.enterText(find.byType(TextField), '12345');
      await tester.pump();
      expect(lookup.asked, isEmpty, reason: 'half a code is not a search');

      await tester.tap(find.text('Receive'));
      await _frames(tester, 3);

      expect(lookup.asked, isEmpty,
          reason: 'an incomplete code must not start the network search');
      expect(find.textContaining('ten digits'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('a complete code starts the search, with that code and no '
        'other', (tester) async {
      await mount(tester);

      await tester.enterText(find.byType(TextField), '1234567890');
      await tester.pump();
      await tester.tap(find.text('Receive'));
      await _frames(tester, 3);

      expect(lookup.asked, [const SessionCode('1234567890')]);
      await _teardown(tester);
    });

    testWidgets('a code typed in two groups is the same code', (tester) async {
      await mount(tester);

      await tester.enterText(find.byType(TextField), '12345 67890');
      await tester.pump();
      await tester.tap(find.text('Receive'));
      await _frames(tester, 3);

      expect(lookup.asked, [const SessionCode('1234567890')]);
      await _teardown(tester);
    });

    testWidgets('text that is not digits never reaches the search or the '
        'parser', (tester) async {
      await mount(tester);

      await tester.enterText(
          find.byType(TextField), 'directdrop://join?p=QS1AAAAAAAAAAAA');
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isNot(contains('directdrop')));

      await tester.tap(find.text('Receive'));
      await _frames(tester, 3);

      expect(lookup.asked, isEmpty);
      expect(find.text('File found'), findsNothing);
      await _teardown(tester);
    });

    testWidgets('a code nobody offers says so — and that it changes every five '
        'minutes, without promising a Wi-Fi network', (tester) async {
      await mount(tester);

      await tester.enterText(find.byType(TextField), '1234567890');
      await tester.pump();
      await tester.tap(find.text('Receive'));
      await _frames(tester, 3);

      expect(find.textContaining('changes every 5 minutes'), findsOneWidget,
          reason: 'codes change every five minutes: "not found" has to say '
              'that is one of the reasons');
      expect(find.textContaining('Wi-Fi'), findsNothing,
          reason: 'the sender may be anywhere: no promise about Wi-Fi');
      await _teardown(tester);
    });
  });
}

// The home screen offers two ways to send — "Over the internet" and "AirDrop"
// — and receiving as an action of its own below them. AirDrop opens, in
// place, the two ways that are really transports: the local network and the
// Bluetooth-started direct link.
//
// What these pin:
//  * which names are on the screen, in both languages, read from the l10n
//    keys and compared to the wording the owner asked for;
//  * the AirDrop buttons are absent until AirDrop is opened, and absent again
//    when it is closed — by finger, by keyboard, and with motion reduced;
//  * every button opens the file screen for its own transport, and that
//    screen no longer asks which one;
//  * a transport that cannot run is refused *on the home screen*, before any
//    file has been chosen;
//  * a file dropped on a target goes the way that target says;
//  * nothing overflows at a phone's size or with larger text.
import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/platform/device_platform.dart';
import 'package:quickshare/core/router/app_router.dart';
import 'package:quickshare/features/home/presentation/pages/home_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/code_receive_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/qr_scan_page.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/pages/file_picker_page.dart';
import 'package:quickshare/features/sender/presentation/widgets/transport_preconditions.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

// ── fakes: the radios and the network, answering at once ────────────────────

class _Radio extends UniversalBlePlatform {
  _Radio(this.state);
  final AvailabilityState state;
  @override
  Future<bool> enableBluetooth() async => true;
  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async => state;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _Wifi extends PeerLinkService {
  const _Wifi();
  @override
  Future<bool> get wifiReady async => true;
  @override
  Future<bool> enableWifi() async => true;
  @override
  Future<bool> openWifiSettings() async => true;
}

class _Network extends NetworkInfoService {
  _Network({this.lan = true, this.internet = true});
  final bool lan;
  final bool internet;
  @override
  Future<bool> hasWifiTransportNetwork() async => lan;
  @override
  Future<bool> hasAnyActiveConnection() async => internet;
}

// ── harness ──────────────────────────────────────────────────────────────────

Future<void> _frames(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Where a `go` landed. A `push` does not move this — it stays at the route
/// underneath — so a screen opened by tapping is looked for in the tree
/// ([_filesAddress]) instead.
String get _location =>
    AppRouter.router.routerDelegate.currentConfiguration.uri.toString();

/// The address the file screen was opened at, or null if it is not on screen.
String? _filesAddress(WidgetTester tester) {
  final screen = find.byType(FilePickerPage);
  if (screen.evaluate().isEmpty) return null;
  return GoRouterState.of(tester.element(screen)).uri.toString();
}

/// Taps [finder] after scrolling it into view, which a small screen with large
/// text needs and a person would do.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

/// Runs [body] with the app believing it is on [platform]. The override has
/// to be gone by the time the test body ends, so it cannot be a tear-down.
Future<void> _onPlatform(
    TargetPlatform platform, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Sizes the window, sets the system's reduce-motion switch and the text
/// scale, and puts the real app on screen at the home route.
Future<void> _app(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  Size size = const Size(900, 1400),
  double textScale = 1.0,
  bool reduceMotion = true,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: reduceMotion);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

  await tester.pumpWidget(MaterialApp.router(
    routerConfig: AppRouter.router,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
  ));
  AppRouter.router.go('/');
  await _frames(tester);
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 200));
}

Future<AppLocalizations> _l10n(String code) =>
    AppLocalizations.delegate.load(Locale(code));

void main() {
  final realNetwork = TransportPreconditions.networkInfo;
  final realPeerLink = TransportPreconditions.peerLink;

  setUp(() async {
    await ServiceLocator.init();
    TransportPreconditions.networkInfo = _Network();
    TransportPreconditions.peerLink = const _Wifi();
    UniversalBle.setInstance(_Radio(AvailabilityState.poweredOn));
    DevicePlatform.debugIsDesktop = null;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    DevicePlatform.debugIsDesktop = null;
    TransportPreconditions.networkInfo = realNetwork;
    TransportPreconditions.peerLink = realPeerLink;
    await sl.reset();
  });

  // ── what is on the screen ──────────────────────────────────────────────────

  group('the names on the home screen', () {
    // The owner's wording, exactly. The l10n keys are what the screen reads,
    // so a rename in the ARB files fails here on purpose and has to be made
    // in this table as well.
    const wording = {
      'en': {
        'internet': 'Over the internet',
        'airdrop': 'AirDrop',
        'local': 'Local network transfer',
        'alternative': 'AirDrop alternative',
        'removed': 'Send File',
        'receive': 'Receive File',
      },
      'ru': {
        'internet': 'Через интернет',
        'airdrop': 'AirDrop',
        'local': 'Передача по локальной сети',
        'alternative': 'Аналог AirDrop',
        'removed': 'Отправить файл',
        'receive': 'Получить файл',
      },
    };

    for (final code in ['en', 'ru']) {
      final w = wording[code]!;

      test('the $code keys say exactly what the owner asked for', () async {
        final l10n = await _l10n(code);
        expect(l10n.homeInternetTitle, w['internet']);
        expect(l10n.homeAirdropTitle, w['airdrop']);
        expect(l10n.homeLocalNetworkTitle, w['local']);
        expect(l10n.homeAirdropAltTitle(l10n.homeAirdropTitle), w['alternative']);
        expect(l10n.homeReceiveTitle, w['receive']);
      });

      testWidgets('$code: two ways to send and Receive, no Send card',
          (tester) async {
        final l10n = await _l10n(code);
        await _app(tester, locale: Locale(code));

        expect(find.text(l10n.homeInternetTitle), findsOneWidget);
        expect(find.text(l10n.homeAirdropTitle), findsOneWidget);
        expect(find.text(l10n.homeReceiveTitle), findsOneWidget);
        // The card that used to be here, by its words.
        expect(find.text(w['removed']!), findsNothing);
        expect(find.textContaining(RegExp(code == 'en' ? 'Send' : 'Отправить')),
            findsNothing);
        await _teardown(tester);
      });
    }

    testWidgets('every "AirDrop" on screen is the one string, so one edit '
        'renames it', (tester) async {
      final l10n = await _l10n('en');
      await _app(tester);
      await _tap(tester, find.text(l10n.homeAirdropTitle));
      await _frames(tester);

      // The card title and the alternative's title, which is built from it.
      final named = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((t) => t.contains('AirDrop'))
          .toList();
      expect(named, containsAll([l10n.homeAirdropTitle, 'AirDrop alternative']));
      await _teardown(tester);
    });

    testWidgets('Receive File is below both ways to send, not a third card',
        (tester) async {
      final l10n = await _l10n('en');
      await _app(tester);

      final internet = tester.getRect(find.text(l10n.homeInternetTitle));
      final airdrop = tester.getRect(find.text(l10n.homeAirdropTitle));
      final receive = tester.getRect(find.text(l10n.homeReceiveTitle));
      expect(receive.top, greaterThan(airdrop.bottom));
      expect(airdrop.top, greaterThan(internet.bottom));

      // Quieter than a card: much shorter than either of them.
      final cardHeight = tester
          .getSize(find
              .ancestor(
                  of: find.text(l10n.homeInternetTitle),
                  matching: find.byType(Container))
              .first)
          .height;
      final receiveHeight = tester
          .getSize(find
              .ancestor(
                  of: find.text(l10n.homeReceiveTitle),
                  matching: find.byType(AnimatedContainer))
              .first)
          .height;
      expect(receiveHeight, lessThan(cardHeight));
      await _teardown(tester);
    });
  });

  // ── opening and closing AirDrop ────────────────────────────────────────────

  group('AirDrop opens and closes in place', () {
    testWidgets('the two buttons are not on screen until AirDrop is opened',
        (tester) async {
      final l10n = await _l10n('en');
      await _app(tester);

      expect(find.text(l10n.homeLocalNetworkTitle), findsNothing);
      expect(find.text('AirDrop alternative'), findsNothing);

      await _tap(tester, find.text(l10n.homeAirdropTitle));
      await _frames(tester);
      expect(find.text(l10n.homeLocalNetworkTitle), findsOneWidget);
      expect(find.text('AirDrop alternative'), findsOneWidget);
      // It opened in place: still the home screen.
      expect(_location, '/');

      await _tap(tester, find.text(l10n.homeAirdropTitle));
      await _frames(tester);
      expect(find.text(l10n.homeLocalNetworkTitle), findsNothing);
      expect(find.text('AirDrop alternative'), findsNothing);
      await _teardown(tester);
    });

    testWidgets('the Bluetooth-started button is there on all five platforms',
        (tester) async {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.iOS,
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        await _onPlatform(platform, () async {
          await _app(tester);
          await _tap(tester, find.text('AirDrop'));
          await _frames(tester);
          expect(find.text('AirDrop alternative'), findsOneWidget,
              reason: platform.name);
          await _teardown(tester);
        });
      }
    });

    testWidgets('a platform without Bluetooth sending is not offered it',
        (tester) async {
      await _onPlatform(TargetPlatform.fuchsia, () async {
        await _app(tester);
        await _tap(tester, find.text('AirDrop'));
        await _frames(tester);

        expect(find.text('Local network transfer'), findsOneWidget);
        expect(find.text('AirDrop alternative'), findsNothing);
        await _teardown(tester);
      });
    });

    testWidgets('with motion reduced it happens at once, with none shown',
        (tester) async {
      await _app(tester, reduceMotion: true);

      await _tap(tester, find.text('AirDrop'));
      await tester.pump();
      expect(find.text('Local network transfer'), findsOneWidget);
      final sizeFactor = tester
          .widget<SizeTransition>(find.byType(SizeTransition))
          .sizeFactor
          .value;
      expect(sizeFactor, 1.0, reason: 'fully open on the first frame');

      await _tap(tester, find.text('AirDrop'));
      await tester.pump();
      expect(find.text('Local network transfer'), findsNothing,
          reason: 'fully closed on the first frame');
      await _teardown(tester);
    });

    testWidgets('with motion allowed it animates, and the options are out of '
        'reach while they leave', (tester) async {
      await _app(tester, reduceMotion: false);

      await _tap(tester, find.text('AirDrop'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final mid = tester
          .widget<SizeTransition>(find.byType(SizeTransition))
          .sizeFactor
          .value;
      expect(mid, inExclusiveRange(0.0, 1.0), reason: 'part-way open');
      await tester.pump(const Duration(milliseconds: 400));
      expect(
          tester
              .widget<SizeTransition>(find.byType(SizeTransition))
              .sizeFactor
              .value,
          1.0);

      // Closing: still drawn for a moment, but nothing in it can be tapped.
      await _tap(tester, find.text('AirDrop'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Local network transfer'), findsOneWidget);
      await tester.tap(find.text('Local network transfer'),
          warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(FilePickerPage), findsNothing,
          reason: 'a leaving button does not navigate');
      expect(find.text('Local network transfer'), findsNothing);
      await _teardown(tester);
    });
  });

  group('opening AirDrop on a small screen shows both buttons', () {
    for (final reduceMotion in [true, false]) {
      for (final (name, size, scale) in [
        ('the 680 × 748 macOS window', const Size(680, 748), 1.0),
        ('a 375 × 812 phone, text ×1.3', const Size(375, 812), 1.3),
        ('a 320 × 568 phone', const Size(320, 568), 1.0),
      ]) {
        testWidgets('${reduceMotion ? 'motion reduced' : 'animated'}, $name',
            (tester) async {
          await _app(tester,
              size: size, textScale: scale, reduceMotion: reduceMotion);

          await _tap(tester, find.text('AirDrop'));
          await _frames(tester, 15);

          final bluetooth = tester.getRect(find.text('AirDrop alternative'));
          final local = tester.getRect(find.text('Local network transfer'));
          expect(local.top, greaterThanOrEqualTo(0));
          expect(bluetooth.bottom, lessThanOrEqualTo(size.height),
              reason: 'the second button is not left half off the screen');
          expect(tester.takeException(), isNull);
          await _teardown(tester);
        });
      }
    }
  });

  // ── keyboard and screen reader ─────────────────────────────────────────────

  group('keyboard and screen reader', () {
    testWidgets('Enter and Space on the focused AirDrop card open and close it',
        (tester) async {
      await _app(tester);
      Focus.of(tester.element(find.text('AirDrop'))).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(find.text('Local network transfer'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _frames(tester);
      expect(find.text('Local network transfer'), findsNothing);
      await _teardown(tester);
    });

    testWidgets('Tab from the open card reaches the buttons, Enter chooses one',
        (tester) async {
      await _app(tester);
      Focus.of(tester.element(find.text('AirDrop'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);

      expect(_filesAddress(tester), '/send?mode=wifi');
      await _teardown(tester);
    });

    testWidgets('the card tells a screen reader whether it is open',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _app(tester);

      final card = find.bySemanticsLabel(RegExp(r'^AirDrop\. '));
      expect(card, findsOneWidget);
      expect(
        tester.getSemantics(card),
        isSemantics(
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
        ),
      );

      await _tap(tester, find.text('AirDrop'));
      await _frames(tester);
      expect(
        tester.getSemantics(card),
        isSemantics(
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
        ),
      );

      // The buttons it opened are buttons, and are not "expandable".
      final local = find.bySemanticsLabel(RegExp(r'^Local network transfer\. '));
      expect(local, findsOneWidget);
      expect(tester.getSemantics(local),
          isSemantics(isButton: true, hasTapAction: true));

      await _tap(tester, find.text('AirDrop'));
      await _frames(tester);
      expect(
        tester.getSemantics(card),
        isSemantics(hasExpandedState: true, isExpanded: false),
      );
      expect(find.bySemanticsLabel(RegExp(r'^Local network transfer\. ')),
          findsNothing);

      handle.dispose();
      await _teardown(tester);
    });

    testWidgets('Receive File is a button for a screen reader too',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _app(tester);
      final receive = find.bySemanticsLabel(RegExp(r'^Receive File\. '));
      expect(receive, findsOneWidget);
      expect(tester.getSemantics(receive),
          isSemantics(isButton: true, hasTapAction: true));
      expect(
          tester.getSemantics(receive).getSemanticsData().flagsCollection.isExpanded,
          Tristate.none,
          reason: 'it opens nothing in place');
      handle.dispose();
      await _teardown(tester);
    });
  });

  // ── where each button leads ────────────────────────────────────────────────

  group('each button opens the file screen for its own transport', () {
    final cases = <(String, TransportType, List<String>)>[
      ('Over the internet', TransportType.internet, const []),
      ('Local network transfer', TransportType.wifi, const ['AirDrop']),
      ('AirDrop alternative', TransportType.bluetooth, const ['AirDrop']),
    ];

    for (final (label, mode, opening) in cases) {
      testWidgets('$label → /send?mode=${mode.name}', (tester) async {
        await _app(tester);
        for (final open in opening) {
          await tester.tap(find.text(open));
          await _frames(tester);
        }

        await tester.tap(find.text(label));
        await _frames(tester, 15);

        expect(_filesAddress(tester), '/send?mode=${mode.name}');
        final picker =
            tester.widget<FilePickerPage>(find.byType(FilePickerPage));
        expect(picker.mode, mode);
        // The screen is titled with the way it sends.
        expect(
            find.descendant(
                of: find.byType(AppBar), matching: find.text(label)),
            findsOneWidget);
        // And it no longer asks which way: no tiles, no radio buttons.
        expect(find.byType(Radio<TransportType>), findsNothing);
        expect(find.textContaining('Select Transfer Method'), findsNothing);
        expect(find.text('Wi-Fi / Local Network'), findsNothing);
        expect(find.text('Internet Link'), findsNothing);
        await _teardown(tester);
      });
    }

    testWidgets('coming back keeps AirDrop as it was left', (tester) async {
      await _app(tester);
      await _tap(tester, find.text('AirDrop'));
      await _frames(tester);
      await tester.tap(find.text('Local network transfer'));
      await _frames(tester, 15);
      expect(_filesAddress(tester), '/send?mode=wifi');

      AppRouter.router.pop();
      await _frames(tester, 15);
      expect(find.byType(FilePickerPage), findsNothing);
      expect(find.text('Local network transfer'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('Receive File leads where it always led: code on a desktop, '
        'the scanner on a phone', (tester) async {
      DevicePlatform.debugIsDesktop = true;
      await _app(tester);
      await tester.tap(find.text('Receive File'));
      await _frames(tester, 15);
      expect(find.byType(CodeReceivePage), findsOneWidget);
      expect(find.byType(QRScanPage), findsNothing);
      await _teardown(tester);

      DevicePlatform.debugIsDesktop = false;
      await _app(tester);
      await tester.tap(find.text('Receive File'));
      await _frames(tester, 15);
      expect(find.byType(QRScanPage), findsOneWidget);
      expect(find.byType(CodeReceivePage), findsNothing);
      await _teardown(tester);
    });

    testWidgets('the settings gear is still there and still works',
        (tester) async {
      await _app(tester);
      await tester.tap(find.byTooltip('Settings'));
      await _frames(tester, 15);
      expect(_location, '/settings');  // the gear uses go, not push
      await _teardown(tester);
    });
  });

  // ── an address that does not name a transport ──────────────────────────────

  group('a /send address without a usable mode', () {
    for (final address in [
      '/send',
      '/send?mode=',
      '/send?mode=bogus',
      '/send?mode=WIFI',
      '/send?mode=wifi%00',
    ]) {
      testWidgets('$address goes home without an error', (tester) async {
        await _app(tester);
        AppRouter.router.go(address);
        await _frames(tester, 15);

        expect(tester.takeException(), isNull);
        expect(_location, '/');
        expect(find.byType(HomePage), findsOneWidget);
        expect(find.byType(FilePickerPage), findsNothing);
        await _teardown(tester);
      });
    }

    testWidgets('Bluetooth, asked for on a platform without it, goes home too',
        (tester) async {
      await _onPlatform(TargetPlatform.fuchsia, () async {
        await _app(tester);
        AppRouter.router.go('/send?mode=bluetooth');
        await _frames(tester, 15);

        expect(tester.takeException(), isNull);
        expect(_location, '/');
        expect(find.byType(FilePickerPage), findsNothing);
        await _teardown(tester);
      });
    });

    testWidgets('the pages under /send keep the screen beneath them on its '
        'transport', (tester) async {
      await _app(tester);
      AppRouter.router.go('/send?mode=internet');
      await _frames(tester, 15);

      // A page below /send is built from an address with no mode in it.
      AppRouter.router.go('/send/fallback');
      await _frames(tester, 15);
      expect(tester.takeException(), isNull);

      final title = find.descendant(
          of: find.byType(AppBar, skipOffstage: false),
          matching: find.text('Over the internet', skipOffstage: false));
      expect(title, findsOneWidget,
          reason: 'it still sends over the internet underneath');
      await _teardown(tester);
    });
  });

  // ── the transport is checked at the button ─────────────────────────────────

  group('a transport that cannot run is refused on the home screen', () {
    testWidgets('Bluetooth off: the dialog is shown, no file screen opens',
        (tester) async {
      UniversalBle.setInstance(_Radio(AvailabilityState.poweredOff));
      final l10n = await _l10n('en');
      await _app(tester);

      await _tap(tester, find.text('AirDrop'));
      await _frames(tester);
      await _tap(tester, find.text('AirDrop alternative'));
      await _frames(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(l10n.precondBluetoothTitle), findsOneWidget);
      expect(find.byType(FilePickerPage), findsNothing,
          reason: 'no file has been asked for');

      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(find.byType(FilePickerPage), findsNothing);
      // And the person can try again: the screen is not stuck.
      expect(find.text('AirDrop alternative'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('no local network: the Wi-Fi dialog, still home',
        (tester) async {
      TransportPreconditions.networkInfo = _Network(lan: false);
      final l10n = await _l10n('en');
      await _app(tester);

      await _tap(tester, find.text('AirDrop'));
      await _frames(tester);
      await tester.tap(find.text('Local network transfer'));
      await _frames(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(l10n.precondWifiTitle), findsOneWidget);
      expect(find.byType(FilePickerPage), findsNothing);
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      await _teardown(tester);
    });

    testWidgets('no connection at all: Over the internet says so, still home',
        (tester) async {
      TransportPreconditions.networkInfo = _Network(internet: false);
      final l10n = await _l10n('en');
      await _app(tester);

      await tester.tap(find.text('Over the internet'));
      await _frames(tester);

      expect(find.text(l10n.precondInternetBlocked), findsOneWidget);
      expect(find.byType(FilePickerPage), findsNothing);
      await _teardown(tester);
    });

    testWidgets('a second tap while the first is being decided does nothing',
        (tester) async {
      UniversalBle.setInstance(_Radio(AvailabilityState.poweredOff));
      await _app(tester);
      await _tap(tester, find.text('AirDrop'));
      await _frames(tester);

      await _tap(tester, find.text('AirDrop alternative'));
      await tester.pump();
      await tester.tap(find.text('Local network transfer'),
          warnIfMissed: false);
      await _frames(tester);

      expect(find.byType(AlertDialog), findsOneWidget,
          reason: 'one dialog, not two stacked');
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      await _teardown(tester);
    });
  });

  // ── drag and drop ──────────────────────────────────────────────────────────

  group('a dropped file goes the way its target says', () {
    test('dropModeFor: the internet card is the internet, the rest the '
        'local network', () {
      expect(dropModeFor(HomeDropTarget.internet), TransportType.internet);
      expect(dropModeFor(HomeDropTarget.airdrop), TransportType.wifi);
    });

    /// Stands in for the platform: what the desktop's file manager sends the
    /// `desktop_drop` plugin when a file is dragged in and let go.
    Future<void> drop(WidgetTester tester, Offset at, List<String> paths) async {
      Future<void> send(String method, Object? args) async {
        final data =
            const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
        await tester.binding.defaultBinaryMessenger
            .handlePlatformMessage('desktop_drop', data, (_) {});
      }

      await send('entered', [at.dx, at.dy]);
      await tester.pump();
      await send('updated', [at.dx, at.dy]);
      await tester.pump();
      await send('performOperation', paths);
      await tester.pump();
    }

    /// The home screen on a router whose `/send` only records what it was
    /// given, so a drop can be followed without starting a transfer.
    Future<List<(String?, Object?)>> homeWithRecorder(
        WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(900, 1400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

      final seen = <(String?, Object?)>[];
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, __) => const HomePage()),
        GoRoute(
          path: '/send',
          builder: (_, state) {
            seen.add((state.uri.queryParameters['mode'], state.extra));
            return const Scaffold(body: Text('files screen'));
          },
        ),
      ]);
      await tester.pumpWidget(MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ));
      await _frames(tester);
      return seen;
    }

    testWidgets('on "Over the internet" it goes over the internet',
        (tester) async {
      final seen = await homeWithRecorder(tester);

      await drop(tester, tester.getCenter(find.text('Over the internet')),
          ['/tmp/trip.txt']);
      await _frames(tester);

      expect(seen, hasLength(1));
      expect(seen.single.$1, 'internet');
      expect(seen.single.$2, {'qhtpPaths': ['/tmp/trip.txt']});
      await _teardown(tester);
    });

    testWidgets('on the AirDrop card it goes over the local network',
        (tester) async {
      final seen = await homeWithRecorder(tester);

      await drop(tester, tester.getCenter(find.text('AirDrop')),
          ['/tmp/a.txt', '/tmp/b.txt']);
      await _frames(tester);

      expect(seen, hasLength(1));
      expect(seen.single.$1, 'wifi');
      expect(seen.single.$2, {
        'qhtpPaths': ['/tmp/a.txt', '/tmp/b.txt']
      });
      await _teardown(tester);
    });

    testWidgets('on an AirDrop button it goes over the local network, too',
        (tester) async {
      final seen = await homeWithRecorder(tester);
      await _tap(tester, find.text('AirDrop'));
      await _frames(tester);

      await drop(tester, tester.getCenter(find.text('AirDrop alternative')),
          ['/tmp/a.txt']);
      await _frames(tester);

      expect(seen, hasLength(1));
      expect(seen.single.$1, 'wifi',
          reason: 'a drop skips the choice the buttons offer');
      await _teardown(tester);
    });

    testWidgets('the AirDrop card says "drop here" while a file is over it, '
        'and the internet card does not', (tester) async {
      await homeWithRecorder(tester);
      final at = tester.getCenter(find.text('AirDrop'));
      Future<void> send(String method, Object? args) async {
        final data = const StandardMethodCodec()
            .encodeMethodCall(MethodCall(method, args));
        await tester.binding.defaultBinaryMessenger
            .handlePlatformMessage('desktop_drop', data, (_) {});
      }

      await send('entered', [at.dx, at.dy]);
      await tester.pump();
      expect(find.text('Drop file here to send'), findsOneWidget);
      expect(find.text('Works from any network'), findsOneWidget);

      await send('exited', null);
      await tester.pump();
      expect(find.text('Drop file here to send'), findsNothing);
      await _teardown(tester);
    });

    testWidgets('on the rest of the screen it goes nowhere: only the two '
        'cards take files, as only the Send card did', (tester) async {
      final seen = await homeWithRecorder(tester);

      await drop(tester, tester.getCenter(find.text('Receive File')),
          ['/tmp/a.txt']);
      await _frames(tester);
      await drop(tester, const Offset(450, 12), ['/tmp/a.txt']);
      await _frames(tester);

      expect(seen, isEmpty);
      await _teardown(tester);
    });
  });

  // ── layout ─────────────────────────────────────────────────────────────────

  group('nothing overflows', () {
    const sizes = {
      'a phone, 375 × 812': Size(375, 812),
      'a small phone, 320 × 568': Size(320, 568),
      'a narrow desktop window, 420 × 640': Size(420, 640),
      'the macOS default window, 680 × 748': Size(680, 748),
      'a desktop window, 900 × 700': Size(900, 700),
    };

    for (final code in ['en', 'ru']) {
      for (final MapEntry(key: name, value: size) in sizes.entries) {
        for (final scale in [1.0, 1.3]) {
          testWidgets('$code, $name, text ×$scale — closed and open',
              (tester) async {
            await _app(tester,
                locale: Locale(code), size: size, textScale: scale);
            expect(tester.takeException(), isNull, reason: 'closed');

            await _tap(tester, find.text('AirDrop'));
            await _frames(tester);
            expect(tester.takeException(), isNull, reason: 'open');
            final l10n = await _l10n(code);
            expect(find.text(l10n.homeLocalNetworkTitle), findsOneWidget);

            // Whatever does not fit is reached by scrolling, not cut off.
            await tester.ensureVisible(find.text(l10n.homeReceiveTitle));
            await tester.pump();
            expect(tester.takeException(), isNull, reason: 'scrolled');
            final rect = tester.getRect(find.text(l10n.homeReceiveTitle));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(size.width));
            await _teardown(tester);
          });
        }
      }
    }

    // Receive is half of what the app is for; it must not be the control a
    // small window hides. Measured in the test font and with no safe-area
    // insets, so this guards against the layout growing rather than proving
    // the pixels on a device.
    for (final (name, size) in [
      ('a 375 × 812 phone', const Size(375, 812)),
      ('the 680 × 748 window the macOS app opens in', const Size(680, 748)),
    ]) {
      testWidgets('on $name, closed, Receive File is in view without '
          'scrolling', (tester) async {
        await _app(tester, size: size);
        final receive = tester.getRect(find.text('Receive File'));
        expect(receive.bottom, lessThanOrEqualTo(size.height));
        await _teardown(tester);
      });
    }
  });
}

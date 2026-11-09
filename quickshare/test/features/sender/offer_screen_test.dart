// What the sender's offer screens show: the QR, the code, and how long they
// last — and nothing about other devices.
//
// A desktop sender still shows its own QR for a phone to scan, and the code
// for a desktop to type. The Bluetooth screen shows both for the same nearby
// offer. Every screen carries a countdown to the
// next change, and tells the bloc when the app comes back to the foreground
// so that a code that expired while the machine slept is replaced at once.
import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/platform/device_platform.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/features/sender/presentation/pages/bluetooth_send_page.dart';
import 'package:quickshare/features/sender/presentation/pages/qr_display_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/widgets/copy_value_row.dart';
import 'package:quickshare/shared/widgets/offer_countdown.dart';

class _MockSenderBloc extends MockBloc<SenderEvent, SenderState>
    implements SenderBloc {}

TransferSession _session() => TransferSession(
      id: 's',
      fileMetadata: const FileMetadata(
        name: 'Holiday photos',
        path: '/tmp/Holiday photos',
        size: 2048,
        mimeType: 'application/octet-stream',
      ),
      serverPort: 8000,
      authToken: 'tok',
      localIp: '192.168.1.5',
      startedAt: DateTime.utc(2026),
      isQhtp: true,
      itemCount: 3,
    );

QRReady _offer(SessionCode code, DateTime expiresAt) => QRReady(
      'QR-DATA-FOR-TEST',
      _session(),
      TransportType.wifi,
      code: code,
      itemCount: 3,
      totalBytes: 2048,
      expiresAt: expiresAt,
    );

/// Leaves the app and comes back, through the states the engine really goes
/// through.
void _leaveAndReturn(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

Future<void> _mount(
  WidgetTester tester,
  SenderBloc bloc,
  Widget page,
) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: BlocProvider<SenderBloc>.value(value: bloc, child: page),
  ));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late _MockSenderBloc bloc;
  const code = SessionCode('4081726359');

  setUpAll(() => registerFallbackValue(OfferResumed()));
  tearDown(() {
    DevicePlatform.debugIsDesktop = null;
    debugDefaultTargetPlatformOverride = null;
  });

  void showing(SenderState state) {
    bloc = _MockSenderBloc();
    whenListen(bloc, const Stream<SenderState>.empty(), initialState: state);
  }

  for (final desktop in [true, false]) {
    group(desktop ? 'on a desktop' : 'on a phone', () {
      setUp(() => DevicePlatform.debugIsDesktop = desktop);

      testWidgets('shows the QR and the code', (tester) async {
        showing(_offer(code, DateTime.now().add(const Duration(minutes: 5))));
        await _mount(tester, bloc, const QRDisplayPage());

        expect(find.byType(QrImageView), findsOneWidget);
        expect(find.text(code.display), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('shows no list of devices, and no way to send to one',
          (tester) async {
        showing(_offer(code, DateTime.now().add(const Duration(minutes: 5))));
        await _mount(tester, bloc, const QRDisplayPage());

        for (final word in [
          'nearby',
          'Devices',
          'Send straight',
          'Looking',
          'No devices',
          'Ready to send',
        ]) {
          expect(find.textContaining(word), findsNothing, reason: word);
        }
        expect(find.byType(ListTile), findsNothing);
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('says the code changes, and when', (tester) async {
        showing(_offer(
            code, DateTime.now().add(const Duration(minutes: 4, seconds: 30))));
        await _mount(tester, bloc, const QRDisplayPage());

        expect(find.byType(OfferCountdown), findsOneWidget);
        expect(find.textContaining('Code and QR change in'), findsOneWidget);
        expect(find.textContaining(RegExp(r'4:[23]\d')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      });
    });
  }

  group('the internet offer', () {
    QRReady internetOffer(DateTime expiresAt) => QRReady(
          'QS2-QR-DATA-FOR-TEST',
          _session(),
          TransportType.internet,
          code: code,
          itemCount: 3,
          totalBytes: 2048,
          expiresAt: expiresAt,
        );

    for (final desktop in [true, false]) {
      group(desktop ? 'on a desktop' : 'on a phone', () {
        setUp(() => DevicePlatform.debugIsDesktop = desktop);

        testWidgets(
            'shows the QR and the ten digits beside it, as the local '
            'offer does', (tester) async {
          showing(
              internetOffer(DateTime.now().add(const Duration(minutes: 5))));
          await _mount(tester, bloc, const QRDisplayPage());

          expect(find.byType(QrImageView), findsOneWidget);
          expect(find.text(code.display), findsOneWidget);
          expect(find.text('Code for the receiving device'), findsOneWidget);
          expect(find.text('Scan the QR or enter the code'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('counts down to the next code, like the local one',
            (tester) async {
          showing(internetOffer(
              DateTime.now().add(const Duration(minutes: 4, seconds: 30))));
          await _mount(tester, bloc, const QRDisplayPage());

          expect(find.byType(OfferCountdown), findsOneWidget);
          expect(find.textContaining('Code and QR change in'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('has nothing about sharing or copying a link',
            (tester) async {
          showing(
              internetOffer(DateTime.now().add(const Duration(minutes: 5))));
          await _mount(tester, bloc, const QRDisplayPage());

          expect(find.textContaining(RegExp('link', caseSensitive: false)),
              findsNothing);
          expect(find.textContaining('directdrop://'), findsNothing);
          expect(find.byIcon(Icons.link), findsNothing);
          expect(
              find.textContaining(RegExp('share (the|this) link|share link',
                  caseSensitive: false)),
              findsNothing);
          // The one thing that can be copied is the code.
          final copyRows =
              tester.widgetList<CopyValueRow>(find.byType(CopyValueRow));
          expect(copyRows.map((r) => r.value), [code.display]);
          await tester.pumpWidget(const SizedBox());
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('the code is the same sort of row as on the local offer',
            (tester) async {
          showing(
              internetOffer(DateTime.now().add(const Duration(minutes: 5))));
          await _mount(tester, bloc, const QRDisplayPage());
          final internetRow =
              tester.widget<CopyValueRow>(find.byType(CopyValueRow));
          await tester.pumpWidget(const SizedBox());
          debugDefaultTargetPlatformOverride = null;

          showing(_offer(code, DateTime.now().add(const Duration(minutes: 5))));
          await _mount(tester, bloc, const QRDisplayPage());
          final localRow =
              tester.widget<CopyValueRow>(find.byType(CopyValueRow));

          expect(internetRow.label, localRow.label);
          expect(internetRow.icon, localRow.icon);
          expect(internetRow.value, localRow.value);
          await tester.pumpWidget(const SizedBox());
          debugDefaultTargetPlatformOverride = null;
        });
      });
    }
  });

  group('the countdown', () {
    testWidgets('counts down by the clock it is given, never below zero',
        (tester) async {
      var now = DateTime.utc(2026, 11, 4, 12);
      final expires = now.add(const Duration(minutes: 5));
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: OfferCountdown(expiresAt: expires, now: () => now),
        ),
      ));
      expect(find.textContaining('5:00'), findsOneWidget);

      now = now.add(const Duration(minutes: 1, seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('3:59'), findsOneWidget);

      now = now.add(const Duration(minutes: 10));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('0:00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('moves to the new deadline when the offer is replaced',
        (tester) async {
      var now = DateTime.utc(2026, 11, 4, 12);
      Widget build(DateTime expires) => MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: OfferCountdown(expiresAt: expires, now: () => now),
            ),
          );

      await tester.pumpWidget(build(now.add(const Duration(minutes: 5))));
      now = now.add(const Duration(minutes: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('0:00'), findsOneWidget);

      await tester.pumpWidget(build(now.add(const Duration(minutes: 5))));
      expect(find.textContaining('5:00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('coming back to the app', () {
    testWidgets(
        'tells the bloc, so a code that lapsed while away is replaced '
        'at once', (tester) async {
      showing(_offer(code, DateTime.now().add(const Duration(minutes: 5))));
      await _mount(tester, bloc, const QRDisplayPage());

      _leaveAndReturn(tester);
      await tester.pump();

      verify(() => bloc.add(any(that: isA<OfferResumed>()))).called(1);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('being backgrounded alone tells it nothing', (tester) async {
      showing(_offer(code, DateTime.now().add(const Duration(minutes: 5))));
      await _mount(tester, bloc, const QRDisplayPage());

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();

      verifyNever(() => bloc.add(any(that: isA<OfferResumed>())));
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('the Bluetooth offer', () {
    for (final platform in [
      TargetPlatform.iOS,
      TargetPlatform.android,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux
    ]) {
      testWidgets(
          '$platform shows and copies the QR offer code and instructions',
          (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        DevicePlatform.debugIsDesktop = platform == TargetPlatform.macOS ||
            platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux;
        showing(BluetoothAdvertising(
          _session(),
          qrData: 'BT-QR',
          code: code,
          itemCount: 3,
          locator: 'K3M9Q2TV',
          expiresAt:
              DateTime.now().add(const Duration(minutes: 3, seconds: 10)),
        ));
        await _mount(tester, bloc, const BluetoothSendPage());
        expect(find.byType(QrImageView), findsOneWidget);
        final row = tester.widget<CopyValueRow>(find.byType(CopyValueRow));
        expect(row.value, code.display);
        expect(find.textContaining('K3M9Q2TV'), findsNothing);
        expect(find.byType(OfferCountdown), findsOneWidget);
        expect(find.textContaining('Code and QR change in'), findsOneWidget);
        expect(
            find.text('Scan the QR or enter the numeric code'), findsOneWidget);
        expect(find.textContaining('Enable Bluetooth on both devices'),
            findsOneWidget);
        expect(find.byType(ListTile), findsNothing);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null));
        await tester.ensureVisible(find.byIcon(Icons.copy_rounded));
        await tester.tap(find.byIcon(Icons.copy_rounded));
        await tester.pump();
        expect(copied, code.display);
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('the code row fits a narrow phone screen', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      DevicePlatform.debugIsDesktop = false;
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      showing(BluetoothAdvertising(_session(),
          qrData: 'BT-QR',
          code: code,
          expiresAt: DateTime.now().add(const Duration(minutes: 3))));
      await _mount(tester, bloc, const BluetoothSendPage());
      await tester.ensureVisible(find.byType(CopyValueRow));
      expect(tester.takeException(), isNull);
      expect(tester.widget<CopyValueRow>(find.byType(CopyValueRow)).value,
          code.display);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
        'the QR it shows is the one the bloc holds, and follows it '
        'when the bloc changes it', (tester) async {
      final first = BluetoothAdvertising(
        _session(),
        qrData: 'BT-QR-FIRST',
        code: code,
        locator: 'K3M9Q2TV',
        expiresAt: DateTime.now().add(const Duration(minutes: 3)),
      );
      final second = BluetoothAdvertising(
        _session(),
        qrData: 'BT-QR-SECOND',
        code: const SessionCode('9023456781'),
        locator: 'W8N4P6XA',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      final changes = StreamController<SenderState>();
      bloc = _MockSenderBloc();
      whenListen(bloc, changes.stream, initialState: first);
      await _mount(tester, bloc, const BluetoothSendPage());

      // The page keys the QR by what it encodes, so the one on screen can be
      // told from the one before it.
      expect(find.byKey(const ValueKey('BT-QR-FIRST')), findsOneWidget);
      expect(tester.widget<CopyValueRow>(find.byType(CopyValueRow)).value,
          code.display);

      changes.add(second);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const ValueKey('BT-QR-SECOND')), findsOneWidget,
          reason: 'the QR on screen must change with the token behind it');
      expect(find.byKey(const ValueKey('BT-QR-FIRST')), findsNothing);
      expect(tester.widget<CopyValueRow>(find.byType(CopyValueRow)).value,
          const SessionCode('9023456781').display);
      await changes.close();
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows the QR, no list of devices, and no way to pick one',
        (tester) async {
      showing(BluetoothAdvertising(
        _session(),
        qrData: 'BT-QR',
        itemCount: 3,
        locator: 'K3M9Q2TV',
        expiresAt: DateTime.now().add(const Duration(minutes: 3)),
      ));
      await _mount(tester, bloc, const BluetoothSendPage());

      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      for (final word in [
        'Devices',
        'from the list',
        'Pick a device',
        'Ready to send',
        'Looking',
        'discoverable',
      ]) {
        expect(find.textContaining(word), findsNothing, reason: word);
      }
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('also tells the bloc when the app returns', (tester) async {
      showing(BluetoothAdvertising(
        _session(),
        qrData: 'BT-QR',
        locator: 'K3M9Q2TV',
        expiresAt: DateTime.now().add(const Duration(minutes: 3)),
      ));
      await _mount(tester, bloc, const BluetoothSendPage());

      _leaveAndReturn(tester);
      await tester.pump();

      verify(() => bloc.add(any(that: isA<OfferResumed>()))).called(1);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

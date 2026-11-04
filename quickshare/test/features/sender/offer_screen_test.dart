// What the sender's offer screens show: the QR, the code, and how long they
// last — and nothing about other devices.
//
// A desktop sender still shows its own QR for a phone to scan, and the code
// for a desktop to type. Both screens carry a countdown to the next change,
// and tell the bloc when the app comes back to the foreground so that a code
// that expired while the machine slept is replaced at once.
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
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
  tearDown(() => DevicePlatform.debugIsDesktop = null);

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
      });

      testWidgets('says the code changes, and when', (tester) async {
        showing(_offer(
            code, DateTime.now().add(const Duration(minutes: 4, seconds: 30))));
        await _mount(tester, bloc, const QRDisplayPage());

        expect(find.byType(OfferCountdown), findsOneWidget);
        expect(find.textContaining('Code and QR change in'), findsOneWidget);
        expect(find.textContaining(RegExp(r'4:[23]\d')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    });
  }

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
    });
  });

  group('coming back to the app', () {
    testWidgets('tells the bloc, so a code that lapsed while away is replaced '
        'at once', (tester) async {
      showing(_offer(code, DateTime.now().add(const Duration(minutes: 5))));
      await _mount(tester, bloc, const QRDisplayPage());

      _leaveAndReturn(tester);
      await tester.pump();

      verify(() => bloc.add(any(that: isA<OfferResumed>()))).called(1);
      await tester.pumpWidget(const SizedBox());
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
    });
  });

  group('the Bluetooth offer', () {
    testWidgets('shows its code with the same countdown', (tester) async {
      showing(BluetoothAdvertising(
        _session(),
        qrData: 'BT-QR',
        itemCount: 3,
        code: code,
        expiresAt: DateTime.now().add(const Duration(minutes: 3, seconds: 10)),
      ));
      await _mount(tester, bloc, const BluetoothSendPage());

      expect(find.text(code.display), findsOneWidget);
      expect(find.byType(OfferCountdown), findsOneWidget);
      expect(find.textContaining('Code and QR change in'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows the QR, no list of devices, and no way to pick one',
        (tester) async {
      showing(BluetoothAdvertising(
        _session(),
        qrData: 'BT-QR',
        itemCount: 3,
        code: code,
        expiresAt: DateTime.now().add(const Duration(minutes: 3)),
      ));
      await _mount(tester, bloc, const BluetoothSendPage());

      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      for (final word in [
        'nearby',
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
    });

    testWidgets('says that a phone scans the code and a computer does not '
        'receive over Bluetooth', (tester) async {
      showing(BluetoothAdvertising(
        _session(),
        qrData: 'BT-QR',
        code: code,
        expiresAt: DateTime.now().add(const Duration(minutes: 3)),
      ));
      await _mount(tester, bloc, const BluetoothSendPage());

      expect(find.text('Scan this QR code with the receiving phone'),
          findsOneWidget);
      expect(find.textContaining('A computer cannot receive over Bluetooth'),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('also tells the bloc when the app returns', (tester) async {
      showing(BluetoothAdvertising(
        _session(),
        qrData: 'BT-QR',
        code: code,
        expiresAt: DateTime.now().add(const Duration(minutes: 3)),
      ));
      await _mount(tester, bloc, const BluetoothSendPage());

      _leaveAndReturn(tester);
      await tester.pump();

      verify(() => bloc.add(any(that: isA<OfferResumed>()))).called(1);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

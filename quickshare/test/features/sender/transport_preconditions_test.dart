// The gate that stops a transport being chosen when it cannot run.
//
// DD-04 — three of the four ways to choose files never went through this: a
// drag-and-drop, and the file and media pickers once a mode was already
// selected. Only clicking a different radio button ran the check, so dropping
// a file with Wi-Fi off built a session and a QR code for a network that was
// not there. `_startSend` is the funnel now; this pins that the gate refuses
// a transport that cannot run.
//
// DD-15 — a radio check that threw was let through, "so the transport can
// report the real error". But the point of the gate is that the session does
// not exist yet when it fails. An unknown radio is a radio that is not ready.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/widgets/transport_preconditions.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

class _FakeNetwork extends NetworkInfoService {
  _FakeNetwork({this.wifi = true});
  final bool wifi;
  @override
  Future<bool> hasWifiTransportNetwork() async => wifi;
}

class _FakeBle extends UniversalBlePlatform {
  _FakeBle(this._state, {this.throws = false});
  final AvailabilityState _state;
  final bool throws;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async {
    if (throws) throw StateError('the radio check itself failed');
    return _state;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  final realNetwork = TransportPreconditions.networkInfo;
  tearDown(() => TransportPreconditions.networkInfo = realNetwork);

  /// Pumps a host and hands its context back, so a test can call `ensure`
  /// against it and then drive whatever dialog it raises.
  Future<BuildContext> host(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        }),
      ),
    ));
    return ctx;
  }

  group('DD-04 — Wi-Fi', () {
    testWidgets('a live network lets the mode through with no dialog',
        (tester) async {
      TransportPreconditions.networkInfo = _FakeNetwork(wifi: true);
      final ctx = await host(tester);

      final allowed =
          await TransportPreconditions.ensure(ctx, TransportType.wifi);

      expect(allowed, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('no network refuses the mode and asks the person',
        (tester) async {
      TransportPreconditions.networkInfo = _FakeNetwork(wifi: false);
      final ctx = await host(tester);

      final pending =
          TransportPreconditions.ensure(ctx, TransportType.wifi);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget,
          reason: 'the person is asked, not ignored');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await pending, isFalse,
          reason: 'the caller must not create a session');
    });
  });

  group('DD-15 — Bluetooth', () {
    Future<bool> refusedVia(WidgetTester tester, _FakeBle ble) async {
      UniversalBle.setInstance(ble);
      final ctx = await host(tester);

      final pending =
          TransportPreconditions.ensure(ctx, TransportType.bluetooth);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      return pending;
    }

    testWidgets('a powered radio lets the mode through', (tester) async {
      UniversalBle.setInstance(_FakeBle(AvailabilityState.poweredOn));
      final ctx = await host(tester);

      expect(
        await TransportPreconditions.ensure(ctx, TransportType.bluetooth),
        isTrue,
      );
    });

    testWidgets('an off radio refuses it', (tester) async {
      expect(
        await refusedVia(tester, _FakeBle(AvailabilityState.poweredOff)),
        isFalse,
      );
    });

    testWidgets('an unknown radio refuses it — "could not tell" is not "on"',
        (tester) async {
      expect(
        await refusedVia(tester, _FakeBle(AvailabilityState.unknown)),
        isFalse,
      );
    });

    testWidgets('a radio check that throws refuses it', (tester) async {
      // Was let through here. The session must not exist when this fails.
      expect(
        await refusedVia(
            tester, _FakeBle(AvailabilityState.poweredOn, throws: true)),
        isFalse,
      );
    });
  });
}

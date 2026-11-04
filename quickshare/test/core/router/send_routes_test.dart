// How the file screen is told which transport to use, and what happens to an
// address that does not say.
//
// The transport is chosen on the home screen and rides in the address
// (`/send?mode=internet`). The address is user-reachable — a deep link, a
// typed path, an old bookmark — so a value that is missing, empty or not a
// transport must have one defined outcome that is not a crash and not a quiet
// switch to some other way of sending.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/router/send_routes.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('the address for a transport', () {
    test('names it by its enum name', () {
      expect(SendRoutes.filesFor(TransportType.wifi), '/send?mode=wifi');
      expect(
          SendRoutes.filesFor(TransportType.bluetooth), '/send?mode=bluetooth');
      expect(
          SendRoutes.filesFor(TransportType.internet), '/send?mode=internet');
    });

    test('reads back as the transport it was built from', () {
      for (final type in TransportType.values) {
        final uri = Uri.parse(SendRoutes.filesFor(type));
        expect(SendRoutes.parseMode(uri.queryParameters['mode']), type);
      }
    });
  });

  group('a value that is not a transport', () {
    for (final raw in [null, '', ' ', 'bogus', 'WIFI', 'Wifi', 'wifi ', 'null']) {
      test('${raw == null ? 'a missing mode' : '"$raw"'} is not read as one',
          () {
        expect(SendRoutes.parseMode(raw), isNull);
      });
    }
  });

  group('the guard on /send', () {
    test('lets an address with a transport through', () {
      for (final type in TransportType.values) {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        expect(SendRoutes.guard(Uri.parse(SendRoutes.filesFor(type))), isNull,
            reason: type.name);
      }
    });

    for (final address in [
      '/send',
      '/send?',
      '/send?mode=',
      '/send?mode=bogus',
      '/send?mode=WIFI',
      '/send?other=wifi',
      '/send/?mode=',
    ]) {
      test('sends $address home, not to a default transport', () {
        expect(SendRoutes.guard(Uri.parse(address)), SendRoutes.home);
      });
    }

    test('lets the pages under /send alone: they carry no mode of their own',
        () {
      for (final address in [
        '/send/qr',
        '/send/bluetooth',
        '/send/progress',
        '/send/fallback',
        '/send/local-network',
      ]) {
        expect(SendRoutes.guard(Uri.parse(address)), isNull, reason: address);
      }
    });

    test('turns Bluetooth away on a platform the app does not send it from',
        () {
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      expect(SendRoutes.guard(Uri.parse('/send?mode=bluetooth')),
          SendRoutes.home);
      // The two network transports have no platform condition.
      expect(SendRoutes.guard(Uri.parse('/send?mode=wifi')), isNull);
      expect(SendRoutes.guard(Uri.parse('/send?mode=internet')), isNull);
    });

    test('offers Bluetooth on every platform the old tile did', () {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.iOS,
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(SendRoutes.guard(Uri.parse('/send?mode=bluetooth')), isNull,
            reason: platform.name);
      }
    });
  });
}

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/local_hotspot_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HotspotCredentials', () {
    test('reads what the platform hands back', () {
      final credentials = HotspotCredentials.fromMap({
        'ssid': 'AndroidShare_1234',
        'passphrase': 'hunter2hunter2',
      });
      expect(credentials.ssid, equals('AndroidShare_1234'));
      expect(credentials.passphrase, equals('hunter2hunter2'));
      expect(credentials.hostAddress, isNull);
    });

    test('rejects a hotspot with no SSID rather than producing a dead QR', () {
      expect(() => HotspotCredentials.fromMap({'passphrase': 'x'}),
          throwsA(isA<HotspotException>()));
      expect(() => HotspotCredentials.fromMap({'ssid': '', 'passphrase': 'x'}),
          throwsA(isA<HotspotException>()));
    });

    test('tolerates an open network', () {
      expect(HotspotCredentials.fromMap({'ssid': 'Open'}).passphrase, isEmpty);
    });

    group('WIFI: QR payload', () {
      test('matches the format phone cameras already understand', () {
        const credentials =
            HotspotCredentials(ssid: 'QuickShare_42', passphrase: 'secret123');
        expect(credentials.toWifiQrPayload(),
            equals('WIFI:T:WPA;S:QuickShare_42;P:secret123;;'));
      });

      test('escapes the characters that would otherwise end a field', () {
        // A generated passphrase containing ; or : would truncate the payload
        // and hand the camera a malformed network.
        const credentials =
            HotspotCredentials(ssid: 'net;work', passphrase: r'pa:ss\wo"rd');
        final payload = credentials.toWifiQrPayload();
        expect(payload, contains(r'S:net\;work'));
        expect(payload, contains(r'P:pa\:ss\\wo\"rd'));
      });
    });

    test('carries the host address forward once it is discovered', () {
      const initial = HotspotCredentials(ssid: 'n', passphrase: 'p');
      final located = initial.withHost('192.168.49.1');
      expect(located.hostAddress, equals('192.168.49.1'));
      expect(located.ssid, equals('n'));
      // An unknown address must not erase one already found.
      expect(located.withHost(null).hostAddress, equals('192.168.49.1'));
    });
  });

  group('LocalHotspotService capabilities', () {
    final service = LocalHotspotService();

    test('only Android can host a network from inside the app', () {
      // iOS has no API to create one, so the roles are not symmetric and the
      // UI must not offer hosting on the wrong side.
      expect(service.canHost, equals(Platform.isAndroid));
    });

    test('refuses to host on a platform that cannot, with a usable message',
        () async {
      if (service.canHost) return;
      await expectLater(
        service.startHosting(),
        throwsA(isA<HotspotException>().having(
          (e) => e.message,
          'message',
          contains('has to host'),
        )),
      );
    });
  });

  group('platform channel contract', () {
    const channel = MethodChannel('quickshare/hotspot');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'startHotspot') {
          return {'ssid': 'QS_test', 'passphrase': 'pw'};
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('join sends the credentials the far side generated', () async {
      await LocalHotspotService(channel: channel).join(
          const HotspotCredentials(ssid: 'QS_test', passphrase: 'pw'));

      expect(calls.single.method, equals('joinHotspot'));
      expect(calls.single.arguments,
          equals({'ssid': 'QS_test', 'passphrase': 'pw'}));
    });

    test('a platform error surfaces as a HotspotException, not a raw crash',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
            code: 'JOIN_FAILED', message: 'You declined the request.');
      });

      await expectLater(
        LocalHotspotService(channel: channel)
            .join(const HotspotCredentials(ssid: 'n', passphrase: 'p')),
        throwsA(isA<HotspotException>().having(
            (e) => e.message, 'message', contains('You declined'))),
      );
    });

    test('stopHosting stays quiet when the platform cannot host', () async {
      await LocalHotspotService(channel: channel).stopHosting();
      expect(calls.where((c) => c.method == 'stopHotspot').length,
          equals(Platform.isAndroid ? 1 : 0));
    });
  });
}

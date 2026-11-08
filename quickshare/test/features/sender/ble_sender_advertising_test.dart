// An Android phone or a Windows PC that sends over Bluetooth has to be seen.
//
// The advertisement was removed from this sender by 7c6e7b9 ("sender finds
// receivers") and not put back when the list of waiting receivers went, so
// on `universal_ble` platforms `startSharing` registered nothing, advertised
// nothing, and the QR it showed pointed at a device nobody could find. These
// tests run the real transport on a fake radio and look at what it asks the
// radio to do.
//
// What the receivers look for is the service UUID in the scan filter, and,
// when the advertisement carries a `QuickShare-` name, this session's
// identifier in it. Neither has a device to be checked on here, so the second
// half of this file runs the real receiver against what the real sender
// advertised.
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_frame.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/core/transfer/ble_session.dart';
import 'package:quickshare/features/receiver/data/transports/universal_ble_receiver_transport.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';

import '../../support/fake_ble.dart';

const _file = FileMetadata(
  name: 'offer.bin',
  path: '/tmp/offer.bin',
  size: 5,
  mimeType: 'application/octet-stream',
);

void main() {
  late FakeBlePeripheral radio;
  late FakeBleCentral central;

  setUp(() {
    radio = FakeBlePeripheral();
    central = FakeBleCentral();
    UniversalBlePeripheral.setInstance(radio);
    UniversalBle.setInstance(central);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    UniversalBlePeripheral.setInstance(UniversalBlePeripheralUnsupported());
  });

  Future<BluetoothTransferTransport> started(
    BleSession session, {
    List<TransferStatus>? statuses,
  }) async {
    final transport = BluetoothTransferTransport();
    if (statuses != null) transport.statusStream.listen(statuses.add);
    await transport.initialize();
    await transport.startSharing(_file, session.token,
        locator: session.locator);
    return transport;
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    group('on ${platform.name}', () {
      final session = BleSession.generate();

      setUp(() => debugDefaultTargetPlatformOverride = platform);

      test('startSharing registers the service and advertises it', () async {
        final statuses = <TransferStatus>[];
        await started(session, statuses: statuses);
        await Future<void>.delayed(Duration.zero);

        expect(radio.registered, hasLength(1),
            reason: 'nothing was registered: a receiver connects to a '
                'server with no service in it');
        final service = radio.registered.single;
        expect(BleUuidParser.compareStrings(service.uuid, BleGatt.service),
            isTrue);

        final control = service.characteristic(BleGatt.control)!;
        expect(control.properties, contains(CharacteristicProperty.write));
        expect(control.permissions,
            contains(PeripheralAttributePermission.writeable),
            reason: 'the receiver writes START here');
        for (final id in [BleGatt.metadata, BleGatt.data]) {
          final c = service.characteristic(id)!;
          expect(c.properties, contains(CharacteristicProperty.notify),
              reason: '$id is subscribed to by the receiver');
        }

        expect(radio.advertised, hasLength(1),
            reason: 'startAdvertising was never called');
        expect(
          radio.advertised.single.services
              .any((s) => BleUuidParser.compareStrings(s, BleGatt.service)),
          isTrue,
          reason: 'the receivers scan for this UUID and nothing else',
        );
        expect(statuses, contains(TransferStatus.serving));
      });

      test('asks for the Bluetooth permissions before it starts', () async {
        await started(session);

        expect(central.permissionRequests, 1);
      });

      test('what it advertises is found by the real receiver', () async {
        await started(session);
        final advert = radio.advertised.single;

        final receiver = UniversalBleReceiverTransport();
        final found = <BleDevice>[];
        receiver.devices.listen(found.add);
        await receiver.startScanning(
            sessionToken: session.token, locator: session.locator);

        central.discover(
          id: 'AA:BB:CC:DD:EE:FF',
          name: advert.localName,
          services: advert.services,
        );
        await Future<void>.delayed(Duration.zero);

        expect(found, hasLength(1),
            reason: 'advertised ${advert.localName}, receiver is looking for '
                '${session.locator}');
        expect(central.scans.single!.withServices.map(BleUuidParser.string),
            contains(BleUuidParser.string(BleGatt.service)));
        await receiver.dispose();
      });

      test('and the advertisement fits the packet the platform allows', () {
        // Not a test of the radio; of the arithmetic that went wrong. A
        // 128-bit service UUID and `QuickShare-` plus eight characters are 42
        // bytes beside the flags, and a legacy packet holds 31.
        return started(session).then((_) {
          final advert = radio.advertised.single;
          final primary = BleAdvertisement.legacyPrimaryPacketBytes(
            serviceUuids128: advert.services.length,
            localName: advert.localName,
          );
          expect(primary, lessThanOrEqualTo(BleAdvertisement.legacyPacketLimit),
              reason: 'ADVERTISE_FAILED_DATA_TOO_LARGE on Android');
        });
      });

      test(
          'the service stays out of the scan response, where a scan filter '
          'may not look', () async {
        await started(session);

        final options = radio.advertised.single.platformConfig?.android;
        expect(options?.addServicesInScanResponse ?? false, isFalse);
      });

      test('the session is answerable: START with the token begins it',
          () async {
        final transport = await started(session);
        final ready = <void>[];
        transport.receiverReady.listen(ready.add);

        radio.write(
            'central-1', BleGatt.control, BleControlProtocol.capabilities());
        radio.write('central-1', BleGatt.control,
            BleControlProtocol.start(session.token));
        radio.subscribe('central-1', BleGatt.data);
        await Future<void>.delayed(Duration.zero);

        expect(ready, hasLength(1));
      });

      test('a START without the token is refused at the ATT layer', () async {
        await started(session);

        final answer = radio.write(
            'central-1', BleGatt.control, BleControlProtocol.start('wrong'));

        expect(
            answer?.status, BleControlProtocol.attInsufficientAuthentication);
      });

      test('stopSharing stops the advertisement and the handlers', () async {
        final transport = await started(session);

        await transport.stopSharing();

        expect(radio.stopAdvertisingCalls, greaterThanOrEqualTo(1));
        expect(radio.writeHandler, isNull);
      });

      test(
          'the service is registered once for the life of the process, not '
          'once per code', () async {
        // The Android plugin keeps a cache of characteristic objects by UUID
        // and never clears it on clearServices(), so the second registration
        // of the same service would notify through the first one's objects.
        final first = await started(session);
        await first.stopSharing();
        await started(BleSession.generate());

        expect(radio.serviceRegistrations, hasLength(1));
        expect(radio.advertised, hasLength(2));
      });
    });
  }

  group('what is on the air differs by platform, and why', () {
    test('Android puts the service UUID in the packet and no name', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final session = BleSession.generate();
      await started(session);

      expect(radio.advertised.single.localName, isNull,
          reason: 'a name would not fit beside the UUID, and setting one '
              'renames the phone\'s Bluetooth for as long as it lasts');
    });

    test('Windows cannot set a name at all', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await started(BleSession.generate());

      expect(radio.advertised.single.localName, isNull);
    });
  });

  group('when it cannot start, the person is told why', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    Future<BluetoothRadioException> failure() async {
      try {
        await started(BleSession.generate());
      } on BluetoothRadioException catch (e) {
        return e;
      }
      fail('startSharing completed although the radio could not advertise');
    }

    test('Bluetooth is off', () async {
      radio.readiness = PeripheralReadinessState.bluetoothOff;

      expect((await failure()).code, FailureCode.bluetoothOff);
    });

    test('the adapter cannot be a sender', () async {
      radio.supportsPeripheralMode = false;
      radio.readiness = PeripheralReadinessState.unsupported;

      expect((await failure()).code, FailureCode.bluetoothSendUnsupported);
    });

    test('the permission is refused', () async {
      central.permissionError = permissionsDenied();

      expect((await failure()).code, FailureCode.bluetoothPermissionDenied);
      expect(radio.advertised, isEmpty);
    });

    test('the advertise permission is refused', () async {
      radio.startAdvertisingError = PlatformException(
          code: 'bluetooth-advertise-permission-denied',
          message: 'Bluetooth advertise permission denied');

      expect((await failure()).code, FailureCode.bluetoothPermissionDenied);
    });

    test('the platform refuses the service, and says the adapter cannot',
        () async {
      // Windows: GattServiceProvider.CreateAsync on an adapter without the
      // peripheral role.
      radio.addServiceError = PlatformException(
          code: 'service-add-failed',
          message: 'Failed to create service provider: e9c1…, errorCode: '
              'NotSupported');

      expect((await failure()).code, FailureCode.bluetoothSendUnsupported);
    });

    test('the platform refuses the service because the radio went away',
        () async {
      radio.addServiceError = PlatformException(
          code: 'service-add-failed',
          message: 'Failed to create service provider: e9c1…, errorCode: '
              'RadioNotAvailable');

      expect((await failure()).code, FailureCode.bluetoothOff);
    });

    test('the platform refuses the service for a reason it gives', () async {
      radio.addServiceError = PlatformException(
          code: 'service-add-failed', message: 'Adding Service failed');

      final e = await failure();

      expect(e.code, FailureCode.bluetoothAdvertiseFailed);
      expect(e.message, contains('Adding Service failed'));
    });

    test('the platform starts, then reports that it failed', () async {
      radio.afterStart = PeripheralAdvertisingState.error;
      radio.advertisingError = 'Data too large';

      final e = await failure();

      expect(e.code, FailureCode.bluetoothAdvertiseFailed);
      expect(e.message, contains('Data too large'),
          reason: 'the platform\'s own reason is the only diagnosis there is');
    });

    test('the failed session leaves nothing advertising', () async {
      radio.afterStart = PeripheralAdvertisingState.error;
      radio.advertisingError = 'Too many advertisers';
      final transport = BluetoothTransferTransport();
      await transport.initialize();

      await expectLater(
        transport.startSharing(_file, 'tok', locator: 'abcd1234'),
        throwsA(isA<BluetoothRadioException>()),
      );

      expect(radio.stopAdvertisingCalls, greaterThanOrEqualTo(1),
          reason: 'a half-started advertiser answers "already started" to '
              'the next attempt');
    });

    test('a platform that never answers does not leave it waiting forever', () {
      fakeAsync((async) {
        radio.afterStart = null;
        Object? error;
        final transport = BluetoothTransferTransport();
        transport.initialize().then((_) => transport
            .startSharing(_file, 'tok', locator: 'abcd1234')
            .then<void>((_) {}, onError: (Object e) => error = e));

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(error, isA<BluetoothRadioException>(),
            reason: 'still waiting a minute later');
        expect((error as BluetoothRadioException).code,
            FailureCode.bluetoothAdvertiseFailed);
      });
    });
  });

  group('link frames', () {
    test('on Android they are addressed to the receiver that connected',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final transport = await started(BleSession.generate());
      radio.subscribe('client-7', BleGatt.data);
      await Future<void>.delayed(Duration.zero);

      await transport.sendLinkFrame({
        'link': {'host': 'sender'}
      });

      final sent = radio.notificationsOn(BleGatt.metadata).single;
      expect(sent.deviceId, 'client-7');
      expect(radio.framesOn(BleGatt.metadata), ['{"link":{"host":"sender"}}']);
    });

    test('on Windows they are not: the plugin refuses a targeted update',
        () async {
      // universal_ble's Windows side answers "does not support targeting a
      // specific device for notifications" to any updateCharacteristicValue
      // that names one, so every frame this sender wrote would have failed.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final transport = await started(BleSession.generate());
      radio.subscribe('client-7', BleGatt.data);
      await Future<void>.delayed(Duration.zero);

      await transport.sendLinkFrame({
        'link': {'host': 'sender'}
      });

      expect(radio.notificationsOn(BleGatt.metadata).single.deviceId, isNull);
    });

    test('Windows pairing broadcasts fit even a minimum MTU subscriber',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      radio.maxNotifyLength = 182;
      final transport = await started(BleSession.generate());
      final frame = {
        'pair': {'id': 'a' * 16, 'sealed': 's' * 100}
      };

      await transport.sendLinkFrame(frame, peerId: 'client-7');

      expect(radio.partsOn(BleGatt.metadata).map((p) => p.length),
          everyElement(lessThanOrEqualTo(20)));
      expect(radio.notificationsOn(BleGatt.metadata).map((n) => n.deviceId),
          everyElement(isNull));
      expect(radio.framesOn(BleGatt.metadata), [jsonEncode(frame)]);
    });

    test('Android pairing is targeted and uses the peer MTU', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      radio.maxNotifyLength = 182;
      final transport = await started(BleSession.generate());
      final frame = {
        'pair': {'id': 'a' * 16, 'sealed': 's' * 100}
      };

      await transport.sendLinkFrame(frame, peerId: 'client-7');

      expect(radio.notificationsOn(BleGatt.metadata), hasLength(1));
      expect(
          radio.notificationsOn(BleGatt.metadata).single.deviceId, 'client-7');
      expect(radio.framesOn(BleGatt.metadata), [jsonEncode(frame)]);
    });

    test(
        'one that is longer than a notification goes out in parts, none of '
        'them longer than it', () async {
      // The platforms cut a notification to the negotiated payload without
      // saying so, and the receiver then fails to read half a JSON document.
      // So nothing longer than the limit is ever asked for.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      radio.maxNotifyLength = 20;
      final transport = await started(BleSession.generate());
      radio.subscribe('client-7', BleGatt.data);
      await Future<void>.delayed(Duration.zero);
      final frame = {
        'link': {'host': 'sender', 'sealed': 'x' * 60}
      };

      await transport.sendLinkFrame(frame);

      final parts = radio.partsOn(BleGatt.metadata);
      expect(parts.length, greaterThan(1));
      expect(parts.map((p) => p.length), everyElement(lessThanOrEqualTo(20)));
      expect(radio.framesOn(BleGatt.metadata), [jsonEncode(frame)],
          reason: 'put back together, it is what was sent');
    });
  });

  group('a frame is cut for what the connection carries', () {
    // The numbers are the ones the owner asked about: the directive that
    // carries credentials is 203 bytes with a 12-character passphrase, the
    // serve frame 225, an iPhone takes 182, a connection nobody negotiated 20.
    final directive = {
      'link': {'host': 'sender', 'sealed': 's' * 112, 'kex': 'k' * 44}
    };
    final serve = {
      'serve': {
        'ip': '192.168.137.1',
        'port': 54321,
        'token': 't' * 32,
        'tf': 'f' * 43,
        'fn': 'Vacation photos',
        'fs': 123456789,
        'ic': 12,
        'sn': "Farman's PC",
        'lip': '192.168.1.10',
      }
    };

    Future<BluetoothTransferTransport> connected(
        {int? limit, TargetPlatform? platform, Duration? pacing}) async {
      debugDefaultTargetPlatformOverride = platform ?? TargetPlatform.android;
      radio.maxNotifyLength = limit;
      final transport = BluetoothTransferTransport(
          notificationPacing: pacing ?? Duration.zero);
      await transport.initialize();
      final session = BleSession.generate();
      await transport.startSharing(_file, session.token,
          locator: session.locator);
      radio.subscribe('client-7', BleGatt.data);
      await Future<void>.delayed(Duration.zero);
      return transport;
    }

    test('the sizes: 203 bytes in two parts at an iPhone\'s 182, 225 in two',
        () async {
      final transport = await connected(limit: 182);

      expect(utf8.encode(jsonEncode(directive)), hasLength(203));
      await transport.sendLinkFrame(directive);
      final directiveParts = radio.notifications.length;
      expect(utf8.encode(jsonEncode(serve)), hasLength(225));
      await transport.sendLinkFrame(serve);

      expect(directiveParts, 2, reason: '203 bytes is 178 + 25 of payload');
      expect(radio.notifications.length - directiveParts, 2);
      expect(radio.partsOn(BleGatt.metadata).map((p) => p.length),
          everyElement(lessThanOrEqualTo(182)));
      expect(radio.framesOn(BleGatt.metadata),
          [jsonEncode(directive), jsonEncode(serve)]);
    });

    test(
        'the sizes: 14 and 15 parts of 20 bytes on a connection nobody '
        'negotiated', () async {
      final transport = await connected(limit: 20);

      await transport.sendLinkFrame(directive);
      final directiveParts = radio.notifications.length;
      await transport.sendLinkFrame(serve);

      expect(directiveParts, 13, reason: '203 bytes at 16 a part');
      expect(radio.notifications.length - directiveParts, 15,
          reason: '225 bytes at 16 a part');
      expect(radio.framesOn(BleGatt.metadata),
          [jsonEncode(directive), jsonEncode(serve)]);
    });

    test('the sizes: one part each at 244 and 512', () async {
      for (final limit in [244, 512]) {
        radio.notifications.clear();
        final transport = await connected(limit: limit);

        await transport.sendLinkFrame(directive);
        await transport.sendLinkFrame(serve);

        expect(radio.notifications, hasLength(2), reason: 'limit $limit');
        expect(radio.partsOn(BleGatt.metadata).map((p) => p.length),
            [203 + 4, 225 + 4]);
        await transport.stopSharing();
      }
    });

    test('the serve frame goes whole: nothing optional is dropped', () async {
      final transport = await connected(limit: 182);

      await transport.sendLinkFrame(serve);

      final got = jsonDecode(radio.framesOn(BleGatt.metadata).single) as Map;
      expect(got['serve'], serve['serve']);
    });

    test(
        'an unknown limit is the least a connection carries, on Android and '
        'on Windows alike', () async {
      for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
        radio.notifications.clear();
        final transport = await connected(limit: null, platform: platform);

        await transport.sendLinkFrame(directive);

        expect(radio.partsOn(BleGatt.metadata).map((p) => p.length),
            everyElement(lessThanOrEqualTo(20)),
            reason: platform.name);
        expect(radio.framesOn(BleGatt.metadata), [jsonEncode(directive)]);
        await transport.stopSharing();
      }
    });

    test(
        'a limit the platform makes up is not believed past what an '
        'attribute can be', () async {
      final transport = await connected(limit: 100000);

      await transport.sendLinkFrame({
        'serve': {...(serve['serve'] as Map), 'fn': 'n' * 1500}
      });

      expect(radio.partsOn(BleGatt.metadata).map((p) => p.length),
          everyElement(lessThanOrEqualTo(512)));
    });

    test('a frame beyond the largest there is is refused, and nothing is sent',
        () async {
      final transport = await connected(limit: 512);

      await expectLater(
        transport.sendLinkFrame({
          'serve': {'fn': 'x' * 4000}
        }),
        throwsA(isA<BluetoothRadioException>()
            .having((e) => e.message, 'message', contains('3072'))),
      );
      expect(radio.notifications, isEmpty);
    });

    test('a connection too small to hold a header says so, and sends nothing',
        () async {
      final transport = await connected(limit: 4);

      await expectLater(
        transport.sendLinkFrame(directive),
        throwsA(isA<BluetoothRadioException>()
            .having((e) => e.message, 'message', contains('4 bytes'))),
      );
      expect(radio.notifications, isEmpty);
    });

    test(
        'a connection so small the frame would need more than 255 parts is '
        'refused', () async {
      // One byte of payload a part, and a frame of more than 255 bytes.
      final transport = await connected(limit: 5);

      await expectLater(
        transport.sendLinkFrame({
          'link': {'host': 'sender', 'sealed': 's' * 300}
        }),
        throwsA(isA<BluetoothRadioException>()
            .having((e) => e.message, 'message', contains('255'))),
      );
      expect(radio.notifications, isEmpty);
    });

    test(
        'two frames asked for at once are sent one after the other, never '
        'mixed', () async {
      final transport = await connected(limit: 20);

      await Future.wait([
        transport.sendLinkFrame(directive),
        transport.sendLinkFrame(serve),
        transport.sendLinkFrame(directive),
      ]);

      expect(radio.framesOn(BleGatt.metadata),
          [jsonEncode(directive), jsonEncode(serve), jsonEncode(directive)]);
    });

    test('a frame that fails does not stop the ones after it', () async {
      final transport = await connected(limit: 512);

      await expectLater(
        transport.sendLinkFrame({
          'serve': {'fn': 'x' * 4000}
        }),
        throwsA(isA<BluetoothRadioException>()),
      );
      await transport.sendLinkFrame(directive);

      expect(radio.framesOn(BleGatt.metadata), [jsonEncode(directive)]);
    });

    test('every frame has a number of its own, and every part of it the same',
        () async {
      final transport = await connected(limit: 20);

      await transport.sendLinkFrame(directive);
      await transport.sendLinkFrame(directive);

      final parts = radio.partsOn(BleGatt.metadata);
      final ids = {for (final p in parts) p[1]};
      expect(ids, hasLength(2));
      expect(parts.first[0], BleFrame.marker);
      expect(parts.first[2], 0, reason: 'a frame starts at part 0');
      expect(parts.first[3], parts.where((p) => p[1] == parts.first[1]).length);
    });

    test(
        'the parts are spaced where the platform does not wait for the '
        'radio, and not where it does', () async {
      final spaced =
          await connected(limit: 20, pacing: const Duration(milliseconds: 25));
      final times = <DateTime>[];
      radio.onNotification = (_) => times.add(DateTime.now());

      await spaced.sendLinkFrame(directive);

      expect(times.length, greaterThan(5));
      for (var i = 1; i < times.length; i++) {
        expect(times[i].difference(times[i - 1]).inMilliseconds,
            greaterThanOrEqualTo(20),
            reason: 'part $i went before the radio could have taken part '
                '${i - 1}');
      }
    });

    test(
        'Android spaces them by default; Windows, whose plugin awaits each '
        'notification, does not', () async {
      final android = BluetoothTransferTransport();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(android.debugPacing, greaterThan(Duration.zero));
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(android.debugPacing, Duration.zero);
    });
  });

  test('on Android a central that never negotiated is on the 23-byte default',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    radio.maxNotifyLength = null;
    final transport = await started(BleSession.generate());
    radio.subscribe('client-7', BleGatt.data);
    await Future<void>.delayed(Duration.zero);
    final frame = {
      'link': {'host': 'sender', 'sealed': 'x' * 60}
    };

    await transport.sendLinkFrame(frame);

    expect(radio.partsOn(BleGatt.metadata).map((p) => p.length),
        everyElement(lessThanOrEqualTo(20)));
    expect(radio.framesOn(BleGatt.metadata), [jsonEncode(frame)]);
  });

  test('a HELLO is read, so the sender knows who it is talking to', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final transport = await started(BleSession.generate());

    radio.write(
        'c', BleGatt.control, BleControlProtocol.hello("Anna's iPhone"));

    expect(transport.receiverName, "Anna's iPhone");
  });
}

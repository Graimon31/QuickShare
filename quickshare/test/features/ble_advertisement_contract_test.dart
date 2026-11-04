// What every sender puts on the air is what every receiver looks for.
//
// Five implementations speak the Bluetooth rendezvous: CoreBluetooth on iOS
// and macOS, `universal_ble` on Android and Windows, BlueZ on Linux. Nothing
// ties them together except a few strings they each repeat — a service UUID,
// a `QuickShare-` name — and a pair of devices is the only thing that could
// tell if one of them drifted. This pins them to the same text, runs the
// Dart receiver's real filter against what the Dart senders really advertise,
// and holds the Swift receivers to the same rule by reading it.
//
// Every sender platform against every receiver platform: the senders are
// Android, Windows, macOS, iOS and Linux; the receivers a phone can be are
// Android and iOS.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/features/receiver/data/transports/universal_ble_receiver_transport.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

import '../support/fake_ble.dart';

String _read(String path) => File(path).readAsStringSync();

final _uuid = RegExp(r'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B1([0-3])',
    caseSensitive: false);

void main() {
  group('the GATT layout is the same text in every implementation', () {
    final sources = {
      'Linux sender': _read(
          'lib/features/sender/data/transports/linux_bluetooth_sender.dart'),
      'macOS bridge': _read('macos/Runner/QuickShareBluetooth.swift'),
      'iOS bridge': _read('ios/Runner/QuickShareBluetooth.swift'),
    };
    final want = {
      '0': BleGatt.service,
      '1': BleGatt.control,
      '2': BleGatt.metadata,
      '3': BleGatt.data,
    };

    for (final entry in sources.entries) {
      test('${entry.key} names the same service and characteristics', () {
        final found = {
          for (final m in _uuid.allMatches(entry.value))
            m.group(1)!: m.group(0)!.toUpperCase(),
        };
        expect(found['0'], want['0'], reason: 'service UUID');
        // The Linux sender registers its characteristics from the same
        // constants a different way; the Apple bridges name all three.
        if (entry.key != 'Linux sender') {
          for (final k in ['1', '2', '3']) {
            expect(found[k], want[k], reason: 'characteristic $k');
          }
        }
      });
    }

    test('the Dart ends read them from one place', () {
      for (final path in [
        'lib/features/sender/data/transports/bluetooth_transfer_transport.dart',
        'lib/features/receiver/data/transports/universal_ble_receiver_transport.dart',
      ]) {
        expect(_read(path), isNot(contains(_uuid)),
            reason: '$path repeats a UUID instead of using BleGatt');
      }
    });
  });

  group('the name, where there is one', () {
    test('the Apple senders advertise QuickShare-<publicId>', () {
      for (final path in [
        'macos/Runner/QuickShareBluetooth.swift',
        'ios/Runner/QuickShareBluetooth.swift',
      ]) {
        final text = _read(path);
        expect(text, contains(r'"QuickShare-\(publicId)"'), reason: path);
        expect(text, contains('"QuickShare-directdrop"'), reason: path);
      }
      expect(BleAdvertisement.nameFor('ABCD1234'), 'QuickShare-ABCD1234');
      expect(BleAdvertisement.nameFor(''), 'QuickShare-directdrop');
    });

    test('so does the Linux sender', () {
      expect(
          _read('lib/features/sender/data/transports/linux_bluetooth_sender.dart'),
          contains(r"'QuickShare-${publicId.isNotEmpty ? publicId : 'directdrop'}'"));
    });

    test('the Apple receivers apply the rule the Dart receiver does', () {
      for (final path in [
        'macos/Runner/QuickShareBluetooth.swift',
        'ios/Runner/QuickShareBluetooth.swift',
      ]) {
        final text = _read(path);
        final start = text.indexOf('didDiscover peripheral');
        expect(start, isNonNegative, reason: path);
        final body = text.substring(start, start + 1400);
        // A name that carries a locator has to carry this session's. One that
        // does not carry a locator at all passes — a Windows PC has none.
        expect(body, contains('hasPrefix("QuickShare-")'), reason: path);
        expect(body, contains('contains(expectedPublicId)'), reason: path);
      }
    });
  });

  group('every sender is found by every receiver', () {
    final code = SessionCode.generate();
    final other = SessionCode.generate();

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

    /// The name each sender platform advertises for [session], the Dart ones
    /// by running them and the native ones by what the sources above hold
    /// them to.
    Future<String?> advertisedBy(TargetPlatform platform, SessionCode session) async {
      switch (platform) {
        case TargetPlatform.android:
        case TargetPlatform.windows:
          debugDefaultTargetPlatformOverride = platform;
          radio.advertised.clear();
          final transport = BluetoothTransferTransport();
          await transport.initialize();
          await transport.startSharing(
            const FileMetadata(
                name: 'a', path: '/tmp/a', size: 1, mimeType: 'text/plain'),
            session.sessionToken,
            publicId: session.publicId,
          );
          await transport.stopSharing();
          return radio.advertised.single.localName;
        case TargetPlatform.macOS:
        case TargetPlatform.iOS:
        case TargetPlatform.linux:
          return BleAdvertisement.nameFor(session.publicId);
        case TargetPlatform.fuchsia:
          return null;
      }
    }

    for (final sender in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.iOS,
      TargetPlatform.linux,
    ]) {
      group('${sender.name} sends', () {
        test('and an Android phone scanning for it connects', () async {
          final name = await advertisedBy(sender, code);
          debugDefaultTargetPlatformOverride = null;

          final receiver = UniversalBleReceiverTransport();
          final found = <BleDevice>[];
          receiver.devices.listen(found.add);
          await receiver.startScanning(
              sessionToken: code.sessionToken, publicId: code.publicId);
          central.discover(
              id: 'peer', name: name, services: [BleGatt.service]);
          await Future<void>.delayed(Duration.zero);
          await receiver.dispose();

          expect(found, hasLength(1), reason: 'advertised "$name"');
        });

        test('and an iPhone scanning for it connects', () async {
          final name = await advertisedBy(sender, code);

          expect(
            BleAdvertisement.accepts(
              advertisedName: name,
              publicId: code.publicId,
              sessionToken: code.sessionToken,
            ),
            isTrue,
            reason: 'advertised "$name"',
          );
        });

        test('and a phone looking for a different session does not connect '
            'to a name that is plainly another one', () async {
          final name = await advertisedBy(sender, other);
          debugDefaultTargetPlatformOverride = null;
          if (name == null) return; // nothing on the air to tell apart

          final receiver = UniversalBleReceiverTransport();
          final found = <BleDevice>[];
          receiver.devices.listen(found.add);
          await receiver.startScanning(
              sessionToken: code.sessionToken, publicId: code.publicId);
          central.discover(
              id: 'peer', name: name, services: [BleGatt.service]);
          await Future<void>.delayed(Duration.zero);
          await receiver.dispose();

          expect(found, isEmpty, reason: 'advertised "$name"');
          expect(
            BleAdvertisement.accepts(
                advertisedName: name,
                publicId: code.publicId,
                sessionToken: code.sessionToken),
            isFalse,
          );
        });
      });
    }
  });

  group('the rule itself', () {
    test('an unnamed or foreign-named device is accepted: the token decides',
        () {
      for (final name in [null, '', 'DESKTOP-4F2A', 'Pixel 9', 'QuickShare']) {
        expect(BleAdvertisement.accepts(advertisedName: name, publicId: 'ABCD1234'),
            isTrue,
            reason: '"$name"');
      }
    });

    test('a locator for another session is not', () {
      expect(
          BleAdvertisement.accepts(
              advertisedName: 'QuickShare-ZZZZ9999', publicId: 'ABCD1234'),
          isFalse);
      expect(
          BleAdvertisement.accepts(
              advertisedName: 'QuickShare-ABCD1234', publicId: 'ABCD1234'),
          isTrue);
    });

    test('a QR from a build with no identifier falls back to the token', () {
      expect(
          BleAdvertisement.accepts(
              advertisedName: 'QuickShare-0123abcd', sessionToken: '0123abcdffff'),
          isTrue);
      expect(
          BleAdvertisement.accepts(
              advertisedName: 'QuickShare-99999999', sessionToken: '0123abcdffff'),
          isFalse);
    });

    test('a packet that cannot hold the UUID and the name is measured as '
        'too big', () {
      // What the old Android code asked for.
      expect(
        BleAdvertisement.legacyPrimaryPacketBytes(
          serviceUuids128: 1,
          localName: BleAdvertisement.nameFor('ABCD1234'),
        ),
        greaterThan(BleAdvertisement.legacyPacketLimit),
      );
      expect(
        BleAdvertisement.legacyPrimaryPacketBytes(serviceUuids128: 1),
        lessThanOrEqualTo(BleAdvertisement.legacyPacketLimit),
      );
    });
  });
}

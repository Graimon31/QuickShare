// What every sender puts on the air is what every receiver looks for.
//
// Five implementations speak the Bluetooth rendezvous: CoreBluetooth on iOS
// and macOS, `universal_ble` on Android and Windows, BlueZ on Linux. Nothing
// ties them together except a few strings they each repeat — a service UUID,
// a `QuickShare-` name, the protocol generation — and a pair of devices is the
// only thing that could tell if one of them drifted. This pins them to the same
// text, runs the Dart receiver's real filter against what the Dart senders
// really advertise, and holds the Swift receivers to the same rule by reading
// it.
//
// What the name carries is a random locator, drawn for the session and related
// to nothing: no code, no token, no network name. It used to be a hash of the
// session code's digits, which anyone in radio range could search for them.
//
// Every sender platform against every receiver platform: the senders are
// Android, Windows, macOS, iOS and Linux; the receivers a phone can be are
// Android and iOS.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/core/transfer/ble_session.dart';
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

  group('the protocol generation is one number in every implementation', () {
    // A sender refuses a receiver below its generation and a receiver refuses a
    // directive from an older one; if the Swift bridges drifted from the Dart
    // constant, an iPhone and an Android phone would either refuse each other
    // for no reason or carry on into a negotiation neither can finish.
    for (final path in [
      'macos/Runner/QuickShareBluetooth.swift',
      'ios/Runner/QuickShareBluetooth.swift',
    ]) {
      test('$path announces and requires generation '
          '${BleControlProtocol.generation}', () {
        expect(_read(path),
            contains('static let generation = ${BleControlProtocol.generation}'));
      });

      test('$path refuses an older receiver in the same words as Dart', () {
        // Swift splits the sentence across string literals; compare it whole.
        final text = _read(path)
            .replaceAll(RegExp(r'"\s*\+\s*"'), '')
            .replaceAll(RegExp(r'"\s*\n\s*\+\s*"'), '');
        expect(text, contains(BleControlProtocol.directLinkRequiredMessage),
            reason: path);
      });
    }

    test('the Apple bridges take the session locator under that name, and '
        'never under the old one', () {
      for (final path in [
        'macos/Runner/QuickShareBluetooth.swift',
        'ios/Runner/QuickShareBluetooth.swift',
      ]) {
        final text = _read(path);
        expect(text, contains('["locator"]'), reason: path);
        expect(text, isNot(contains('publicId')),
            reason: '$path still names the value the way it was when it was '
                'worked out from the code');
      }
    });
  });

  group('the name, where there is one', () {
    test('the Apple senders advertise QuickShare-<locator>', () {
      for (final path in [
        'macos/Runner/QuickShareBluetooth.swift',
        'ios/Runner/QuickShareBluetooth.swift',
      ]) {
        final text = _read(path);
        expect(text, contains(r'"QuickShare-\(locator)"'), reason: path);
        expect(text, contains('"QuickShare-directdrop"'), reason: path);
      }
      expect(BleAdvertisement.nameFor('ABCD1234'), 'QuickShare-ABCD1234');
      expect(BleAdvertisement.nameFor(''), 'QuickShare-directdrop');
    });

    test('so does the Linux sender', () {
      expect(
          _read('lib/features/sender/data/transports/linux_bluetooth_sender.dart'),
          contains(r"'QuickShare-${locator.isNotEmpty ? locator : 'directdrop'}'"));
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
        expect(body, contains('contains(expectedLocator)'), reason: path);
      }
    });
  });

  group('every sender is found by every receiver', () {
    final session = BleSession.generate();
    final other = BleSession.generate();

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
    Future<String?> advertisedBy(TargetPlatform platform, BleSession session) async {
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
            session.token,
            locator: session.locator,
          );
          await transport.stopSharing();
          return radio.advertised.single.localName;
        case TargetPlatform.macOS:
        case TargetPlatform.iOS:
        case TargetPlatform.linux:
          return BleAdvertisement.nameFor(session.locator);
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
          final name = await advertisedBy(sender, session);
          debugDefaultTargetPlatformOverride = null;

          final receiver = UniversalBleReceiverTransport();
          final found = <BleDevice>[];
          receiver.devices.listen(found.add);
          await receiver.startScanning(
              sessionToken: session.token, locator: session.locator);
          central.discover(
              id: 'peer', name: name, services: [BleGatt.service]);
          await Future<void>.delayed(Duration.zero);
          await receiver.dispose();

          expect(found, hasLength(1), reason: 'advertised "$name"');
        });

        test('and an iPhone scanning for it connects', () async {
          final name = await advertisedBy(sender, session);

          expect(
            BleAdvertisement.accepts(
              advertisedName: name,
              locator: session.locator,
              sessionToken: session.token,
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
              sessionToken: session.token, locator: session.locator);
          central.discover(
              id: 'peer', name: name, services: [BleGatt.service]);
          await Future<void>.delayed(Duration.zero);
          await receiver.dispose();

          expect(found, isEmpty, reason: 'advertised "$name"');
          expect(
            BleAdvertisement.accepts(
                advertisedName: name,
                locator: session.locator,
                sessionToken: session.token),
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
        expect(BleAdvertisement.accepts(advertisedName: name, locator: 'ABCD1234'),
            isTrue,
            reason: '"$name"');
      }
    });

    test('a locator for another session is not', () {
      expect(
          BleAdvertisement.accepts(
              advertisedName: 'QuickShare-ZZZZ9999', locator: 'ABCD1234'),
          isFalse);
      expect(
          BleAdvertisement.accepts(
              advertisedName: 'QuickShare-ABCD1234', locator: 'ABCD1234'),
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

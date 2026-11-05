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
import 'package:quickshare/core/transfer/ble_frame.dart';
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

  group('the frame format is one thing in every implementation', () {
    // A frame longer than a notification crosses as parts (see `BleFrame`),
    // and five implementations cut them or put them together. The Swift ones
    // are exercised by compiling their pure part against Dart in
    // `ble_frame_swift_test.dart`; this holds the rest of them to the same
    // words and the same constants, and the CoreBluetooth half — which only a
    // device can run — to the behaviour it has to have.
    final swift = {
      'macOS bridge': _read('macos/Runner/QuickShareBluetooth.swift'),
      'iOS bridge': _read('ios/Runner/QuickShareBluetooth.swift'),
    };

    String region(String text) {
      final from = text.indexOf('// MARK: - BEGIN QuickShareBleFrame');
      const end = '// MARK: - END QuickShareBleFrame';
      final to = text.indexOf(end);
      expect(from, isNonNegative);
      expect(to, greaterThan(from));
      return text.substring(from, to + end.length);
    }

    /// The Swift source with its string literals joined the way the compiler
    /// joins them, so a sentence split across lines can be searched for.
    String joined(String text) => text
        .replaceAll(RegExp(r'"\s*\n\s*\+\s*"'), '')
        .replaceAll(RegExp(r'"\s*\+\s*"'), '');

    test('the format code is the same text in both Apple bridges', () {
      expect(region(swift['iOS bridge']!), region(swift['macOS bridge']!));
    });

    test('and says the same numbers as Dart', () {
      final text = region(swift['macOS bridge']!);
      int number(String name) {
        final m = RegExp('static let $name(?:: \\w+)? = (0x[0-9A-Fa-f]+|\\d+)')
            .firstMatch(text);
        expect(m, isNotNull, reason: 'no $name in the Swift region');
        return int.parse(m!.group(1)!);
      }

      expect(number('marker'), BleFrame.marker);
      expect(number('headerBytes'), BleFrame.headerBytes);
      expect(number('maxParts'), BleFrame.maxParts);
      expect(number('maxFrameBytes'), BleFrame.maxFrameBytes);
      expect(number('maxNotificationBytes'), BleFrame.maxNotificationBytes);
      expect(number('defaultNotificationBytes'),
          BleFrame.defaultNotificationBytes);
      expect(number('assemblyTimeout'), BleFrame.assemblyTimeout.inSeconds);
      expect(text, contains('first == 0x7B'),
          reason: 'what bare JSON starts with');
    });

    test('and names every problem Dart does, by the same word', () {
      final text = region(swift['macOS bridge']!);
      for (final problem in BleFrameProblem.values) {
        expect(text, contains(problem.name),
            reason: 'Swift has no ${problem.name}');
      }
    });

    for (final entry in swift.entries) {
      group(entry.key, () {
        final text = joined(entry.value);

        test('says a frame is lost or damaged in the words Dart does', () {
          expect(text, contains(BleFrame.damagedMessage));
        });

        test('says "an older version" only for an unframed sender or bytes on '
            'the data characteristic', () {
          // Every call, not the definition.
          final calls = RegExp(r'(?<!func )refuseStaleSender\(\)')
              .allMatches(text)
              .length;
          expect(calls, 2,
              reason: 'one from refuseFrame (guarded by isOlderSender), one '
                  'for bytes on the data characteristic');
          final refuse = text.substring(text.indexOf('func refuseFrame'));
          expect(refuse.substring(0, 200), contains('fault.isOlderSender'));
          // The metadata branch hands everything to the assembler and does not
          // judge by itself.
          final update = text.indexOf('didUpdateValueFor characteristic');
          final metadata = text.substring(update);
          final branch = metadata.substring(
              0, metadata.indexOf('characteristic.uuid == '
                  '${entry.key == 'iOS bridge' ? 'QuickShareBluetoothIDs' : 'BTServiceIDs'}.data'));
          expect(branch, contains('acceptFramePart(value)'));
          expect(branch, isNot(contains('refuseStaleSender')),
              reason: 'a cut or unreadable frame was called "an older sender"');
        });

        test('refuses a damaged frame with its own code, not the old-version '
            'one', () {
          final damaged = text.substring(text.indexOf('func refuseDamagedFrame'));
          expect(damaged.substring(0, 500), contains('bluetoothTransferFailed'));
          expect(damaged.substring(0, 500),
              isNot(contains('senderTooOldForDirectLink')));
        });

        test('keeps a part the radio would not take and sends it when the '
            'radio is ready', () {
          expect(text, contains('peripheralManagerIsReady'));
          // The result of updateValue decides whether a part leaves the queue.
          expect(text, contains('if !manager.updateValue('));
          final drain = text.substring(text.indexOf('func drainOutbox'));
          final body = drain.substring(0, drain.indexOf('func armOutboxWatchdog'));
          expect(body.indexOf('updateValue'), lessThan(body.indexOf('removeFirst')),
              reason: 'a part is taken off the queue only after the radio took it');
          expect(text, isNot(contains('"BUSY"')),
              reason: 'a full queue is waited out, not handed back to Dart');
        });

        test('cuts to what the subscribed receiver can take, and not to a '
            'number of its own', () {
          expect(text, contains('maximumUpdateValueLength'));
          expect(text, contains('QuickShareBleFrame.split('));
          expect(text, isNot(contains('updateValue(data')),
              reason: 'a whole frame is not sent as one notification');
        });

        test('gives up on a radio that never becomes ready, and on a receiver '
            'that goes away, instead of keeping the frame for ever', () {
          expect(text, contains('armOutboxWatchdog'));
          expect(text, contains('failOutbox(code: "TIMEOUT"'));
          expect(text, contains('failOutbox(code: "UNAVAILABLE"'));
        });

        test('starts each connection with an empty assembler', () {
          expect(RegExp(r'resetFrames\(\)').allMatches(text).length,
              greaterThanOrEqualTo(4),
              reason: 'connect, cancel, disconnect and its definition');
        });
      });
    }

    test('the Linux sender cuts to the MTU BlueZ reports on a write', () {
      final linux = _read(
          'lib/features/sender/data/transports/linux_bluetooth_sender.dart');
      expect(linux, contains('BleFrameSplitter'));
      expect(linux, contains('mtuOfWrite'));
      expect(linux, contains("entry.key.asString() == 'mtu'"));
      expect(linux, isNot(contains('utf8.encode(jsonEncode(frame))));')),
          reason: 'a whole frame is not one notification');
    });

    test('no Dart sender drops a field to make a frame fit', () {
      final transport = _read(
          'lib/features/sender/data/transports/bluetooth_transfer_transport.dart');
      expect(transport, isNot(contains('_withoutOptionalFields')));
      expect(transport, isNot(contains("'lip', 'sn', 'fn'")));
    });

    test('the sender in Dart reads the limit from the platform', () {
      final transport = _read(
          'lib/features/sender/data/transports/bluetooth_transfer_transport.dart');
      expect(transport, contains('getMaximumNotifyLength'));
      expect(transport, contains('BleFrame.defaultNotificationBytes'));
    });

    test('the generation is still 5: nothing here changes what a peer must '
        'support to be told apart from an older one', () {
      // Generation 5 has not been released anywhere. A build made from the
      // commit before the parts sends bare JSON, which a current receiver
      // recognises and answers with the update message; raising the number
      // would add nothing that message does not already say.
      expect(BleControlProtocol.generation, 5);
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

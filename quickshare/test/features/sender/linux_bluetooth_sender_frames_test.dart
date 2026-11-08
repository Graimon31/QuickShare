// The Linux sender cuts a frame for the connection BlueZ has negotiated.
//
// BlueZ cannot be run here, but the two things the sender gets from it can be:
// the `mtu` in the options of every write the receiver makes, and a
// characteristic to push `Value` changes to. Both are stood in for.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/transfer/ble_frame.dart';
import 'package:quickshare/features/sender/data/transports/linux_bluetooth_sender.dart';

void main() {
  group('what a notification carries', () {
    test('is the negotiated MTU less the three bytes of ATT header', () {
      expect(LinuxBluetoothSender.notificationBytes(185), 182,
          reason: 'an iPhone');
      expect(LinuxBluetoothSender.notificationBytes(247), 244,
          reason: 'an Android phone that asked for 247');
      expect(LinuxBluetoothSender.notificationBytes(23), 20,
          reason: 'the default nobody negotiated away from');
    });

    test('is the least a connection carries when BlueZ has not said', () {
      expect(LinuxBluetoothSender.notificationBytes(null), 20);
    });

    test('is never a number that cannot be right', () {
      expect(LinuxBluetoothSender.notificationBytes(0), 20);
      expect(LinuxBluetoothSender.notificationBytes(3), 20);
      expect(LinuxBluetoothSender.notificationBytes(-5), 20);
      expect(LinuxBluetoothSender.notificationBytes(100000), 512,
          reason: 'an attribute value is at most 512 bytes');
    });
  });

  group('the MTU in the options of a write', () {
    DBusValue options(Map<String, DBusValue> entries) =>
        DBusDict.stringVariant(entries);

    test('is read when BlueZ gives one', () {
      expect(
          LinuxBluetoothSender.mtuOfWrite([
            DBusArray.byte(const [1, 2]),
            options(
                {'mtu': const DBusUint16(185), 'link': const DBusString('LE')}),
          ]),
          185);
    });

    test('is not there when it is not said', () {
      expect(
          LinuxBluetoothSender.mtuOfWrite([
            DBusArray.byte(const [1]),
            options({'link': const DBusString('LE')}),
          ]),
          isNull);
      expect(
          LinuxBluetoothSender.mtuOfWrite([
            DBusArray.byte(const [1])
          ]),
          isNull);
      expect(LinuxBluetoothSender.mtuOfWrite(const []), isNull);
    });

    test('is not guessed from something that is not a number', () {
      expect(
          LinuxBluetoothSender.mtuOfWrite([
            DBusArray.byte(const [1]),
            options({'mtu': const DBusString('185')}),
          ]),
          isNull);
      expect(
          LinuxBluetoothSender.mtuOfWrite([
            DBusArray.byte(const [1]),
            const DBusString('not a dictionary'),
          ]),
          isNull);
    });
  });

  group('pairing write sources and control frames', () {
    test('extracts only an actual BlueZ device object path', () {
      final bytes = DBusArray.byte(const [1]);
      const path = '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF';
      expect(
          LinuxBluetoothSender.peerOfWrite([
            bytes,
            DBusDict.stringVariant({'device': DBusObjectPath(path)})
          ]),
          path);
      expect(
          LinuxBluetoothSender.peerOfWrite([
            bytes,
            DBusDict.stringVariant({'device': const DBusString('fake')})
          ]),
          isEmpty);
      expect(LinuxBluetoothSender.peerOfWrite([bytes]), isEmpty);
    });

    test(
        'isolates peers and recovers slots after malformed and oversized frames',
        () async {
      final sender = LinuxBluetoothSender();
      final received = <String, String>{};
      void accept(String peer, String command) => received[peer] = command;
      for (var n = 0; n < 10; n++) {
        sender.debugAcceptPairingPart(
            'bad-$n', Uint8List.fromList([BleFrame.marker, 1]), accept);
      }
      final splitter = BleFrameSplitter();
      final a = splitter.split(
          Uint8List.fromList(utf8.encode('PAIR:${'a' * 100}')),
          notificationBytes: 20);
      final b = splitter.split(
          Uint8List.fromList(utf8.encode('PAIR:${'b' * 100}')),
          notificationBytes: 20);
      for (var n = 0; n < a.length; n++) {
        sender.debugAcceptPairingPart('a', a[n], accept);
        sender.debugAcceptPairingPart('b', b[n], accept);
      }
      expect(received, {'a': 'PAIR:${'a' * 100}', 'b': 'PAIR:${'b' * 100}'});
      final over = splitter.split(
          Uint8List.fromList(utf8.encode('PAIR:${'x' * 176}')),
          notificationBytes: 20);
      for (final part in over) {
        sender.debugAcceptPairingPart('a', part, accept);
      }
      expect(received['a'], 'PAIR:${'a' * 100}');
      final again = splitter.split(Uint8List.fromList(utf8.encode('PAIR:ok')),
          notificationBytes: 20);
      for (final part in again) {
        sender.debugAcceptPairingPart('a', part, accept);
      }
      expect(received['a'], 'PAIR:ok');
      await sender.stop();
    });
  });

  group('a frame is cut for it', () {
    final directive = jsonEncode({
      'link': {'host': 'sender', 'sealed': 's' * 112, 'kex': 'k' * 44}
    });
    final serve = jsonEncode({
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
    });

    late LinuxBluetoothSender sender;
    late List<Uint8List> parts;

    setUp(() {
      sender = LinuxBluetoothSender();
      parts = [];
      sender.debugEmit = (part) async => parts.add(Uint8List.fromList(part));
    });

    List<String> whole() {
      final frames = <String>[];
      final assembler = BleFrameAssembler(
          onFrame: (f) => frames.add(utf8.decode(f)),
          onFault: (e) => fail(e.message));
      parts.forEach(assembler.add);
      assembler.dispose();
      return frames;
    }

    Map<String, Object?> asMap(String json) =>
        jsonDecode(json) as Map<String, Object?>;

    test(
        'an iPhone\'s 185-byte MTU: two parts of at most 182 for each of '
        'the two big frames, and they come out whole', () async {
      sender.debugPeerMtu = 185;

      await sender.notifyLinkFrame(asMap(directive));
      await sender.notifyLinkFrame(asMap(serve));

      expect(parts, hasLength(4));
      expect(parts.map((p) => p.length), everyElement(lessThanOrEqualTo(182)));
      expect(whole(), [directive, serve]);
    });

    test('an MTU nobody reported: parts of at most 20', () async {
      await sender.notifyLinkFrame(asMap(directive));
      await sender.notifyLinkFrame(asMap(serve));

      expect(parts.map((p) => p.length), everyElement(lessThanOrEqualTo(20)));
      expect(parts, hasLength(13 + 15));
      expect(whole(), [directive, serve]);
    });

    test('the MTU a later write reports is the one used', () async {
      sender.debugPeerMtu = 23;
      await sender.notifyLinkFrame(asMap(directive));
      final small = parts.length;
      sender.debugPeerMtu = 247;
      await sender.notifyLinkFrame(asMap(directive));

      expect(small, 13);
      expect(parts.length - small, 1);
      expect(whole(), [directive, directive]);
    });

    test('broadcast pairing frames fit a subscriber with the minimum MTU',
        () async {
      sender.debugPeerMtu = 247;
      final pair = {
        'pair': {'id': 'a' * 16, 'sealed': 's' * 300}
      };

      await sender.notifyLinkFrame(pair);

      expect(parts, hasLength(greaterThan(1)));
      expect(parts.map((p) => p.length), everyElement(lessThanOrEqualTo(20)));
      expect(whole(), [jsonEncode(pair)]);
    });

    test('a frame past the largest there is is refused, and nothing is sent',
        () async {
      sender.debugPeerMtu = 517;

      await expectLater(
        sender.notifyLinkFrame({
          'serve': {'fn': 'x' * 4000}
        }),
        throwsA(isA<BleFrameException>().having(
            (e) => e.problem, 'problem', BleFrameProblem.frameTooLarge)),
      );
      expect(parts, isEmpty);
    });

    test('nothing is sent once the sender has been stopped', () async {
      await sender.stop();

      await sender.notifyLinkFrame(asMap(serve));

      expect(parts, isEmpty);
    });
  });
}

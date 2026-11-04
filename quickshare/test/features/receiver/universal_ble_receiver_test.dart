// The Android and Windows receiver is a rendezvous client, not a file sink.
//
// It used to write whatever arrived on the data characteristic straight into a
// partial file and rename it, with none of QHTP's checks. Since the direct
// link the file crosses Wi-Fi, and this end only connects, subscribes, says
// what it can take, and listens for the sender's frames. A sender that still
// pushes bytes is an older build, and is told so.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/features/receiver/data/transports/ble_receiver_failure.dart';
import 'package:quickshare/features/receiver/data/transports/universal_ble_receiver_transport.dart';

import '../../support/fake_ble.dart';

void main() {
  late FakeBleCentral radio;
  late UniversalBleReceiverTransport receiver;
  late List<BleReceiverFailure> failures;
  late List<DirectLinkDirective> directives;
  late List<LinkServeInfo> serves;

  setUp(() {
    radio = FakeBleCentral();
    UniversalBle.setInstance(radio);
    receiver = UniversalBleReceiverTransport();
    failures = [];
    directives = [];
    serves = [];
    receiver.failures.listen(failures.add);
    receiver.linkDirectives.listen(directives.add);
    receiver.serveInfos.listen(serves.add);
  });

  tearDown(() => receiver.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('connecting', () {
    test('subscribes to metadata and data, says what it can take, then asks',
        () async {
      await receiver.connect('sender-1', token: 'tok');

      expect(radio.connects, ['sender-1']);
      expect(radio.subscribed,
          containsAll([BleUuidParser.string(BleGatt.metadata), BleUuidParser.string(BleGatt.data)]),
          reason: 'the sender waits for the data subscription before it begins');
      final order = [for (final w in radio.writes) w.text];
      expect(order, [BleControlProtocol.capabilities(), 'START:tok'],
          reason: 'CAPS before START, or a current receiver looks old');
    });

    test('asks for a bigger MTU, because Android before 14 starts at 23 bytes',
        () async {
      await receiver.connect('sender-1', token: 'tok');

      expect(radio.mtuRequests, isNotEmpty);
      expect(radio.mtuRequests.single, greaterThan(180),
          reason: 'a frame is two hundred bytes');
    });

    test('and carries on if the platform will not take the request', () async {
      radio.mtuError = PlatformException(code: 'notSupported');

      await receiver.connect('sender-1', token: 'tok');

      expect(radio.wrote('START:'), ['START:tok']);
    });

    test('refuses to start without the token the QR carried', () async {
      await expectLater(receiver.connect('sender-1', token: ''), throwsException);
      expect(radio.connects, isEmpty);
    });

    test('a device that cannot be connected to is an error, not a hang',
        () async {
      radio.connectError = Exception('Failed to connect');

      await expectLater(receiver.connect('sender-1', token: 'tok'),
          throwsA(anything));
      expect(radio.wrote('START:'), isEmpty);
    });
  });

  group('what the sender says', () {
    setUp(() async => receiver.connect('sender-1', token: 'tok'));

    test('a link directive reaches the coordinator', () async {
      radio.notify(
          'sender-1',
          BleGatt.metadata,
          jsonEncode(
              {'link': const DirectLinkDirective.hostByReceiver(senderPublicKey: 'k').toJson()}));
      await settle();

      expect(directives, hasLength(1));
      expect(directives.single.receiverHosts, isTrue);
      expect(failures, isEmpty);
    });

    test('and so does a serve frame', () async {
      radio.notify(
          'sender-1',
          BleGatt.metadata,
          jsonEncode({
            'serve': {'ip': '10.0.0.2', 'port': 8123, 'token': 't', 'tf': 'ff'}
          }));
      await settle();

      expect(serves.single.port, 8123);
    });

    test('a sender that begins a file on the metadata characteristic is told '
        'to update — and nothing is written', () async {
      // The first frame of a file, as every build before the direct link
      // sent it.
      radio.notify('sender-1', BleGatt.metadata,
          jsonEncode({'name': 'a.bin', 'size': 3, 'path': 'a.bin', 'index': 0}));
      await settle();

      expect(failures, hasLength(1));
      expect(failures.single.code, FailureCode.senderTooOldForDirectLink);
      expect(failures.single.message.toLowerCase(), contains('update'));
    });

    test('bytes on the data characteristic are the same sender, said once',
        () async {
      for (var i = 0; i < 50; i++) {
        radio.notifyBytes('sender-1', BleGatt.data, List<int>.filled(182, i));
      }
      await settle();

      expect(failures, hasLength(1),
          reason: 'a file is thousands of notifications');
      expect(failures.single.code, FailureCode.senderTooOldForDirectLink);
    });

    test('half a frame is reported as what it is, not as an old sender',
        () async {
      final whole = jsonEncode({
        'serve': {'ip': '10.0.0.2', 'port': 8123, 'token': 't' * 32, 'tf': 'ff' * 32}
      });
      radio.notify('sender-1', BleGatt.metadata, whole.substring(0, 20));
      await settle();

      expect(failures.single.code, FailureCode.bluetoothTransferFailed);
      expect(failures.single.message, contains('20-byte'));
      expect(serves, isEmpty);
    });

    test('the connection dropping is reported, for the session to weigh',
        () async {
      radio.updateConnection('sender-1', false);
      await settle();

      expect(failures.single.code, FailureCode.linkPeerLost);
    });

    test('after cancel() nothing is reported', () async {
      await receiver.cancel();
      radio.notify('sender-1', BleGatt.metadata, '{"name":"a","size":1}');
      await settle();

      expect(failures, isEmpty);
      expect(radio.disconnects, ['sender-1']);
    });
  });

  group('scanning', () {
    test('filters on the service and nothing else', () async {
      await receiver.startScanning(sessionToken: 'tok', publicId: 'ABCD1234');

      expect(radio.scans.single!.withServices,
          [BleGatt.service]);
    });

    test('a QuickShare name for another session is not offered', () async {
      final seen = <BleDevice>[];
      receiver.devices.listen(seen.add);
      await receiver.startScanning(sessionToken: 'tok', publicId: 'ABCD1234');

      radio.discover(id: 'a', name: 'QuickShare-ZZZZ9999');
      radio.discover(id: 'b', name: 'QuickShare-ABCD1234');
      radio.discover(id: 'c', name: null);
      radio.discover(id: 'd', name: 'DESKTOP-4F2A');
      await settle();

      expect([for (final d in seen) d.deviceId], ['b', 'c', 'd']);
    });
  });
}

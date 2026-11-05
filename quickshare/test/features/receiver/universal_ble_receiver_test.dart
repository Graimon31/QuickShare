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
import 'package:quickshare/core/transfer/ble_frame.dart';
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
      radio.notifyFrame(
          'sender-1',
          BleGatt.metadata,
          jsonEncode(
              {'link': const DirectLinkDirective.hostByReceiver(senderPublicKey: 'k').toJson()}));
      await settle();

      expect(directives, hasLength(1));
      expect(directives.single.receiverHosts, isTrue);
      expect(failures, isEmpty);
    });

    test('a directive that still carries the code\'s digits is an older '
        'sender: told to update, not acted on', () async {
      // Generation 4 and below put the ten digits in every directive. The
      // frame is refused at once, with the update it needs, instead of being
      // handed to a negotiation whose seal could not open — which would only
      // say so after waiting out its whole budget.
      radio.notifyFrame(
          'sender-1',
          BleGatt.metadata,
          jsonEncode({
            'link': {
              ...const DirectLinkDirective.hostByReceiver(senderPublicKey: 'k')
                  .toJson(),
              'code': '0123456789',
            }
          }));
      await settle();

      expect(directives, isEmpty);
      expect(failures, hasLength(1));
      expect(failures.single.code, FailureCode.senderTooOldForDirectLink);
      expect(failures.single.message, BleControlProtocol.senderTooOldMessage);
    });

    test('and so does a serve frame', () async {
      radio.notifyFrame(
          'sender-1',
          BleGatt.metadata,
          jsonEncode({
            'serve': {'ip': '10.0.0.2', 'port': 8123, 'token': 't', 'tf': 'ff'}
          }));
      await settle();

      expect(serves.single.port, 8123);
    });

    test('a frame that is longer than the notification arrives in parts and '
        'comes out whole', () async {
      final serve = {
        'ip': '192.168.137.1',
        'port': 54321,
        'token': 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
        'tf': 'ppyVDnOklxV6jThfz6nwYkm7r_rGePi0X5ULmV_k2qY',
        'fn': 'Vacation photos',
        'fs': 123456789,
        'ic': 12,
        'sn': "Farman's PC",
        'lip': '192.168.1.10',
      };
      radio.notifyFrame('sender-1', BleGatt.metadata, jsonEncode({'serve': serve}),
          notificationBytes: 20);
      await settle();

      expect(failures, isEmpty);
      expect(serves.single.fileName, 'Vacation photos');
      expect(serves.single.lanIp, '192.168.1.10');
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

    test('a sender whose frames are not in parts is an older build, and is '
        'told so', () async {
      // Bare JSON, which is what every sender before the parts sent — and what
      // a build made from the commit before them still sends.
      radio.notify(
          'sender-1',
          BleGatt.metadata,
          jsonEncode({
            'link': const DirectLinkDirective.hostByReceiver(senderPublicKey: 'k')
                .toJson()
          }));
      await settle();

      expect(directives, isEmpty);
      expect(failures.single.code, FailureCode.senderTooOldForDirectLink);
      expect(failures.single.message, BleControlProtocol.senderTooOldMessage);
    });

    test('parts cut short by the link are damage, not an old sender',
        () async {
      // Every part of a current sender's frame carries its header, so a link
      // that cuts a notification to 20 bytes leaves valid parts with too little
      // in them — and the frame that comes out is half a document.
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
        'serve': {'ip': '10.0.0.2', 'port': 8123, 'token': 't' * 32, 'tf': 'ff' * 32}
      })));
      for (final part
          in BleFrameSplitter().split(bytes, notificationBytes: 182)) {
        radio.notifyBytes('sender-1', BleGatt.metadata,
            part.length > 20 ? part.sublist(0, 20) : part);
      }
      await settle();

      expect(failures, hasLength(1));
      expect(failures.single.code, FailureCode.bluetoothTransferFailed);
      expect(failures.single.message, contains(BleFrame.damagedMessage));
      expect(failures.single.message, isNot(contains('older version')));
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

  group('a frame that cannot be put together', () {
    setUp(() async => receiver.connect('sender-1', token: 'tok'));

    /// The parts of a frame of [size] bytes of JSON, cut for [notificationBytes].
    List<Uint8List> partsOf(int size,
        {int notificationBytes = 20, int? frameId}) {
      final filler = 'x' * (size - '{"serve":{"x":""}}'.length);
      return BleFrameSplitter().split(
          Uint8List.fromList(utf8.encode('{"serve":{"x":"$filler"}}')),
          notificationBytes: notificationBytes,
          frameId: frameId ?? 9);
    }

    void play(Iterable<Uint8List> parts) {
      for (final part in parts) {
        radio.notifyBytes('sender-1', BleGatt.metadata, part);
      }
    }

    /// What the person is told, and that it is not the old-version message.
    void expectDamaged(String about) {
      expect(failures, hasLength(1),
          reason: 'one failure for the session, not one per part that follows');
      expect(failures.single.code, FailureCode.bluetoothTransferFailed);
      expect(failures.single.message, contains(BleFrame.damagedMessage));
      expect(failures.single.message, contains(about));
      expect(failures.single.message, isNot(contains('older version')));
      expect(serves, isEmpty);
      expect(directives, isEmpty);
    }

    test('a part that never arrives is a lost part, said at the next one',
        () async {
      final parts = partsOf(100);
      play([parts[0], parts[1], ...parts.skip(3)]);
      await settle();

      expectDamaged('a part was lost');
    });

    test('a part that arrives twice is refused', () async {
      final parts = partsOf(100);
      play([parts[0], parts[1], parts[1], ...parts.skip(2)]);
      await settle();

      expectDamaged('arrived twice');
    });

    test('a part from another frame in the middle of one is refused',
        () async {
      final mine = partsOf(100, frameId: 9);
      final theirs = partsOf(100, frameId: 77);
      play([mine[0], mine[1], theirs[2], ...mine.skip(2)]);
      await settle();

      expectDamaged('arrived inside frame 9');
    });

    test('a frame that begins before the last one ended is refused', () async {
      final mine = partsOf(100, frameId: 9);
      final next = partsOf(60, frameId: 10);
      play([mine[0], mine[1], next[0]]);
      await settle();

      expectDamaged('began while frame 9');
    });

    test('a part from the middle of a frame whose start never came is refused',
        () async {
      final parts = partsOf(100);
      play([parts[3]]);
      await settle();

      expectDamaged('no beginning');
    });

    test('a part that disagrees about how many there are is refused',
        () async {
      final parts = partsOf(100);
      final lying = Uint8List.fromList(parts[1])..[3] = parts[1][3] + 1;
      play([parts[0], lying]);
      await settle();

      expectDamaged('said it had');
    });

    test('a frame that grows past the limit is stopped, not stored', () async {
      // 250 parts of 16 bytes is 4000: past the 3072 a frame may have, and the
      // assembler says so at the part that crosses it instead of keeping on.
      final parts = <Uint8List>[
        for (var i = 0; i < 250; i++)
          Uint8List.fromList([BleFrame.marker, 5, i, 250, ...List.filled(16, 0x41)])
      ];
      play(parts);
      await settle();

      expectDamaged('is past ${BleFrame.maxFrameBytes} bytes');
    });

    test('a notification that is not a part at all is refused', () async {
      play([Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x04])]);
      await settle();

      expectDamaged('not a part of a frame');
    });

    test('a part with a header and nothing after it is refused', () async {
      play([Uint8List.fromList([BleFrame.marker, 1, 0, 1])]);
      await settle();

      expectDamaged('nothing after it');
    });

    test('a frame that arrives whole but is not JSON is refused', () async {
      play(BleFrameSplitter().split(Uint8List.fromList(utf8.encode('not json')),
          notificationBytes: 182));
      await settle();

      expectDamaged('not JSON');
    });

    test('a frame that is JSON but neither link nor serve is refused',
        () async {
      radio.notifyFrame('sender-1', BleGatt.metadata, '{"hello":1}');
      await settle();

      expectDamaged('neither a link nor a serve frame');
    });

    test('a serve frame without what the pull needs is refused, not dropped',
        () async {
      // No fingerprint: the receiver could not pin the pull, and a silent drop
      // would leave the screen waiting for an address that never comes.
      radio.notifyFrame('sender-1', BleGatt.metadata,
          jsonEncode({'serve': {'ip': '10.0.0.2', 'port': 8123, 'token': 't'}}));
      await settle();

      expectDamaged('missing what a receiver needs');
    });

    test('nothing follows a refused frame: the rest of its parts say nothing',
        () async {
      final parts = partsOf(100);
      play([parts[0], parts[2], ...parts.skip(3)]);
      await settle();

      expect(failures, hasLength(1));
    });

    test('a frame that never finishes is stopped by the clock, not waited for',
        () async {
      final timed = UniversalBleReceiverTransport(
          frameTimeout: const Duration(milliseconds: 40));
      addTearDown(timed.dispose);
      final seen = <BleReceiverFailure>[];
      timed.failures.listen(seen.add);
      await timed.connect('sender-2', token: 'tok');

      radio.notifyBytes('sender-2', BleGatt.metadata, partsOf(100).first);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(seen, hasLength(1));
      expect(seen.single.code, FailureCode.bluetoothTransferFailed);
      expect(seen.single.message, contains('did not finish'));
      expect(seen.single.message, contains('1 of'));
    });

    test('and a frame that does finish in time stops its clock', () async {
      final timed = UniversalBleReceiverTransport(
          frameTimeout: const Duration(milliseconds: 40));
      addTearDown(timed.dispose);
      final seen = <BleReceiverFailure>[];
      final got = <LinkServeInfo>[];
      timed.failures.listen(seen.add);
      timed.serveInfos.listen(got.add);
      await timed.connect('sender-2', token: 'tok');

      radio.notifyFrame('sender-2', BleGatt.metadata,
          jsonEncode({'serve': {'ip': '10.0.0.2', 'port': 8123, 'token': 't', 'tf': 'ff'}}),
          notificationBytes: 20);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(got, hasLength(1));
      expect(seen, isEmpty);
    });
  });

  group('scanning', () {
    test('filters on the service and nothing else', () async {
      await receiver.startScanning(sessionToken: 'tok', locator: 'ABCD1234');

      expect(radio.scans.single!.withServices,
          [BleGatt.service]);
    });

    test('a QuickShare name for another session is not offered', () async {
      final seen = <BleDevice>[];
      receiver.devices.listen(seen.add);
      await receiver.startScanning(sessionToken: 'tok', locator: 'ABCD1234');

      radio.discover(id: 'a', name: 'QuickShare-ZZZZ9999');
      radio.discover(id: 'b', name: 'QuickShare-ABCD1234');
      radio.discover(id: 'c', name: null);
      radio.discover(id: 'd', name: 'DESKTOP-4F2A');
      await settle();

      expect([for (final d in seen) d.deviceId], ['b', 'c', 'd']);
    });
  });
}

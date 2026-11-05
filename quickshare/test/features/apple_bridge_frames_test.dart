// What Dart asks of the Apple bridge, and what it makes of what the bridge says,
// for negotiation frames.
//
// CoreBluetooth cannot run here, so the bridge is a stand-in on the method and
// event channels. What is checked is the contract Dart relies on: the sender
// hands the bridge a whole frame and lets the bridge cut it to the receiver's
// limit and wait for the radio (see `QuickShareBluetooth.swift`); the receiver
// is handed whole frames, and a problem with one is reported as what it is.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_frame.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('quickshare/bluetooth');
  const events = MethodChannel('quickshare/bluetooth/events');
  const codec = StandardMethodCodec();

  late List<MethodCall> calls;
  Future<Object?> Function(MethodCall call)? bridge;

  setUp(() {
    calls = [];
    bridge = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, (call) {
      calls.add(call);
      return bridge?.call(call) ?? Future<Object?>.value();
    });
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (call) async => null);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });

  group('a sender on an Apple device', () {
    late BluetoothTransferTransport transport;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      transport = BluetoothTransferTransport();
      await transport.initialize();
    });

    tearDown(() => transport.stopSharing());

    List<MethodCall> frames() =>
        [for (final c in calls) if (c.method == 'sendLinkFrame') c];

    test('hands the bridge the whole frame, once: cutting it is the bridge\'s '
        'job, because only it knows the receiver\'s limit', () async {
      final frame = {
        'serve': {'ip': '10.0.0.2', 'port': 1, 'token': 't' * 32, 'tf': 'f' * 43,
            'fn': 'Vacation photos', 'lip': '192.168.1.10', 'sn': 'Mac'}
      };

      await transport.sendLinkFrame(frame);

      expect(frames(), hasLength(1));
      expect((frames().single.arguments as Map)['frame'], frame,
          reason: 'nothing dropped to make it fit');
    });

    test('frames asked for together go to the bridge one after the other',
        () async {
      final first = Completer<Object?>();
      bridge = (call) =>
          calls.where((c) => c.method == 'sendLinkFrame').length == 1
              ? first.future
              : Future<Object?>.value();

      final a = transport.sendLinkFrame({'link': {'host': 'receiver'}});
      final b = transport.sendLinkFrame({'serve': {'ip': 'x'}});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(frames(), hasLength(1),
          reason: 'the second must not start while the first has parts the '
              'radio has not taken');
      first.complete();
      await Future.wait([a, b]);
      expect(frames(), hasLength(2));
      expect(
          [for (final c in frames()) ((c.arguments as Map)['frame'] as Map).keys.single],
          ['link', 'serve']);
    });

    test('what the bridge refuses with is the caller\'s to see, and the next '
        'frame goes anyway', () async {
      var n = 0;
      bridge = (call) async {
        if (call.method == 'sendLinkFrame' && n++ == 0) {
          throw PlatformException(
              code: 'TIMEOUT',
              message: 'the radio stayed busy for 10 seconds');
        }
        return null;
      };

      await expectLater(
        transport.sendLinkFrame({'link': {'host': 'receiver'}}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'TIMEOUT')),
      );
      await transport.sendLinkFrame({'link': {'host': 'receiver'}});

      expect(frames(), hasLength(2));
    });

    test('a full queue is the bridge\'s to wait out: Dart does not retry a '
        'frame that may be half sent', () async {
      bridge = (call) async {
        if (call.method == 'sendLinkFrame') {
          throw PlatformException(code: 'BUSY', message: 'the queue is full');
        }
        return null;
      };

      await expectLater(
        transport.sendLinkFrame({'link': {'host': 'receiver'}}),
        throwsA(isA<PlatformException>()),
      );

      expect(frames(), hasLength(1),
          reason: 'a second attempt after a first that sent some of its parts '
              'would start a new frame inside the old one');
    });
  });

  group('a receiver on an Apple device', () {
    late BluetoothReceiverTransport receiver;
    late List<BleReceiverFailure> failures;
    late List<DirectLinkDirective> directives;
    late List<LinkServeInfo> serves;

    setUp(() async {
      receiver = BluetoothReceiverTransport();
      failures = [];
      directives = [];
      serves = [];
      receiver.failures.listen(failures.add);
      receiver.linkDirectives.listen(directives.add);
      receiver.serveInfos.listen(serves.add);
      await receiver.startScanning(sessionToken: 'tok', locator: 'ABCD2345');
    });

    tearDown(() => receiver.dispose());

    Future<void> bridgeSays(Map<String, Object?> event) async {
      await binding.defaultBinaryMessenger.handlePlatformMessage(
          events.name, codec.encodeSuccessEnvelope(event), (_) {});
      await Future<void>.delayed(Duration.zero);
    }

    test('is handed a link frame and a serve frame whole', () async {
      await bridgeSays({
        'type': 'linkDirective',
        'link': {'host': 'receiver', 'kex': 'a-key'}
      });
      await bridgeSays({
        'type': 'serveInfo',
        'serve': {'ip': '10.0.0.2', 'port': 8123, 'token': 't', 'tf': 'ff'}
      });

      expect(directives.single.receiverHosts, isTrue);
      expect(serves.single.port, 8123);
      expect(failures, isEmpty);
    });

    test('a serve frame that is missing what the pull needs is reported, not '
        'dropped', () async {
      await bridgeSays({
        'type': 'serveInfo',
        'serve': {'ip': '10.0.0.2', 'port': 8123, 'token': 't'}
      });

      expect(serves, isEmpty);
      expect(failures.single.code, FailureCode.bluetoothTransferFailed);
      expect(failures.single.message, contains(BleFrame.damagedMessage));
    });

    test('a frame the bridge could not put together is a lost message, not '
        'an older sender', () async {
      await bridgeSays({
        'type': 'receiverFailed',
        'error': '${BleFrame.damagedMessage} Part 3 of frame 12 arrived with '
            'part 2 still missing: a part was lost.',
        'code': 'bluetoothTransferFailed',
      });

      expect(failures.single.code, FailureCode.bluetoothTransferFailed);
      expect(failures.single.message, isNot(contains('older version')));
    });

    test('and only a sender that does not cut its frames is told to update',
        () async {
      await bridgeSays({
        'type': 'receiverFailed',
        'error': BleControlProtocol.senderTooOldMessage,
        'code': 'senderTooOldForDirectLink',
      });

      expect(failures.single.code, FailureCode.senderTooOldForDirectLink);
    });
  });
}

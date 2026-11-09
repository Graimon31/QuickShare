import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/transfer/ble_code_pairing.dart';
import 'package:quickshare/features/receiver/data/client/bluetooth_code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

const code = SessionCode('1234567890');
const otherCode = SessionCode('9876543210');
final offer =
    const BluetoothQrPayload(token: 'private-token', locator: 'random')
        .encode();

class FakeRadio implements BleCodeRadio {
  FakeRadio(this.senders,
      {this.hangConnect = false,
      this.hangDisconnect = false,
      this.hangDispose = false});
  final Map<String, BleCodePairingSender?> senders;
  final bool hangConnect;
  final bool hangDisconnect;
  final bool hangDispose;
  final disconnectBlocker = Completer<void>();
  final disposeBlocker = Completer<void>();
  final devicesController = StreamController<String>.broadcast(sync: true);
  final framesController =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final connected = <String>[];
  final writes = <String>[];
  final onConnect = Completer<void>();
  final blocker = Completer<void>();
  int disconnects = 0;
  int stops = 0;
  bool disposed = false;
  String? current;

  @override
  Stream<String> get devices => devicesController.stream;
  @override
  Stream<Map<String, dynamic>> get frames => framesController.stream;
  @override
  Future<void> scan() async {
    for (final device in senders.keys) {
      devicesController.add(device);
      devicesController.add(device); // duplicate advertisement
    }
  }

  @override
  Future<void> stopScan() async => stops++;
  @override
  Future<void> connect(String device) async {
    current = device;
    connected.add(device);
    if (!onConnect.isCompleted) onConnect.complete();
    if (hangConnect) await blocker.future;
  }

  @override
  Future<void> write(String command) async {
    writes.add(command);
    final sender = senders[current];
    if (sender == null || disposed) return;
    final answer = await sender.handle('receiver', command);
    if (answer != null && !disposed) framesController.add(answer);
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    current = null;
    if (hangDisconnect) await disconnectBlocker.future;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (hangDispose) await disposeBlocker.future;
    if (hangConnect && !blocker.isCompleted) {
      blocker.completeError(StateError('disposed'));
    }
    await devicesController.close();
    await framesController.close();
  }
}

void main() {
  BluetoothCodeSearch search(FakeRadio radio, {Duration? timeout}) =>
      BluetoothCodeSearch(
          radio: () => radio,
          discoveryWindow: const Duration(milliseconds: 10),
          attemptWindow: const Duration(seconds: 3),
          searchWindow: timeout ?? const Duration(seconds: 10),
          cleanupWindow: const Duration(milliseconds: 200));

  test('skips wrong sender and finds proof from a second device', () async {
    final first = BleCodePairingSender(otherCode, offer);
    final second = BleCodePairingSender(code, offer);
    final radio = FakeRadio({'wrong': first, 'correct': second});
    final control = CodeSearchControl();
    final gate = CodeSearchArbiter(control).gate('bluetooth');
    final result = await search(radio).run(code, gate: gate);
    expect(result, isA<CodeSessionFoundBluetooth>());
    expect((result as CodeSessionFoundBluetooth).payload, offer);
    expect(radio.connected, ['wrong', 'correct']);
    expect(radio.writes, everyElement(isNot(contains(code.code))));
    expect(radio.writes, everyElement(isNot(contains('private-token'))));
    expect(radio.disconnects, 2);
    expect(radio.disposed, isTrue);
    expect(radio.stops, greaterThanOrEqualTo(1));
    first.dispose();
    second.dispose();
    await control.dispose();
  });

  test('a silent candidate times out without blocking the next one', () async {
    final sender = BleCodePairingSender(code, offer);
    final radio = FakeRadio({'silent': null, 'correct': sender});
    final control = CodeSearchControl();
    final gate = CodeSearchArbiter(control).gate('bluetooth');
    final searcher = BluetoothCodeSearch(
      radio: () => radio,
      discoveryWindow: const Duration(milliseconds: 10),
      attemptWindow: const Duration(seconds: 1),
      searchWindow: const Duration(seconds: 5),
    );
    final result = await searcher.run(code, gate: gate);
    expect(result, isA<CodeSessionFoundBluetooth>());
    expect(radio.connected, ['silent', 'correct']);
    expect(radio.disconnects, 2);
    expect(radio.disposed, isTrue);
    sender.dispose();
    await control.dispose();
  });

  test('cancel releases an in-progress connection and cannot claim', () async {
    final radio = FakeRadio({'silent': null}, hangConnect: true);
    final control = CodeSearchControl();
    final arbiter = CodeSearchArbiter(control);
    final gate = arbiter.gate('bluetooth');
    final future = search(radio).run(code, gate: gate);
    await radio.onConnect.future;
    control.cancel();
    expect(await future, isA<CodeSessionNotFound>());
    expect(arbiter.winner, isNull);
    expect(radio.disposed, isTrue);
    await control.dispose();
  });

  test('overall deadline disposes a radio stuck during connection', () async {
    final radio = FakeRadio({'silent': null}, hangConnect: true);
    final control = CodeSearchControl();
    final gate = CodeSearchArbiter(control).gate('bluetooth');
    final result =
        await search(radio, timeout: const Duration(milliseconds: 100))
            .run(code, gate: gate);
    expect(result, isA<CodeSessionNotFound>());
    expect(radio.disposed, isTrue);
    await control.dispose();
  });

  test('handoff waits for a normal disconnect to finish', () async {
    final sender = BleCodePairingSender(code, offer);
    final radio = FakeRadio({'correct': sender}, hangDisconnect: true);
    final control = CodeSearchControl();
    var completed = false;
    final result = search(radio)
        .run(code, gate: CodeSearchArbiter(control).gate('bluetooth'))
        .then((value) {
      completed = true;
      return value;
    });
    while (radio.disconnects == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(completed, isFalse);
    radio.disconnectBlocker.complete();
    expect(await result, isA<CodeSessionFoundBluetooth>());
    expect(radio.disposed, isTrue);
    sender.dispose();
    await control.dispose();
  });

  test('a stuck disconnect does not hide an authenticated offer', () async {
    final sender = BleCodePairingSender(code, offer);
    final radio = FakeRadio({'correct': sender}, hangDisconnect: true);
    final control = CodeSearchControl();
    final result = await search(radio)
        .run(code, gate: CodeSearchArbiter(control).gate('bluetooth'))
        .timeout(const Duration(seconds: 2));
    expect(result, isA<CodeSessionFoundBluetooth>());
    expect((result as CodeSessionFoundBluetooth).payload, offer);
    expect(radio.disconnects, 1);
    radio.disconnectBlocker.complete();
    sender.dispose();
    await control.dispose();
  });

  test('cancellation is not held up by a stuck dispose', () async {
    final radio =
        FakeRadio({'silent': null}, hangConnect: true, hangDispose: true);
    final control = CodeSearchControl();
    final future = search(radio)
        .run(code, gate: CodeSearchArbiter(control).gate('bluetooth'));
    await radio.onConnect.future;
    control.cancel();
    expect(await future.timeout(const Duration(seconds: 1)),
        isA<CodeSessionNotFound>());
    expect(radio.disposed, isTrue);
    radio.disposeBlocker.complete();
    await control.dispose();
  });
}

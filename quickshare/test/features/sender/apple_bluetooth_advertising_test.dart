import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('quickshare/bluetooth');
  const events = MethodChannel('quickshare/bluetooth/events');
  const codec = StandardMethodCodec();
  const file = FileMetadata(
      name: 'file', path: '/tmp/file', size: 1, mimeType: 'text/plain');

  Future<void> emit(Map<String, Object?> event) =>
      binding.defaultBinaryMessenger.handlePlatformMessage(
          events.name, codec.encodeSuccessEnvelope(event), (_) {});

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async => null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (call) async => null);
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });

  test('the sender waits for the native advertising callback', () async {
    final transport = BluetoothTransferTransport();
    await transport.initialize();
    addTearDown(transport.stopSharing);
    var completed = false;
    final started = transport.startSharing(file, 'token', locator: 'public')
      ..then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    await emit({'type': 'advertisingStarted'});
    expect(await started, file.name);
  });

  test('stopping while advertising starts settles without a later stop',
      () async {
    var stops = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods,
        (call) async {
      if (call.method == 'stopAdvertising') stops++;
      return null;
    });
    final transport = BluetoothTransferTransport(
        advertisingTimeout: const Duration(milliseconds: 50));
    await transport.initialize();
    final started = transport.startSharing(file, 'token', locator: 'public');
    final checked = expectLater(
        started,
        throwsA(isA<BluetoothRadioException>().having((e) => e.message,
            'message', 'Bluetooth advertising was cancelled.')));
    await transport.stopSharing();
    await checked;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(stops, 1, reason: 'the old timeout must not stop a later session');
  });

  test('the sender propagates the native advertising failure', () async {
    final transport = BluetoothTransferTransport();
    await transport.initialize();
    addTearDown(transport.stopSharing);
    final started = transport.startSharing(file, 'token', locator: 'public');
    final checked = expectLater(
        started,
        throwsA(isA<BluetoothRadioException>()
            .having((e) => e.message, 'message', 'advertising rejected')));
    await emit({'type': 'senderFailed', 'error': 'advertising rejected'});
    await checked;
  });
}

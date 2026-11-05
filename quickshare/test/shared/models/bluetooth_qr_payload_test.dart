import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

void main() {
  test('Bluetooth QR payload round-trips its session token and metadata', () {
    const original = BluetoothQrPayload(
      token: 'session-token-123',
      locator: 'ABCD2345',
      fileName: 'Photos',
      fileSize: 456789,
      itemCount: 4,
      senderName: 'MacBook Pro',
    );
    final decoded = BluetoothQrPayload.tryDecode(original.encode());

    expect(decoded?.token, original.token);
    expect(decoded?.locator, original.locator);
    expect(decoded?.fileName, original.fileName);
    expect(decoded?.fileSize, original.fileSize);
    expect(decoded?.itemCount, original.itemCount);
    expect(decoded?.senderName, original.senderName);
  });

  test('Bluetooth QR decoder supports legacy payload without metadata', () {
    const legacy = BluetoothQrPayload(token: 'session-token-legacy');
    final decoded = BluetoothQrPayload.tryDecode(legacy.encode());

    expect(decoded?.token, legacy.token);
    expect(decoded?.fileName, '');
    expect(decoded?.fileSize, 0);
    expect(decoded?.itemCount, 0);
    expect(decoded?.senderName, '');
  });

  test('Bluetooth QR decoder rejects unrelated QR data', () {
    expect(
        BluetoothQrPayload.tryDecode('quickshare://join?room=ABC123'), isNull);
    expect(BluetoothQrPayload.tryDecode('${BluetoothQrPayload.prefix}bad'),
        isNull);
  });
}

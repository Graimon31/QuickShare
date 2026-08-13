import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

void main() {
  test('Bluetooth QR payload round-trips its session token', () {
    const original = BluetoothQrPayload(token: 'session-token-123');
    final decoded = BluetoothQrPayload.tryDecode(original.encode());

    expect(decoded?.token, original.token);
  });

  test('Bluetooth QR decoder rejects unrelated QR data', () {
    expect(
        BluetoothQrPayload.tryDecode('quickshare://join?room=ABC123'), isNull);
    expect(BluetoothQrPayload.tryDecode('${BluetoothQrPayload.prefix}bad'),
        isNull);
  });
}

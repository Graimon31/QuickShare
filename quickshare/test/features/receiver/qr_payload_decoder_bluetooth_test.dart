import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

void main() {
  late QRPayloadDecoder decoder;

  setUp(() {
    decoder = QRPayloadDecoder();
  });

  test('decodes Bluetooth QR payload with metadata into QRPayload', () {
    const bt = BluetoothQrPayload(
      token: 'session-bt-999',
      publicId: 'cid-pub-123',
      fileName: 'VacationFolder',
      fileSize: 10485760,
      itemCount: 5,
      senderName: 'MacBook Pro — Mr.Graimon',
    );
    final raw = bt.encode();
    final payload = decoder.decode(raw);

    expect(payload.mode, QRPayloadDecoder.bluetoothMode);
    expect(payload.token, 'session-bt-999');
    expect(payload.sessionId, 'cid-pub-123');
    expect(payload.fileName, 'VacationFolder');
    expect(payload.fileSize, 10485760);
    expect(payload.itemCount, 5);
    expect(payload.senderName, 'MacBook Pro — Mr.Graimon');
    expect(payload.isValid, isTrue);
  });

  test('decodes legacy Bluetooth QR payload into QRPayload', () {
    const bt = BluetoothQrPayload(token: 'legacy-token');
    final raw = bt.encode();
    final payload = decoder.decode(raw);

    expect(payload.mode, QRPayloadDecoder.bluetoothMode);
    expect(payload.token, 'legacy-token');
    expect(payload.fileName, '');
    expect(payload.fileSize, 0);
    expect(payload.itemCount, 0);
    expect(payload.senderName, isNull);
    expect(payload.isValid, isTrue);
  });
}

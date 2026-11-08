// Runs the real universal sender and code-search receiver across a simulated
// minimum-MTU BLE link; no fake implements the pairing protocol.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/transfer/ble_frame.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/features/receiver/data/client/bluetooth_code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../support/linked_ble.dart';

class MinimumMtuCentral extends LinkedBleCentral {
  final bytes = <Uint8List>[];
  @override
  Future<void> startScan(
      {ScanFilter? scanFilter, PlatformConfig? platformConfig}) async {
    await super
        .startScan(scanFilter: scanFilter, platformConfig: platformConfig);
    Timer.run(() => discover(id: 'peer'));
  }

  @override
  Future<void> writeValue(
      String deviceId,
      String service,
      String characteristic,
      Uint8List value,
      BleOutputProperty property) async {
    expect(value.length, lessThanOrEqualTo(20), reason: 'ATT MTU 23');
    bytes.add(Uint8List.fromList(value));
    await super.writeValue(deviceId, service, characteristic, value, property);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    test('$platform real code sender and receiver work over 20-byte writes',
        () async {
      debugDefaultTargetPlatformOverride = platform;
      final central = MinimumMtuCentral()..mtu = 23;
      final peripheral = LinkedBlePeripheral(central, radioLimit: 20);
      central.server = peripheral;
      UniversalBle.setInstance(central);
      UniversalBlePeripheral.setInstance(peripheral);
      final sender =
          BluetoothTransferTransport(notificationPacing: Duration.zero);
      const code = SessionCode('1234567890');
      final payload =
          const BluetoothQrPayload(token: 'secret', locator: 'random').encode();
      final control = CodeSearchControl();
      try {
        await sender.initialize();
        sender.enableCodePairing(code, payload);
        await sender.startSharing(
            const FileMetadata(
                name: 'x',
                path: '/x',
                size: 1,
                mimeType: 'application/octet-stream'),
            'secret',
            locator: 'random');
        // Bad fragments from unrelated centrals, including this peer, must
        // not permanently consume the limited assembler slots.
        for (var n = 0; n < 10; n++) {
          peripheral.write('bad-$n', BleGatt.control,
              String.fromCharCodes([BleFrame.marker, 1]));
        }
        peripheral.write('peer', BleGatt.control,
            String.fromCharCodes([BleFrame.marker, 1]));
        final result = await BluetoothCodeSearch(
          discoveryWindow: const Duration(milliseconds: 25),
          attemptWindow: const Duration(seconds: 3),
          searchWindow: const Duration(seconds: 5),
        ).run(code, gate: CodeSearchArbiter(control).gate('bluetooth'));
        expect(result, isA<CodeSessionFoundBluetooth>());
        expect((result as CodeSessionFoundBluetooth).payload, payload);
        expect(central.bytes.length, greaterThan(2));
        expect(central.bytes.every((value) => value.first == BleFrame.marker),
            isTrue);
        expect(peripheral.offered.every((value) => value.length <= 20), isTrue);
        // Cleanup is started before returning but a plugin can complete it
        // asynchronously; a stuck plugin must not hold the result hostage.
        final deadline = DateTime.now().add(const Duration(seconds: 1));
        while (!central.disconnects.contains('peer') &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(central.disconnects, contains('peer'));
      } finally {
        await sender.stopSharing();
        await control.dispose();
        UniversalBlePeripheral.setInstance(UniversalBlePeripheralUnsupported());
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}

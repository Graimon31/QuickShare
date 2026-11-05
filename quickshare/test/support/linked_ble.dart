// A sender's radio wired to a receiver's, as a real link behaves.
//
// `fake_ble.dart` has the two halves of the radio apart. This joins them: a
// notification the sender asks for is heard by the receiver as a central would
// hear it — and, like a real link, **cut to what the connection carries**. The
// platforms do not refuse a notification that is longer than the negotiated
// payload; they send its first bytes and say nothing, which is how a 203-byte
// frame on an iPhone's 182-byte link reaches the far side as half a JSON
// document. A fake that delivered every notification whole could not have shown
// that, and could not show that it no longer happens.
//
// Faults are scripted in [LinkedBlePeripheral.tamper]: the one place a test can
// lose a part, repeat one, reorder two or put one of its own on the link.
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'fake_ble.dart';

/// The sender's GATT server, heard by [central] under the id [peer].
class LinkedBlePeripheral extends FakeBlePeripheral {
  /// [radioLimit] is what the connection really carries per notification: the
  /// ATT MTU less three. The sender is *told* the same number
  /// (`getMaximumNotifyLength`) unless [reportsLimit] is false, which is a
  /// platform that did not know it.
  LinkedBlePeripheral(
    this.central, {
    this.radioLimit = 20,
    bool reportsLimit = true,
    this.peer = 'peer',
  }) {
    maxNotifyLength = reportsLimit ? radioLimit : null;
  }

  final FakeBleCentral central;
  final String peer;

  /// What a notification can hold on this link; anything longer is cut.
  int radioLimit;

  /// Everything the link was asked to carry, before it cut anything: how the
  /// test learns what the sender tried.
  final List<Uint8List> offered = [];

  /// What went through, after cutting. This is what the receiver heard.
  final List<Uint8List> delivered = [];

  /// Between the sender and the link: returns what actually gets onto it for
  /// each notification the sender makes. Null passes it through unchanged.
  List<Uint8List> Function(int sequence, Uint8List value)? tamper;

  int _sequence = 0;

  @override
  Future<void> updateCharacteristicValue({
    required String characteristicId,
    required Uint8List value,
    String? deviceId,
  }) async {
    await super.updateCharacteristicValue(
        characteristicId: characteristicId, value: value, deviceId: deviceId);
    offered.add(Uint8List.fromList(value));
    final onTheLink = tamper?.call(_sequence++, value) ?? [value];
    for (final v in onTheLink) {
      final cut = v.length > radioLimit ? v.sublist(0, radioLimit) : v;
      delivered.add(Uint8List.fromList(cut));
      central.notifyBytes(peer, characteristicId, cut);
    }
  }
}

/// The receiver's radio, wired to the sender's: what it writes and subscribes
/// to reaches the sender's GATT server.
class LinkedBleCentral extends FakeBleCentral {
  FakeBlePeripheral? server;

  @override
  Future<void> writeValue(String deviceId, String service, String characteristic,
      Uint8List value, BleOutputProperty bleOutputProperty) async {
    await super.writeValue(
        deviceId, service, characteristic, value, bleOutputProperty);
    server?.write(deviceId, characteristic, String.fromCharCodes(value));
  }

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    await super.setNotifiable(
        deviceId, service, characteristic, bleInputProperty);
    if (bleInputProperty != BleInputProperty.disabled) {
      server?.subscribe(deviceId, characteristic);
    }
  }
}

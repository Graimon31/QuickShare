// The two Bluetooth radios a test can stand a transport on.
//
// `universal_ble` is the only thing between the sender and receiver code and
// the platform, and it has a seam for both halves: `UniversalBlePeripheral`
// (advertising, the GATT server) and `UniversalBle` (scanning, the GATT
// client). These fakes sit exactly there, so the transports under test are
// the real ones, running their real code against a radio that does what the
// plugin documents — including the parts that are easy to forget, like
// Android reporting a failed advertisement on a stream rather than by
// throwing.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

/// One characteristic as the sender registered it.
class FakeGattCharacteristic {
  FakeGattCharacteristic({
    required this.uuid,
    required this.properties,
    required this.permissions,
  });

  final String uuid;
  final List<CharacteristicProperty> properties;
  final List<PeripheralAttributePermission> permissions;
}

/// One service as the sender registered it.
class FakeGattService {
  FakeGattService(this.uuid, this.characteristics);

  final String uuid;
  final List<FakeGattCharacteristic> characteristics;

  FakeGattCharacteristic? characteristic(String id) {
    for (final c in characteristics) {
      if (BleUuidParser.compareStrings(c.uuid, id)) return c;
    }
    return null;
  }
}

/// One call to `startAdvertising`.
class FakeAdvertise {
  FakeAdvertise({
    required this.services,
    required this.localName,
    required this.platformConfig,
  });

  final List<String> services;
  final String? localName;
  final PeripheralPlatformConfig? platformConfig;
}

/// One `updateCharacteristicValue`: a notification the sender asked for.
class FakeNotification {
  FakeNotification(this.characteristicId, this.value, this.deviceId);

  final String characteristicId;
  final Uint8List value;
  final String? deviceId;

  String get text => String.fromCharCodes(value);
}

/// The GATT-server half: what a phone or a PC does as the sending end.
class FakeBlePeripheral extends UniversalBlePeripheralPlatform {
  // ── script ────────────────────────────────────────────────────────────

  bool supportsPeripheralMode = true;
  PeripheralReadinessState readiness = PeripheralReadinessState.ready;

  /// What the radio reports once it has been asked to advertise. Null is the
  /// plugin saying nothing at all, which is what a stack that never answers
  /// looks like from Dart.
  PeripheralAdvertisingState? afterStart = PeripheralAdvertisingState.advertising;

  /// The text that rides with an `error` state ("Data too large", …).
  String? advertisingError;

  /// Thrown by `addService`, as the plugin throws when the platform refuses.
  Object? addServiceError;

  /// Thrown by `startAdvertising` itself (permission denied, …).
  Object? startAdvertisingError;

  /// What `getMaximumNotifyLength` answers: the negotiated ATT payload.
  int? maxNotifyLength = 512;

  // ── record ────────────────────────────────────────────────────────────

  final List<FakeGattService> registered = [];
  final List<int> serviceRegistrations = [];
  final List<FakeAdvertise> advertised = [];
  final List<FakeNotification> notifications = [];
  int stopAdvertisingCalls = 0;
  int clearServicesCalls = 0;
  PeripheralAdvertisingState advertisingNow = PeripheralAdvertisingState.idle;

  OnPeripheralWriteRequest? writeHandler;

  /// A central writes [text] to [characteristic]. Returns what the sender
  /// answered at the ATT layer (null is "success", as the plugin treats it).
  PeripheralWriteRequestResult? write(
    String deviceId,
    String characteristic,
    String text,
  ) =>
      writeHandler?.call(deviceId, BleUuidParser.string(characteristic), 0,
          Uint8List.fromList(text.codeUnits));

  /// A central turns notifications on for [characteristic].
  void subscribe(String deviceId, String characteristic, {bool on = true}) =>
      updateCharacteristicSubscription(
        BlePeripheralCharacteristicSubscriptionChanged(
          deviceId: deviceId,
          characteristicId: BleUuidParser.string(characteristic),
          isSubscribed: on,
          name: null,
        ),
      );

  Iterable<FakeNotification> notificationsOn(String characteristic) =>
      notifications.where(
          (n) => BleUuidParser.compareStrings(n.characteristicId, characteristic));

  // ── platform ──────────────────────────────────────────────────────────

  @override
  Future<BlePeripheralCapabilities> getCapabilities() async =>
      BlePeripheralCapabilities(
        supportsPeripheralMode: supportsPeripheralMode,
        supportsManufacturerDataInAdvertisement: true,
        supportsManufacturerDataInScanResponse: false,
        supportsServiceDataInAdvertisement: false,
        supportsServiceDataInScanResponse: false,
        supportsTargetedCharacteristicUpdate: true,
        supportsAdvertisingTimeout: false,
      );

  @override
  Future<PeripheralReadinessState> getAvailabilityState() async => readiness;

  @override
  Future<PeripheralAdvertisingState> getAdvertisingState() async =>
      advertisingNow;

  /// `PeripheralService` is a plugin-internal type, so the call is read
  /// reflectively rather than by importing the plugin's `src/`.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #addService) {
      final service = invocation.positionalArguments.first as dynamic;
      final error = addServiceError;
      if (error != null) return Future<void>.error(error);
      registered.add(FakeGattService(
        BleUuidParser.string(service.uuid as String),
        [
          for (final c in (service.characteristics as List))
            FakeGattCharacteristic(
              uuid: BleUuidParser.string((c as dynamic).uuid as String),
              properties:
                  List<CharacteristicProperty>.from((c as dynamic).properties as List),
              permissions: List<PeripheralAttributePermission>.from(
                  (c as dynamic).permissions as List),
            ),
        ],
      ));
      serviceRegistrations.add(registered.length);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }

  @override
  Future<void> removeService(String serviceId) async {
    registered.removeWhere(
        (s) => BleUuidParser.compareStrings(s.uuid, serviceId));
  }

  @override
  Future<void> clearServices() async {
    clearServicesCalls++;
    registered.clear();
  }

  @override
  Future<List<String>> getServices() async =>
      [for (final s in registered) s.uuid];

  @override
  Future<void> startAdvertising({
    required List<String> services,
    String? localName,
    Duration? timeout,
    ManufacturerData? manufacturerData,
    PeripheralPlatformConfig? platformConfig,
  }) async {
    final error = startAdvertisingError;
    if (error != null) throw error;
    advertised.add(FakeAdvertise(
      services: services,
      localName: localName,
      platformConfig: platformConfig,
    ));
    advertisingNow = PeripheralAdvertisingState.starting;
    final outcome = afterStart;
    if (outcome == null) return;
    // After this call has returned, which is when a real stack answers.
    Timer(Duration.zero, () {
      advertisingNow = outcome;
      updateAdvertisingState(
          BlePeripheralAdvertisingStateChanged(outcome, advertisingError));
    });
  }

  @override
  Future<void> stopAdvertising() async {
    stopAdvertisingCalls++;
    advertisingNow = PeripheralAdvertisingState.idle;
    updateAdvertisingState(BlePeripheralAdvertisingStateChanged(
        PeripheralAdvertisingState.idle, null));
  }

  @override
  Future<void> updateCharacteristicValue({
    required String characteristicId,
    required Uint8List value,
    String? deviceId,
  }) async {
    notifications.add(FakeNotification(characteristicId, value, deviceId));
  }

  @override
  Future<List<String>> getSubscribedClients(String characteristicId) async =>
      const [];

  @override
  Future<int?> getMaximumNotifyLength(String deviceId) async => maxNotifyLength;

  @override
  void setReadRequestHandler(OnPeripheralReadRequest? handler) {}

  @override
  void setWriteRequestHandler(OnPeripheralWriteRequest? handler) =>
      writeHandler = handler;

  @override
  void setDescriptorReadRequestHandler(
      OnPeripheralDescriptorReadRequest? handler) {}

  @override
  void setDescriptorWriteRequestHandler(
      OnPeripheralDescriptorWriteRequest? handler) {}
}

/// The GATT-client half: what a phone does as the receiving end, and what any
/// sender asks of it before it advertises (permissions).
class FakeBleCentral extends UniversalBlePlatform {
  /// What `requestPermissions` does: null grants, anything else is thrown.
  Object? permissionError;

  int permissionRequests = 0;
  final List<ScanFilter?> scans = [];
  int stopScans = 0;

  AvailabilityState availability = AvailabilityState.poweredOn;

  /// A scan result arrives, as the OS would deliver it.
  void discover({required String id, String? name, List<String>? services}) =>
      updateScanResult(BleDevice(
        deviceId: id,
        name: name,
        services: services ?? const [],
      ));

  @override
  Future<void> requestPermissions({bool withAndroidFineLocation = false}) async {
    permissionRequests++;
    final error = permissionError;
    if (error != null) throw error;
  }

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      availability;

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    scans.add(scanFilter);
  }

  @override
  Future<void> stopScan() async {
    stopScans++;
  }

  // ── the GATT-client half: what a receiver does once it has found a sender ──

  /// What `connect` does. Null connects; anything else is the failure.
  Object? connectError;

  /// What `requestMtu` does. Null answers [mtu]; anything else is thrown, as
  /// a platform that does not take the request does.
  Object? mtuError;
  int mtu = 247;

  final List<String> connects = [];
  final List<String> disconnects = [];
  final List<int> mtuRequests = [];
  final List<String> subscribed = [];
  final List<({String characteristic, String text})> writes = [];

  /// Characteristic writes whose text starts with [prefix], in order.
  List<String> wrote(String prefix) => [
        for (final w in writes)
          if (w.text.startsWith(prefix)) w.text
      ];

  /// The sender notifies [text] on [characteristic].
  void notify(String deviceId, String characteristic, String text) =>
      updateCharacteristicValue(deviceId, characteristic,
          Uint8List.fromList(text.codeUnits), null);

  /// The sender notifies raw bytes.
  void notifyBytes(String deviceId, String characteristic, List<int> bytes) =>
      updateCharacteristicValue(
          deviceId, characteristic, Uint8List.fromList(bytes), null);

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    connects.add(deviceId);
    final error = connectError;
    if (error != null) throw error;
    Timer(Duration.zero, () => updateConnection(deviceId, true));
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnects.add(deviceId);
    Timer(Duration.zero, () => updateConnection(deviceId, false));
  }

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      connects.contains(deviceId) && !disconnects.contains(deviceId)
          ? BleConnectionState.connected
          : BleConnectionState.disconnected;

  @override
  Future<List<BleService>> discoverServices(
          String deviceId, bool withDescriptors) async =>
      const [];

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    if (bleInputProperty != BleInputProperty.disabled) {
      subscribed.add(BleUuidParser.string(characteristic));
    }
  }

  @override
  Future<void> writeValue(String deviceId, String service, String characteristic,
      Uint8List value, BleOutputProperty bleOutputProperty) async {
    writes.add((
      characteristic: BleUuidParser.string(characteristic),
      text: String.fromCharCodes(value),
    ));
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    mtuRequests.add(expectedMtu);
    final error = mtuError;
    if (error != null) throw error;
    return mtu;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// What the plugin throws when the person says no to a permission.
PlatformException permissionsDenied([String which = 'BLUETOOTH_CONNECT']) =>
    PlatformException(code: 'failed', message: 'Permissions denied: $which');

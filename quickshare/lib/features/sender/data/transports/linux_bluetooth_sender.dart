import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

typedef LinuxBluetoothProgress = void Function(int sent, int total);
typedef LinuxBluetoothStatus = void Function(String status, [String? error]);

/// Minimal BlueZ GATT server used only by the Linux sender.
///
/// BlueZ exposes client APIs through most Flutter BLE plugins, but peripheral
/// mode still requires registering a local GATT application over D-Bus. This
/// class registers the QuickShare service/characteristics and an LE
/// advertisement, then streams the selected file as Value notifications after
/// the receiver writes START:<token> to the control characteristic.
class LinuxBluetoothSender {
  static const serviceUuid =
      'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';
  static const controlUuid =
      'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B11';
  static const metadataUuid =
      'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B12';
  static const dataUuid =
      'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B13';

  DBusClient? _bus;
  DBusRemoteObject? _adapter;
  _GattRoot? _gattRoot;
  _GattService? _service;
  _GattCharacteristic? _control;
  _GattCharacteristic? _metadata;
  _GattCharacteristic? _data;
  _BleAdvertisement? _advertisement;
  RandomAccessFile? _file;

  String? _token;
  FileMetadata? _fileMetadata;
  bool _dataNotifying = false;
  bool _startReceived = false;
  bool _transferStarted = false;
  bool _stopping = false;
  LinuxBluetoothProgress? _onProgress;
  LinuxBluetoothStatus? _onStatus;

  Future<void> start(
    FileMetadata file,
    String token, {
    required LinuxBluetoothProgress onProgress,
    required LinuxBluetoothStatus onStatus,
  }) async {
    await stop();
    _fileMetadata = file;
    _token = token;
    _onProgress = onProgress;
    _onStatus = onStatus;
    _stopping = false;

    try {
      final bus = DBusClient.system();
      _bus = bus;

      final rootPath = DBusObjectPath('/com/yourorg/quickshare');
      final servicePath = DBusObjectPath('/com/yourorg/quickshare/service');
      final controlPath = DBusObjectPath('/com/yourorg/quickshare/control');
      final metadataPath = DBusObjectPath('/com/yourorg/quickshare/metadata');
      final dataPath = DBusObjectPath('/com/yourorg/quickshare/data');

      final root = _GattRoot(rootPath);
      final service = _GattService(servicePath, rootPath, serviceUuid);
      late final _GattCharacteristic control;
      late final _GattCharacteristic metadata;
      late final _GattCharacteristic data;

      control = _GattCharacteristic(
        path: controlPath,
        servicePath: servicePath,
        uuid: controlUuid,
        flags: const ['write', 'write-without-response'],
        onWrite: (bytes) async {
          final command = utf8.decode(bytes, allowMalformed: true);
          if (command == 'START' || command == 'START:$_token') {
            _startReceived = true;
            await _maybeStartTransfer();
          }
        },
      );
      metadata = _GattCharacteristic(
        path: metadataPath,
        servicePath: servicePath,
        uuid: metadataUuid,
        flags: const ['read', 'notify'],
        onNotifyChanged: (notifying) async {
          if (notifying) await _maybeStartTransfer();
        },
      );
      data = _GattCharacteristic(
        path: dataPath,
        servicePath: servicePath,
        uuid: dataUuid,
        flags: const ['read', 'notify'],
        onNotifyChanged: (notifying) async {
          _dataNotifying = notifying;
          if (notifying) {
            _onStatus?.call('connected');
            await _maybeStartTransfer();
          }
        },
      );

      service.children = [control, metadata, data];
      _gattRoot = root;
      _service = service;
      _control = control;
      _metadata = metadata;
      _data = data;

      await bus.registerObject(root);
      await bus.registerObject(service);
      await bus.registerObject(control);
      await bus.registerObject(metadata);
      await bus.registerObject(data);

      final adapterPath = await _findAdapterPath(bus);
      final adapter = DBusRemoteObject(
        bus,
        name: 'org.bluez',
        path: adapterPath,
      );
      _adapter = adapter;
      await adapter.callMethod(
        'org.bluez.GattManager1',
        'RegisterApplication',
        [rootPath, DBusDict.stringVariant({})],
        replySignature: DBusSignature(''),
      );

      final advertisementRoot = _BleAdvertisementRoot(
        DBusObjectPath('/com/yourorg/quickshare_advertisement'),
      );
      final advertisement = _BleAdvertisement(
        DBusObjectPath('/com/yourorg/quickshare_advertisement/instance'),
        serviceUuid: serviceUuid,
        localName: 'QuickShare-${token.substring(0, 8)}',
      );
      _advertisement = advertisement;
      await bus.registerObject(advertisementRoot);
      await bus.registerObject(advertisement);
      await adapter.callMethod(
        'org.bluez.LEAdvertisingManager1',
        'RegisterAdvertisement',
        [advertisement.path, DBusDict.stringVariant({})],
        replySignature: DBusSignature(''),
      );

      _onStatus?.call('advertising');
    } catch (error) {
      await stop();
      rethrow;
    }
  }

  Future<DBusObjectPath> _findAdapterPath(DBusClient bus) async {
    final bluezRoot = DBusRemoteObject(
      bus,
      name: 'org.bluez',
      path: DBusObjectPath('/'),
    );
    final response = await bluezRoot.callMethod(
      'org.freedesktop.DBus.ObjectManager',
      'GetManagedObjects',
      const [],
      replySignature: DBusSignature('a{oa{sa{sv}}}'),
    );
    final managedObjects = response.returnValues.single.asDict();
    for (final entry in managedObjects.entries) {
      final interfaces = entry.value.asDict();
      final hasGatt = interfaces.keys.any(
        (interface) => interface.asString() == 'org.bluez.GattManager1',
      );
      final hasAdvertising = interfaces.keys.any(
        (interface) =>
            interface.asString() == 'org.bluez.LEAdvertisingManager1',
      );
      if (hasGatt && hasAdvertising) return entry.key.asObjectPath();
    }
    throw StateError('No Bluetooth adapter with BlueZ GATT support found.');
  }

  Future<void> _maybeStartTransfer() async {
    if (_transferStarted || !_dataNotifying || !_startReceived || _stopping) {
      return;
    }
    final metadata = _fileMetadata;
    final dataCharacteristic = _data;
    final metadataCharacteristic = _metadata;
    if (metadata == null ||
        dataCharacteristic == null ||
        metadataCharacteristic == null) {
      return;
    }

    _transferStarted = true;
    try {
      _file = await File(metadata.path).open();
      await metadataCharacteristic.setValue(
        utf8.encode(jsonEncode({
          'name': metadata.name,
          'size': metadata.size,
          'mime': metadata.mimeType,
        })),
      );

      const chunkSize = 182;
      var sent = 0;
      while (!_stopping && sent < metadata.size) {
        final chunk = await _file!.read(chunkSize);
        if (chunk.isEmpty) break;
        await dataCharacteristic.setValue(chunk);
        sent += chunk.length;
        _onProgress?.call(sent, metadata.size);
      }
      if (!_stopping && sent >= metadata.size) _onStatus?.call('completed');
    } catch (error) {
      if (!_stopping) _onStatus?.call('failed', error.toString());
    } finally {
      await _file?.close();
      _file = null;
    }
  }

  Future<void> stop() async {
    _stopping = true;
    try {
      if (_adapter != null && _advertisement != null) {
        await _adapter!.callMethod(
          'org.bluez.LEAdvertisingManager1',
          'UnregisterAdvertisement',
          [_advertisement!.path],
          replySignature: DBusSignature(''),
        );
      }
    } catch (_) {}
    try {
      if (_adapter != null && _gattRoot != null) {
        await _adapter!.callMethod(
          'org.bluez.GattManager1',
          'UnregisterApplication',
          [_gattRoot!.path],
          replySignature: DBusSignature(''),
        );
      }
    } catch (_) {}
    await _file?.close();
    _file = null;
    final bus = _bus;
    if (bus != null) {
      for (final object in [
        _advertisement,
        _gattRoot,
        _service,
        _control,
        _metadata,
        _data,
      ]) {
        if (object != null && object.client == bus) {
          try {
            await bus.unregisterObject(object);
          } catch (_) {}
        }
      }
      await bus.close();
    }
    _bus = null;
    _adapter = null;
    _gattRoot = null;
    _service = null;
    _control = null;
    _metadata = null;
    _data = null;
    _advertisement = null;
    _token = null;
    _fileMetadata = null;
    _onProgress = null;
    _onStatus = null;
    _dataNotifying = false;
    _startReceived = false;
    _transferStarted = false;
  }
}

abstract class _GattObject extends DBusObject {
  final String interfaceName;
  final Map<String, DBusValue> properties;

  _GattObject(super.path, this.interfaceName, this.properties);

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
        interfaceName: properties,
      };

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface != interfaceName) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    return DBusGetAllPropertiesResponse(properties);
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != interfaceName) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final value = properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }
}

class _GattRoot extends DBusObject {
  _GattRoot(super.path) : super(isObjectManager: true);
}

class _GattService extends _GattObject {
  List<_GattCharacteristic> children = [];

  _GattService(DBusObjectPath path, DBusObjectPath rootPath, String uuid)
      : super(path, 'org.bluez.GattService1', {
          'UUID': DBusString(uuid),
          'Primary': const DBusBoolean(true),
          'Includes': DBusArray.objectPath(const []),
        });
}

typedef _GattWriteHandler = Future<void> Function(List<int> value);
typedef _GattNotifyHandler = Future<void> Function(bool notifying);

class _GattCharacteristic extends _GattObject {
  final _GattWriteHandler? onWrite;
  final _GattNotifyHandler? onNotifyChanged;
  bool _notifying = false;
  List<int> _value = const [];

  _GattCharacteristic({
    required DBusObjectPath path,
    required DBusObjectPath servicePath,
    required String uuid,
    required List<String> flags,
    this.onWrite,
    this.onNotifyChanged,
  }) : super(path, 'org.bluez.GattCharacteristic1', {
          'Service': servicePath,
          'UUID': DBusString(uuid),
          'Flags': DBusArray.string(flags),
          'Value': DBusArray.byte(const []),
          'Notifying': const DBusBoolean(false),
        });

  bool get notifying => _notifying;

  Future<void> setValue(List<int> value) async {
    _value = List<int>.from(value);
    properties['Value'] = DBusArray.byte(_value);
    await emitPropertiesChanged(
      interfaceName,
      changedProperties: {'Value': properties['Value']!},
    );
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != interfaceName) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'ReadValue':
        return DBusMethodSuccessResponse([DBusArray.byte(_value)]);
      case 'WriteValue':
        if (onWrite == null || methodCall.values.isEmpty) {
          return DBusMethodErrorResponse.unknownMethod();
        }
        await onWrite!(methodCall.values.first.asByteArray().toList());
        return DBusMethodSuccessResponse();
      case 'StartNotify':
        _notifying = true;
        properties['Notifying'] = const DBusBoolean(true);
        await emitPropertiesChanged(interfaceName, changedProperties: {
          'Notifying': properties['Notifying']!,
        });
        await onNotifyChanged?.call(true);
        return DBusMethodSuccessResponse();
      case 'StopNotify':
        _notifying = false;
        properties['Notifying'] = const DBusBoolean(false);
        await emitPropertiesChanged(interfaceName, changedProperties: {
          'Notifying': properties['Notifying']!,
        });
        await onNotifyChanged?.call(false);
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}

class _BleAdvertisementRoot extends DBusObject {
  _BleAdvertisementRoot(super.path);
}

class _BleAdvertisement extends _GattObject {
  _BleAdvertisement(
    DBusObjectPath path, {
    required String serviceUuid,
    required String localName,
  }) : super(path, 'org.bluez.LEAdvertisement1', {
          'Type': const DBusString('peripheral'),
          'ServiceUUIDs': DBusArray.string([serviceUuid]),
          'LocalName': DBusString(localName),
          'Includes': DBusArray.string(const []),
        });

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == interfaceName && methodCall.name == 'Release') {
      return DBusMethodSuccessResponse();
    }
    return super.handleMethodCall(methodCall);
  }
}

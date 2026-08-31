import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

typedef LinuxBluetoothProgress = void Function(int sent, int total);
typedef LinuxBluetoothStatus = void Function(String status, [String? error]);

/// Minimal BlueZ GATT server used only by the Linux sender.
///
/// BlueZ exposes client APIs through most Flutter BLE plugins, but peripheral
/// mode still requires registering a local GATT application over D-Bus. This
/// class registers the DirectDrop service/characteristics and an LE
/// advertisement, then streams the selected file as Value notifications after
/// the receiver writes START:<token> to the control characteristic.
class LinuxBluetoothSender {
  static const serviceUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';
  static const controlUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B11';
  static const metadataUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B12';
  static const dataUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B13';

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

  /// The session being served, in send order. One entry for a single file,
  /// one per file for a folder — the same list the other BLE senders take.
  List<FileMetadata> _sessionFiles = const [];
  /// What the receiver said it can take, from its `CAPS:` write. Null means
  /// it never sent one — a build that stops at the first file.
  int? _peerGeneration;
  bool _dataNotifying = false;
  bool _startReceived = false;
  bool _transferStarted = false;
  bool _stopping = false;
  LinuxBluetoothProgress? _onProgress;
  LinuxBluetoothStatus? _onStatus;

  Future<void> start(
    List<FileMetadata> files,
    String token, {
    required LinuxBluetoothProgress onProgress,
    required LinuxBluetoothStatus onStatus,
  }) async {
    await stop();
    _sessionFiles = files;
    _peerGeneration = null;
    _token = token;
    _onProgress = onProgress;
    _onStatus = onStatus;
    _stopping = false;

    try {
      final bus = DBusClient.system();
      _bus = bus;

      final rootPath = DBusObjectPath('/com/directdrop/app');
      final servicePath = DBusObjectPath('/com/directdrop/app/service');
      final controlPath = DBusObjectPath('/com/directdrop/app/control');
      final metadataPath = DBusObjectPath('/com/directdrop/app/metadata');
      final dataPath = DBusObjectPath('/com/directdrop/app/data');

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
          // Always ahead of START, so it is on record before the decision
          // about what this session may send is taken.
          final generation = BleControlProtocol.parseCapabilities(command);
          if (generation != null) {
            _peerGeneration = generation;
            return;
          }
          if (BleControlProtocol.isStart(command, _token)) {
            _startReceived = true;
            await _maybeStartTransfer();
          } else if (BleControlProtocol.isUnauthorizedStart(command, _token)) {
            // A START without the session token — a receiver too old to pair
            // securely. Say so rather than leaving both sides waiting.
            _onStatus?.call('failed', BleControlProtocol.staleReceiverMessage);
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
        DBusObjectPath('/com/directdrop/app_advertisement'),
      );
      final advertisement = _BleAdvertisement(
        DBusObjectPath('/com/directdrop/app_advertisement/instance'),
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
    final session = _sessionFiles;
    final dataCharacteristic = _data;
    final metadataCharacteristic = _metadata;
    if (session.isEmpty ||
        dataCharacteristic == null ||
        metadataCharacteristic == null) {
      return;
    }

    _transferStarted = true;
    // Half a folder delivered in silence is worse than a refusal: an older
    // receiver ends the transfer at the first file and reports success.
    if (!BleControlProtocol.peerCanTakeSession(
        fileCount: session.length, peerGeneration: _peerGeneration)) {
      _onStatus?.call('failed', BleControlProtocol.sessionRefusedMessage);
      return;
    }
    final sessionBytes = session.fold<int>(0, (sum, f) => sum + f.size);
    var sessionSent = 0;
    try {
      for (var index = 0; index < session.length; index++) {
        if (_stopping) return;
        final item = session[index];
        _file = await File(item.path).open();
        await metadataCharacteristic.setValue(
          utf8.encode(jsonEncode({
            'name': item.name,
            // Where this file sits inside the selection, so a folder is
            // rebuilt on the far side instead of arriving as a heap of files
            // or as an archive to unpack.
            'path': item.relPath,
            'size': item.size,
            'mime': item.mimeType,
            'index': index,
            'count': session.length,
            'sessionBytes': sessionBytes,
          })),
        );

        const chunkSize = 182;
        var fileSent = 0;
        try {
          while (!_stopping && fileSent < item.size) {
            final chunk = await _file!.read(chunkSize);
            if (chunk.isEmpty) break;
            await dataCharacteristic.setValue(chunk);
            fileSent += chunk.length;
            sessionSent += chunk.length;
            // Progress belongs to the session, not to whichever file happens
            // to be open.
            _onProgress?.call(sessionSent, sessionBytes);
          }
        } finally {
          await _file?.close();
          _file = null;
        }
        if (fileSent < item.size) return;
      }
      if (!_stopping) _onStatus?.call('completed');
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
    _sessionFiles = const [];
    _peerGeneration = null;
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

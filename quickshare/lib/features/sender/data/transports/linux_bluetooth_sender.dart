import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_frame.dart';

/// [error] is English and technical; [code] is the same fact as a
/// `FailureCode`, where this bridge decided it rather than caught it.
typedef LinuxBluetoothStatus = void Function(String status,
    [String? error, String? code]);
typedef LinuxBluetoothApOffer = void Function(String sealed);
typedef LinuxBluetoothPeerKey = void Function(String publicKey);

/// Minimal BlueZ GATT server used only by the Linux sender.
///
/// BlueZ exposes client APIs through most Flutter BLE plugins, but peripheral
/// mode still requires registering a local GATT application over D-Bus. This
/// class registers the DirectDrop service/characteristics and an LE
/// advertisement.
///
/// Since protocol generation 4 the channel is the rendezvous, not the road:
/// once the receiver's subscriptions are up and its START has arrived, this
/// sender reports `ready` and the `DirectLinkCoordinator` builds the Wi-Fi
/// link the file actually crosses. What stays here is the negotiation itself
/// — CAPS/START/AP on the control characteristic, link frames on the
/// metadata one (see [notifyLinkFrame]).
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

  String? _token;

  /// The ATT MTU the receiver's connection negotiated, as BlueZ last reported
  /// it (see [mtuOfWrite]). Null until a write has said.
  int? _peerMtu;

  /// Numbers this session's frames; see [notifyLinkFrame].
  BleFrameSplitter _splitter = BleFrameSplitter();

  /// What the receiver said it can take, from its `CAPS:` write. Null means
  /// it never sent one — a build that predates the direct link.
  int? _peerGeneration;
  bool _dataNotifying = false;
  bool _startReceived = false;
  bool _transferStarted = false;
  bool _stopping = false;
  LinuxBluetoothStatus? _onStatus;
  LinuxBluetoothApOffer? _onApOffer;
  LinuxBluetoothPeerKey? _onPeerKey;
  void Function(String, String)? _onPairing;

  final _pairingFrames = <String, BleFrameAssembler>{};

  void _acceptPairingPart(String peer, Uint8List bytes) {
    if (peer.isEmpty) return;
    if (!_pairingFrames.containsKey(peer) && _pairingFrames.length >= 8) return;
    final assembler = _pairingFrames.putIfAbsent(
        peer,
        () => BleFrameAssembler(
              maxFrameBytes: 180,
              onFrame: (frame) {
                _pairingFrames.remove(peer)?.dispose();
                _onPairing?.call(
                    peer, utf8.decode(frame, allowMalformed: true));
              },
              onFault: (_) => _pairingFrames.remove(peer)?.dispose(),
            ));
    assembler.add(bytes);
  }

  @visibleForTesting
  void debugAcceptPairingPart(String peer, Uint8List bytes,
      void Function(String peer, String command) onPairing) {
    _onPairing = onPairing;
    _acceptPairingPart(peer, bytes);
  }

  Future<void> start(
    String token, {
    String locator = '',
    required LinuxBluetoothStatus onStatus,
    LinuxBluetoothApOffer? onApOffer,
    LinuxBluetoothPeerKey? onPeerKey,
    void Function(String, String)? onPairing,
  }) async {
    await stop();
    _peerGeneration = null;
    _peerMtu = null;
    _splitter = BleFrameSplitter();
    _token = token;
    _onStatus = onStatus;
    _onApOffer = onApOffer;
    _onPeerKey = onPeerKey;
    _onPairing = onPairing;
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
        onWrite: (bytes, mtu, peer) async {
          // Returns false to refuse the write; BlueZ turns that into an ATT
          // error for the peer, which is the only way this side can say no.

          // The MTU the connection ended up with, which is what bounds a
          // notification back. The latest answer wins: it can be renegotiated.
          if (mtu != null) _peerMtu = mtu;

          final command = utf8.decode(bytes, allowMalformed: true);
          if (bytes.isNotEmpty && bytes.first == BleFrame.marker) {
            _acceptPairingPart(peer, Uint8List.fromList(bytes));
            return true;
          }
          if (command.startsWith('PAIR:') && bytes.length <= 180) {
            if (peer.isEmpty) return false;
            _onPairing?.call(peer, command);
            return true;
          }
          // Always ahead of START, so it is on record before the decision
          // about what this session may send is taken.
          final generation = BleControlProtocol.parseCapabilities(command);
          if (generation != null) {
            _peerGeneration = generation;
            return true;
          }
          if (BleControlProtocol.parseKeyExchange(command) case final key?) {
            _onPeerKey?.call(key);
            return true;
          }
          if (BleControlProtocol.parseApOffer(command) case final sealed?) {
            // A receiver that raised the network itself says where — sealed.
            _onApOffer?.call(sealed);
            return true;
          }
          if (BleControlProtocol.isStart(command, _token)) {
            _startReceived = true;
            await _maybeStartTransfer();
          } else if (BleControlProtocol.isUnauthorizedStart(command, _token)) {
            // A START without the session token — a receiver too old to pair
            // securely. Say so rather than leaving both sides waiting.
            _onStatus?.call('failed', BleControlProtocol.staleReceiverMessage,
                FailureCode.receiverTooOldToPair);
            // And refuse the write. Answering success told that receiver its
            // transfer had begun while this side tore the session down behind
            // it, so it waited on bytes that were never coming.
            return false;
          }
          return true;
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
          if (!notifying && !_transferStarted) _onStatus?.call('advertising');
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
        localName: 'QuickShare-${locator.isNotEmpty ? locator : 'directdrop'}',
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

  /// Pushes a negotiation frame — `{"link": …}` or `{"serve": …}` — to the
  /// connected receiver as metadata notifications, cut into parts that each fit
  /// the connection (see [BleFrame]).
  ///
  /// What a notification carries is the negotiated ATT MTU less three, and the
  /// stack that sends it cuts a longer one to that without a word. BlueZ does
  /// not offer the MTU of a notification's own connection to a service
  /// registered over D-Bus (`AcquireNotify` would, but returns a file
  /// descriptor this client cannot read), so it is taken from the `mtu` option
  /// BlueZ puts on every write the receiver makes — which it has made several of
  /// (CAPS, KEX, START) before the first frame goes out. Without one it is
  /// [BleFrame.defaultNotificationBytes].
  ///
  /// There is no way to ask BlueZ to wait: each part is a `PropertiesChanged`
  /// signal for `Value`, and the daemon sends them in the order it receives them
  /// on the bus. Called from [BluetoothTransferTransport], which lets one frame
  /// finish before the next begins.
  Future<void> notifyLinkFrame(Map<String, Object?> frame) async {
    if (_stopping) return;
    final emit = debugEmit ?? _metadata?.setValue;
    if (emit == null) return;
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(frame)));
    // BlueZ broadcasts these notifications to all subscribed centrals, and
    // the most recent write's MTU may belong to a different pairing peer.
    // Pairing responses must therefore fit the minimum MTU for every listener.
    final limit = frame.containsKey('pair')
        ? BleFrame.defaultNotificationBytes
        : notificationBytes(_peerMtu);
    final parts = _splitter.split(bytes, notificationBytes: limit);
    for (final part in parts) {
      if (_stopping) return;
      await emit(part);
    }
  }

  /// What one notification carries on a connection whose MTU is [mtu], or on
  /// one nobody has reported: the MTU less the three bytes of ATT header, never
  /// more than an attribute value can be, and the least a connection carries
  /// when there is no answer.
  @visibleForTesting
  static int notificationBytes(int? mtu) {
    if (mtu == null || mtu <= 3) return BleFrame.defaultNotificationBytes;
    return math.min(mtu - 3, BleFrame.maxNotificationBytes);
  }

  /// The ATT MTU in the options of a `WriteValue` call, when BlueZ gave one.
  ///
  /// Options are `a{sv}`; BlueZ has put `mtu` (a `q`, "Exchanged MTU") in them
  /// for the server side since 5.50. Anything else — a dictionary without it, a
  /// value of another type, no dictionary — is "not said".
  @visibleForTesting
  static int? mtuOfWrite(List<DBusValue> arguments) {
    if (arguments.length < 2) return null;
    try {
      for (final entry in arguments[1].asDict().entries) {
        if (entry.key.asString() == 'mtu') {
          return entry.value.asVariant().asUint16();
        }
      }
    } catch (_) {
      // Not a dictionary of variants, or not a number: not said.
    }
    return null;
  }

  static String peerOfWrite(List<DBusValue> arguments) {
    if (arguments.length >= 2) {
      try {
        for (final entry in arguments[1].asDict().entries) {
          if (entry.key.asString() == 'device') {
            return entry.value.asVariant().asObjectPath().value;
          }
        }
      } catch (_) {}
    }
    // BlueZ is expected to supply the central's object path; an absent one
    // cannot authorize a numeric-code exchange.
    return '';
  }

  /// Where a part goes instead of the characteristic, for a test that has no
  /// D-Bus to put it on.
  @visibleForTesting
  Future<void> Function(Uint8List part)? debugEmit;

  /// The MTU a write reported, set by hand in a test.
  @visibleForTesting
  set debugPeerMtu(int? mtu) => _peerMtu = mtu;

  /// The session is fully dressed — the receiver's notifications are up and
  /// its START has arrived — so the session may begin.
  ///
  /// Since generation 4 "begins" never means streaming bytes here: a peer
  /// that understands the direct link is reported as `ready` and the
  /// coordinator builds the network the file actually crosses, and a peer
  /// below it is refused with the update it needs rather than sent anything
  /// slowly.
  Future<void> _maybeStartTransfer() async {
    if (_transferStarted || !_dataNotifying || !_startReceived || _stopping) {
      return;
    }
    _transferStarted = true;
    if (!BleControlProtocol.peerSupportsDirectLink(_peerGeneration)) {
      _onStatus?.call('failed', BleControlProtocol.directLinkRequiredMessage,
          FailureCode.receiverTooOldForDirectLink);
      return;
    }
    _onStatus?.call('ready');
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
    _peerGeneration = null;
    _peerMtu = null;
    _onStatus = null;
    _onApOffer = null;
    _onPeerKey = null;
    _onPairing = null;
    for (final frames in _pairingFrames.values) {
      frames.dispose();
    }
    _pairingFrames.clear();
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

/// Handles one write. False refuses it, which BlueZ answers as an ATT error
/// for the peer; true accepts.
typedef _GattWriteHandler = Future<bool> Function(
    List<int> value, int? mtu, String peer);
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
        final accepted = await onWrite!(
            methodCall.values.first.asByteArray().toList(),
            LinuxBluetoothSender.mtuOfWrite(methodCall.values),
            LinuxBluetoothSender.peerOfWrite(methodCall.values));
        if (!accepted) {
          // BlueZ maps this to insufficient authentication for the peer —
          // the same answer Apple's bridges give, and the same one Android
          // gives through its ATT status.
          return DBusMethodErrorResponse('org.bluez.Error.NotAuthorized',
              [const DBusString('the session token is missing or wrong')]);
        }
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

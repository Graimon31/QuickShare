import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_frame.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'ble_receiver_failure.dart';
import 'universal_ble_receiver_transport.dart';

export 'ble_receiver_failure.dart' show BleReceiverFailure;
export 'universal_ble_receiver_transport.dart' show UniversalBleReceiverTransport;

class BluetoothDevice extends Equatable {
  final String id;
  final String name;
  const BluetoothDevice({required this.id, required this.name});
  @override
  List<Object?> get props => [id, name];
}

/// What a receive screen needs from a BLE receiver, whichever platform
/// implements it: discovery, and the direct-link negotiation the transfer
/// rides on. **Not the transfer itself** — since protocol generation 4 the
/// file crosses a Wi-Fi link over QHTP, and a sender that still pushes it over
/// Bluetooth is refused with the update it needs.
///
/// [BluetoothReceiverTransport] (native CoreBluetooth, iOS/macOS) and
/// [_UniversalBleReceiverAdapter] (universal_ble, Android/Windows) both
/// answer this; [BluetoothReceiverTransport.forPlatform] picks.
abstract interface class BleReceiver {
  Stream<BluetoothDevice> get devices;
  Stream<DirectLinkDirective> get linkDirectives;
  Stream<LinkServeInfo> get serveInfos;

  /// A problem on the radio after [connect]: a sender too old for the direct
  /// link, an unreadable frame, a connection that dropped. Which of them still
  /// matters is the session's call — after the serve frame, none does.
  Stream<BleReceiverFailure> get failures;

  Future<void> startScanning({String? sessionToken, String? locator});
  Future<void> stopScanning();

  /// Connects to [deviceId] and starts the handshake. [token] authorises the
  /// session; the native bridge already holds it from [startScanning], the
  /// universal transport writes it as `START:<token>` here and cannot connect
  /// without it.
  ///
  /// Completes once the handshake is under way (universal: START has been
  /// written; native: the bridge has been told to connect, and reports a
  /// failure on [failures]). Throws when the device cannot be connected to.
  Future<void> connect(String deviceId, {String? token});

  /// Tells the sender about a network this receiver raised, sealed.
  Future<void> sendApOffer(String sealed);

  /// Hands the sender this side's public half for the negotiation.
  Future<void> sendKeyExchange(String publicKey);

  Future<void> cancel();
  Future<void> dispose();
}

/// Native CoreBluetooth receiver for iOS and macOS.
///
/// On Android and Windows, use [UniversalBleReceiverTransport] instead.
/// The static factory [BluetoothReceiverTransport.forPlatform] picks the right
/// one automatically.
class BluetoothReceiverTransport implements BleReceiver {
  static const _method = MethodChannel('quickshare/bluetooth');
  static const _events = EventChannel('quickshare/bluetooth/events');

  StreamSubscription? _eventSub;
  final _devicesController = StreamController<BluetoothDevice>.broadcast();
  final _failureController = StreamController<BleReceiverFailure>.broadcast();

  @override
  Stream<BluetoothDevice> get devices => _devicesController.stream;

  @override
  Stream<BleReceiverFailure> get failures => _failureController.stream;

  /// Who raises the direct Wi-Fi link and how to reach it — the sender's
  /// `{"link": …}` frames, decoded for the coordinator.
  final _linkDirectiveController =
      StreamController<DirectLinkDirective>.broadcast();

  /// Where the file is served once the link is up — the sender's
  /// `{"serve": …}` frames, decoded.
  final _serveInfoController = StreamController<LinkServeInfo>.broadcast();

  @override
  Stream<DirectLinkDirective> get linkDirectives =>
      _linkDirectiveController.stream;

  @override
  Stream<LinkServeInfo> get serveInfos => _serveInfoController.stream;

  /// Tells the sender about a network this receiver raised: an `AP:` write
  /// on the control characteristic of the peripheral it connected to.
  @override
  Future<void> sendApOffer(String sealed) async {
    await _method.invokeMethod('sendApOffer', {'sealed': sealed});
  }

  @override
  Future<void> sendKeyExchange(String publicKey) async {
    await _method.invokeMethod('sendKeyExchange', {'key': publicKey});
  }

  // -------------------------------------------------------------------------
  // Factory: returns the right receiver for the current platform.
  // -------------------------------------------------------------------------

  /// Returns `true` when the native Apple CoreBluetooth bridge should be used.
  ///
  /// The universal_ble Central role is available on macOS too, but the native
  /// bridge is already installed and tested, so we leave it as-is for the
  /// receiver on Apple platforms.
  static bool get _usesNativeBridge =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// Creates the appropriate BLE receiver for the current platform.
  ///
  /// On iOS/macOS: a [BluetoothReceiverTransport] (CoreBluetooth).
  /// On Android/Windows: a [UniversalBleReceiverTransport] behind an adapter.
  /// Both answer [BleReceiver], so the caller never branches on the type.
  static BleReceiver forPlatform() {
    if (_usesNativeBridge) {
      AppLogger.info('BLE receiver: using native CoreBluetooth bridge',
          tag: 'BLE_RECEIVER');
      return BluetoothReceiverTransport();
    }
    AppLogger.info('BLE receiver: using universal_ble GATT Central',
        tag: 'BLE_RECEIVER');
    return _UniversalBleReceiverAdapter(UniversalBleReceiverTransport());
  }

  // -------------------------------------------------------------------------
  // Native CoreBluetooth implementation (iOS / macOS)
  // -------------------------------------------------------------------------

  @override
  Future<void> startScanning({String? sessionToken, String? locator}) async {
    _eventSub ??= _events.receiveBroadcastStream().listen(
          _handleEvent,
          onError: (Object e) =>
              debugPrint('Bluetooth receiver event stream error: $e'),
        );
    try {
      await _method.invokeMethod('startScanning', {
        if (sessionToken != null) 'sessionToken': sessionToken,
        // What the sender actually advertises: the session's random locator,
        // which the QR carries. Matching on the token's first characters is
        // what earlier builds did, and it only worked because the sender was
        // broadcasting part of its own secret.
        if (locator != null && locator.isNotEmpty) 'locator': locator,
      });
    } on MissingPluginException {
      throw Exception('Bluetooth is unavailable in this build.');
    }
  }

  @override
  Future<void> stopScanning() async {
    try {
      await _method.invokeMethod('stopScanning');
    } catch (_) {
      // best effort
    }
  }

  /// Starts connecting to [deviceId]. [token] is accepted for the
  /// [BleReceiver] contract and ignored — the bridge took it in
  /// [startScanning], and writes `START:<token>` itself once its
  /// characteristics are resolved.
  @override
  Future<void> connect(String deviceId, {String? token}) async {
    await _method.invokeMethod('connect', {'deviceId': deviceId});
  }

  void _handleEvent(dynamic event) {
    final map = Map<String, dynamic>.from(event as Map);
    switch (map['type']) {
      case 'deviceDiscovered':
        _devicesController.add(BluetoothDevice(
            id: map['id'] as String, name: map['name'] as String));
        break;

      // The rendezvous' negotiation frames, off the metadata characteristic.
      case 'linkDirective':
        final link = map['link'];
        if (link is Map) {
          final json = Map<String, Object?>.from(link);
          // A sender of generation 4 or below, still putting the code's digits
          // in the frame: refused at the first frame with the update it needs,
          // not after the negotiation has run out its budget.
          if (DirectLinkDirective.fromOlderGeneration(json)) {
            _failureController.add(const BleReceiverFailure(
                BleControlProtocol.senderTooOldMessage,
                FailureCode.senderTooOldForDirectLink));
            break;
          }
          final directive = DirectLinkDirective.fromJson(json);
          if (directive != null) _linkDirectiveController.add(directive);
        }
        break;

      case 'serveInfo':
        final serve = map['serve'];
        if (serve is Map) {
          final info =
              LinkServeInfo.fromJson(Map<String, Object?>.from(serve));
          if (info != null) {
            _serveInfoController.add(info);
          } else {
            // The last frame of the rendezvous, with nothing after it to carry
            // on without: dropped, it would leave the screen waiting for an
            // address that was never going to arrive.
            _failureController.add(const BleReceiverFailure(
                '${BleFrame.damagedMessage} The serve frame is missing what a '
                'receiver needs to pull the file.',
                FailureCode.bluetoothTransferFailed));
          }
        }
        break;

      case 'receiverDisconnected':
        _failureController.add(const BleReceiverFailure(
            'The connection to the sending device dropped.',
            FailureCode.linkPeerLost));
        break;

      case 'receiverFailed':
        final err = map['error'] as String? ?? 'Unknown error';
        final errCode = map['code'] as String?;
        debugPrint('Bluetooth receive failed: $err (code: $errCode)');
        _failureController.add(BleReceiverFailure(
            err,
            errCode == 'senderTooOldForDirectLink'
                ? FailureCode.senderTooOldForDirectLink
                : FailureCode.bluetoothTransferFailed));
        break;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _method.invokeMethod('cancelTransfer');
    } catch (_) {
      // best effort
    }
  }

  @override
  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    await _devicesController.close();
    await _failureController.close();
    await _linkDirectiveController.close();
    await _serveInfoController.close();
  }
}

/// [BleReceiver] over the universal_ble GATT-central receiver, for Android
/// and Windows. Pure translation: the device shape differs between the two
/// implementations, the contract does not.
class _UniversalBleReceiverAdapter implements BleReceiver {
  final UniversalBleReceiverTransport _inner;

  _UniversalBleReceiverAdapter(this._inner);

  @override
  Stream<BluetoothDevice> get devices => _inner.devices.map((d) =>
      BluetoothDevice(id: d.deviceId, name: d.name ?? 'Unknown device'));

  @override
  Stream<DirectLinkDirective> get linkDirectives => _inner.linkDirectives;

  @override
  Stream<LinkServeInfo> get serveInfos => _inner.serveInfos;

  @override
  Stream<BleReceiverFailure> get failures => _inner.failures;

  @override
  Future<void> startScanning({String? sessionToken, String? locator}) =>
      _inner.startScanning(sessionToken: sessionToken, locator: locator);

  @override
  Future<void> stopScanning() => _inner.stopScanning();

  @override
  Future<void> connect(String deviceId, {String? token}) async {
    if (token == null || token.isEmpty) {
      // The universal transport writes START:<token> itself, so it has no
      // announce-without-a-session path the native bridge has.
      throw Exception('Missing session token — scan the QR code again.');
    }
    await _inner.connect(deviceId, token: token);
  }

  @override
  Future<void> sendApOffer(String sealed) => _inner.sendApOffer(sealed);

  @override
  Future<void> sendKeyExchange(String publicKey) =>
      _inner.sendKeyExchange(publicKey);

  @override
  Future<void> cancel() => _inner.cancel();

  @override
  Future<void> dispose() => _inner.dispose();
}

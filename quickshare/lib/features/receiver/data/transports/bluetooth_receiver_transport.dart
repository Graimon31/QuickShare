import 'dart:async';
import 'dart:io' show Platform;
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'universal_ble_receiver_transport.dart';

export 'universal_ble_receiver_transport.dart'
    show UniversalBleReceiverTransport, UniversalBleReceiveProgress;

class BluetoothDevice extends Equatable {
  final String id;
  final String name;
  const BluetoothDevice({required this.id, required this.name});
  @override
  List<Object?> get props => [id, name];
}

class BluetoothReceiveProgress {
  final String phase; // 'connecting' | 'transferring' | 'completed' | 'failed'
  final String fileName;
  final int received;
  final int total;
  final String? error;
  final String? errorCode;

  const BluetoothReceiveProgress({
    required this.phase,
    required this.fileName,
    required this.received,
    required this.total,
    this.error,
    this.errorCode,
  });
}

/// What a receive screen needs from a BLE receiver, whichever platform
/// implements it: discovery, the transfer itself, and the direct-link
/// negotiation the transfer rides on since protocol generation 4.
///
/// [BluetoothReceiverTransport] (native CoreBluetooth, iOS/macOS) and
/// [_UniversalBleReceiverAdapter] (universal_ble, Android/Windows) both
/// answer this; [BluetoothReceiverTransport.forPlatform] picks.
abstract interface class BleReceiver {
  Stream<BluetoothDevice> get devices;
  Stream<BluetoothReceiveProgress> get progressStream;
  Stream<DirectLinkDirective> get linkDirectives;
  Stream<LinkServeInfo> get serveInfos;

  Future<void> startScanning({String? sessionToken, String? publicId});
  Future<void> stopScanning();

  /// Advertise so a sender can find this device and connect to it.
  ///
  /// Generation-4 Bluetooth is sender-finds-receiver: this device lights up
  /// as a GATT peripheral, the sender scans, and the person sending picks
  /// the row. The previous direction (this side scanning for the sender)
  /// is what made a Mac receiving from an iPhone fail to appear in the list.
  Future<void> startWaitingAdvertisement({required String deviceName});

  /// Connects to [deviceId] and resolves with the saved file path once the
  /// transfer completes. [token] authorises the session; the native bridge
  /// already holds it from [startScanning], the universal transport writes
  /// it as `START:<token>` here and cannot connect without it.
  Future<String> connect(String deviceId, {String? token, String? targetDir});

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
  final _progressController =
      StreamController<BluetoothReceiveProgress>.broadcast();
  Completer<String>? _completion;

  String _fileName = 'received_file';
  int _total = 0;

  @override
  Stream<BluetoothDevice> get devices => _devicesController.stream;
  @override
  Stream<BluetoothReceiveProgress> get progressStream =>
      _progressController.stream;

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
  /// On macOS the bridge handles both the peripheral (sender) and central
  /// (receiver) roles. The universal_ble Central role is available on macOS
  /// too, but the native bridge is already installed and tested, so we leave
  /// it as-is for receiver on Apple platforms.
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
  Future<void> startScanning({String? sessionToken, String? publicId}) async {
    _eventSub ??= _events.receiveBroadcastStream().listen(
          _handleEvent,
          onError: (Object e) =>
              debugPrint('Bluetooth receiver event stream error: $e'),
        );
    try {
      await _method.invokeMethod('startScanning', {
        if (sessionToken != null) 'sessionToken': sessionToken,
        // What the sender actually advertises. Matching on the token's first
        // characters is what earlier builds did, and it only worked because
        // the sender was broadcasting part of its own secret.
        if (publicId != null && publicId.isNotEmpty) 'publicId': publicId,
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

  @override
  Future<void> startWaitingAdvertisement({required String deviceName}) async {
    _eventSub ??= _events.receiveBroadcastStream().listen(
          _handleEvent,
          onError: (Object e) =>
              debugPrint('Bluetooth receiver event stream error: $e'),
        );
    try {
      await _method.invokeMethod('startReceiverAdvertising', {
        'deviceName': deviceName,
      });
    } on MissingPluginException {
      throw Exception('Bluetooth is unavailable in this build.');
    }
  }

  /// Connects to [deviceId] and resolves with the saved file path once the
  /// transfer completes.
  ///
  /// [targetDir] is where the bytes land. Callers pass a transfer-cache
  /// session directory: what arrives is not the user's yet, and the decision
  /// about where it belongs is made once the transfer is finished. [token] is
  /// accepted for the [BleReceiver] contract and ignored — the bridge took it
  /// in [startScanning].
  @override
  Future<String> connect(String deviceId,
      {String? token, String? targetDir}) async {
    final completer = Completer<String>();
    _completion = completer;

    final dir = targetDir ??
        (Platform.isIOS
            ? (await getApplicationDocumentsDirectory()).path
            : (await getDownloadsDirectory())?.path ??
                (await getTemporaryDirectory()).path);
    await _method
        .invokeMethod('connect', {'deviceId': deviceId, 'targetDir': dir});
    return completer.future;
  }

  void _handleEvent(dynamic event) {
    final map = Map<String, dynamic>.from(event as Map);
    switch (map['type']) {
      case 'deviceDiscovered':
        _devicesController.add(BluetoothDevice(
            id: map['id'] as String, name: map['name'] as String));
        break;

      case 'connecting':
        _progressController.add(BluetoothReceiveProgress(
            phase: 'connecting', fileName: _fileName, received: 0, total: 0));
        break;

      // The rendezvous' negotiation frames, off the metadata characteristic
      // before any file metadata could arrive there.
      case 'linkDirective':
        final link = map['link'];
        if (link is Map) {
          final directive = DirectLinkDirective.fromJson(
              Map<String, Object?>.from(link));
          if (directive != null) _linkDirectiveController.add(directive);
        }
        break;

      case 'serveInfo':
        final serve = map['serve'];
        if (serve is Map) {
          final info =
              LinkServeInfo.fromJson(Map<String, Object?>.from(serve));
          if (info != null) _serveInfoController.add(info);
        }
        break;

      case 'metadataReceived':
        _fileName = map['name'] as String? ?? _fileName;
        _total = map['size'] as int? ?? 0;
        _progressController.add(BluetoothReceiveProgress(
            phase: 'transferring',
            fileName: _fileName,
            received: 0,
            total: _total));
        break;

      case 'receiverProgress':
        final received = map['received'] as int? ?? 0;
        _total = map['total'] as int? ?? _total;
        _progressController.add(BluetoothReceiveProgress(
            phase: 'transferring',
            fileName: _fileName,
            received: received,
            total: _total));
        break;

      case 'receiverCompleted':
        final path = map['path'] as String? ?? '';
        _progressController.add(BluetoothReceiveProgress(
            phase: 'completed',
            fileName: _fileName,
            received: _total,
            total: _total));
        if (_completion?.isCompleted == false) _completion!.complete(path);
        break;

      // Connected, announced, and waiting for the person on the other device
      // to pick this one. Not a failure, which is how it used to be reported:
      // there was nothing to start with, and starting was the receiver's job.
      case 'waitingToBeChosen':
        _progressController.add(const BluetoothReceiveProgress(
            phase: 'waiting', fileName: '', received: 0, total: 0));
        break;

      case 'receiverDisconnected':
        _progressController.add(const BluetoothReceiveProgress(
            phase: 'disconnected', fileName: '', received: 0, total: 0));
        break;

      case 'receiverFailed':
        final err = map['error'] as String? ?? 'Unknown error';
        final errCode = map['code'] as String?;
        debugPrint('Bluetooth receive failed: $err (code: $errCode)');
        _progressController.add(BluetoothReceiveProgress(
            phase: 'failed',
            fileName: _fileName,
            received: 0,
            total: _total,
            error: err,
            errorCode: errCode));
        if (_completion?.isCompleted == false) {
          _completion!.completeError(Exception(err));
        }
        break;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _method.invokeMethod('stopAdvertising');
    } catch (_) {}
    try {
      await _method.invokeMethod('cancelTransfer');
    } catch (_) {
      // best effort
    }
    if (_completion?.isCompleted == false) {
      _completion!.completeError(Exception('Cancelled by user'));
    }
  }

  @override
  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    await _devicesController.close();
    await _progressController.close();
    await _linkDirectiveController.close();
    await _serveInfoController.close();
  }
}

/// [BleReceiver] over the universal_ble GATT-central receiver, for Android
/// and Windows. Pure translation: device and progress shapes differ between
/// the two implementations, the contract does not.
class _UniversalBleReceiverAdapter implements BleReceiver {
  final UniversalBleReceiverTransport _inner;

  _UniversalBleReceiverAdapter(this._inner);

  @override
  Stream<BluetoothDevice> get devices => _inner.devices.map((d) =>
      BluetoothDevice(id: d.deviceId, name: d.name ?? 'Unknown device'));

  @override
  Stream<BluetoothReceiveProgress> get progressStream =>
      _inner.progressStream.map((p) => BluetoothReceiveProgress(
          phase: p.phase,
          fileName: p.fileName,
          received: p.received,
          total: p.total));

  @override
  Stream<DirectLinkDirective> get linkDirectives => _inner.linkDirectives;

  @override
  Stream<LinkServeInfo> get serveInfos => _inner.serveInfos;

  @override
  Future<void> startScanning({String? sessionToken, String? publicId}) =>
      _inner.startScanning(sessionToken: sessionToken, publicId: publicId);

  @override
  Future<void> startWaitingAdvertisement({required String deviceName}) =>
      _inner.startWaitingAdvertisement(deviceName: deviceName);

  @override
  Future<void> stopScanning() => _inner.stopScanning();

  @override
  Future<String> connect(String deviceId,
      {String? token, String? targetDir}) async {
    if (token == null || token.isEmpty) {
      // The universal transport writes START:<token> itself, so it has no
      // announce-without-a-session path the native bridge has.
      throw Exception('Missing session token — scan the QR code again.');
    }
    return _inner.connect(deviceId, token: token, targetDir: targetDir);
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

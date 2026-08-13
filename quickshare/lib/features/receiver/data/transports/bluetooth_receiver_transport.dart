import 'dart:async';
import 'dart:io' show Platform;
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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

  const BluetoothReceiveProgress({
    required this.phase,
    required this.fileName,
    required this.received,
    required this.total,
  });
}

/// Receiver side of the native CoreBluetooth transport.
///
/// When [startScanning] receives a session token, the native scanner filters
/// BLE advertisers to the Mac represented by the QR code.
class BluetoothReceiverTransport {
  static const _method = MethodChannel('quickshare/bluetooth');
  static const _events = EventChannel('quickshare/bluetooth/events');

  StreamSubscription? _eventSub;
  final _devicesController = StreamController<BluetoothDevice>.broadcast();
  final _progressController =
      StreamController<BluetoothReceiveProgress>.broadcast();
  Completer<String>? _completion;

  String _fileName = 'received_file';
  int _total = 0;

  Stream<BluetoothDevice> get devices => _devicesController.stream;
  Stream<BluetoothReceiveProgress> get progressStream =>
      _progressController.stream;

  Future<void> startScanning({String? sessionToken}) async {
    _eventSub ??= _events.receiveBroadcastStream().listen(
          _handleEvent,
          onError: (Object e) =>
              debugPrint('Bluetooth receiver event stream error: $e'),
        );
    try {
      await _method.invokeMethod('startScanning', {
        if (sessionToken != null) 'sessionToken': sessionToken,
      });
    } on MissingPluginException {
      throw Exception('Bluetooth is unavailable in this build.');
    }
  }

  Future<void> stopScanning() async {
    try {
      await _method.invokeMethod('stopScanning');
    } catch (_) {
      // best effort
    }
  }

  /// Connects to [deviceId] and resolves with the saved file path once the
  /// transfer completes.
  Future<String> connect(String deviceId) async {
    final completer = Completer<String>();
    _completion = completer;

    final dir = Platform.isIOS
        ? (await getApplicationDocumentsDirectory()).path
        : (await getDownloadsDirectory())?.path ??
            (await getTemporaryDirectory()).path;
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

      case 'receiverFailed':
        final err = map['error'] as String? ?? 'Unknown error';
        debugPrint('Bluetooth receive failed: $err');
        if (_completion?.isCompleted == false)
          _completion!.completeError(Exception(err));
        break;
    }
  }

  Future<void> cancel() async {
    try {
      await _method.invokeMethod('cancelTransfer');
    } catch (_) {
      // best effort
    }
    if (_completion?.isCompleted == false) {
      _completion!.completeError(Exception('Cancelled by user'));
    }
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    await _devicesController.close();
    await _progressController.close();
  }
}

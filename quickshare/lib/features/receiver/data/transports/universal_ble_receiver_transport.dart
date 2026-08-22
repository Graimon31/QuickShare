import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// Progress event emitted by [UniversalBleReceiverTransport].
class UniversalBleReceiveProgress {
  final String phase; // 'scanning' | 'connecting' | 'transferring' | 'completed' | 'failed'
  final String fileName;
  final int received;
  final int total;

  const UniversalBleReceiveProgress({
    required this.phase,
    required this.fileName,
    required this.received,
    required this.total,
  });
}

/// A BLE-central (GATT client) receiver for Android and Windows.
///
/// The sender runs [BluetoothTransferTransport] in peripheral/GATT-server mode
/// with three characteristics:
///
/// | UUID suffix | Role |
/// |-------------|------|
/// | …6B11       | Control — receiver writes `START:<token>` here |
/// | …6B12       | Metadata — sender notifies a JSON blob with name / size / mime / compressed |
/// | …6B13       | Data — sender streams file chunks as GATT notify |
///
/// This class handles the GATT-client side: scanning, connecting, writing the
/// START command, receiving metadata + data chunks, and writing the assembled
/// file to disk.
///
/// On iOS and macOS the native CoreBluetooth bridge is used instead — see
/// [BluetoothReceiverTransport].
class UniversalBleReceiverTransport {
  static const _serviceUuid     = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';
  static const _controlUuid     = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B11';
  static const _metadataUuid    = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B12';
  static const _dataUuid        = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B13';

  final _devicesController =
      StreamController<BleDevice>.broadcast();
  final _progressController =
      StreamController<UniversalBleReceiveProgress>.broadcast();

  Stream<BleDevice> get devices => _devicesController.stream;
  Stream<UniversalBleReceiveProgress> get progressStream =>
      _progressController.stream;

  StreamSubscription<BleDevice>? _scanSub;
  StreamSubscription<dynamic>? _valueSub;
  List<StreamSubscription<dynamic>> _extraSubs = [];

  String? _targetDeviceId;
  String? _sessionToken;
  String _fileName = 'received_file';
  int _totalBytes = 0;
  int _receivedBytes = 0;
  bool _isCompressed = false;

  IOSink? _fileSink;
  String? _targetPath;
  String _baseDir = '';
  bool _metadataReceived = false;

  final _completion = Completer<String>();

  /// Starts BLE scanning and emits discovered devices on [devices].
  ///
  /// If [sessionToken] is provided, only peripherals advertising
  /// `QuickShare-<token-prefix>` will be forwarded via [devices].
  Future<void> startScanning({String? sessionToken}) async {
    _sessionToken = sessionToken;

    await UniversalBle.requestPermissions(withAndroidFineLocation: false);

    _scanSub = UniversalBle.scanStream.listen((device) {
      if (_filterDevice(device)) {
        _devicesController.add(device);
      }
    });

    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [_serviceUuid]),
    );

    AppLogger.info('UniversalBleReceiver: scan started', tag: 'BLE_RECEIVER');
  }

  bool _filterDevice(BleDevice device) {
    if (_sessionToken == null) return true;
    final prefix = _sessionToken!.substring(0, _sessionToken!.length.clamp(0, 8));
    final name = device.name ?? '';
    return name.contains('QuickShare-$prefix') || name.contains('QuickShare');
  }

  Future<void> stopScanning() async {
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }

  /// Connects to [deviceId], sends the START command with [token], and returns
  /// a [Future] that resolves to the saved file path once the transfer is done.
  ///
  /// [targetDir] overrides the default download directory.
  Future<String> connect(
    String deviceId, {
    required String token,
    String? targetDir,
  }) async {
    await stopScanning();

    _targetDeviceId = deviceId;
    _baseDir = targetDir ??
        (await getDownloadsDirectory())?.path ??
        (await getApplicationDocumentsDirectory()).path;

    _emit('connecting');

    try {
      await UniversalBle.connect(deviceId);
      AppLogger.info('UniversalBleReceiver: connected to $deviceId',
          tag: 'BLE_RECEIVER');

      await UniversalBle.discoverServices(deviceId);

      // Subscribe to metadata and data characteristics.
      await UniversalBle.subscribeNotifications(
          deviceId, _serviceUuid, _metadataUuid);
      await UniversalBle.subscribeNotifications(
          deviceId, _serviceUuid, _dataUuid);

      // Use per-characteristic streams — cleaner than the global onValueChange
      // setter which can only hold one handler process-wide.
      _extraSubs
        ..add(
          UniversalBle.characteristicValueStream(deviceId, _metadataUuid)
              .listen(_handleMetadata),
        )
        ..add(
          UniversalBle.characteristicValueStream(deviceId, _dataUuid)
              .listen(_handleData),
        );

      // Send the START command — the sender only starts streaming once it
      // receives this, so we cannot arrive before the notify subscriptions.
      final command = utf8.encode('START:$token');
      await UniversalBle.write(
        deviceId,
        _serviceUuid,
        _controlUuid,
        Uint8List.fromList(command),
        withoutResponse: false,
      );
      AppLogger.info('UniversalBleReceiver: START command sent', tag: 'BLE_RECEIVER');
    } catch (e) {
      if (!_completion.isCompleted) {
        _completion.completeError(e);
      }
      await _cleanup(deviceId);
    }

    return _completion.future;
  }

  void _handleMetadata(Uint8List value) {
    try {
      final json = jsonDecode(utf8.decode(value)) as Map<String, dynamic>;
      _fileName = json['name'] as String? ?? 'received_file';
      _totalBytes = json['size'] as int? ?? 0;
      _isCompressed = (json['compressed'] as bool?) ?? false;
      _metadataReceived = true;
      _receivedBytes = 0;

      final safeName = _sanitize(_fileName);
      _targetPath = _uniquePath(p.join(_baseDir, safeName));
      _fileSink = File(_targetPath!).openWrite();

      AppLogger.info(
          'UniversalBleReceiver: metadata — $_fileName, '
          '$_totalBytes bytes, compressed=$_isCompressed',
          tag: 'BLE_RECEIVER');
      _emit('transferring');
    } catch (e) {
      AppLogger.warning('UniversalBleReceiver: bad metadata chunk: $e',
          tag: 'BLE_RECEIVER');
    }
  }

  void _handleData(Uint8List value) {
    if (!_metadataReceived || _fileSink == null) return;

    try {
      // §8: decompress if the sender said so.
      final bytes = _isCompressed
          ? Uint8List.fromList(GZipDecoder().decodeBytes(value))
          : value;

      _fileSink!.add(bytes);
      _receivedBytes += bytes.length;
      _emit('transferring');

      if (_totalBytes > 0 && _receivedBytes >= _totalBytes) {
        _finalize();
      }
    } catch (e) {
      AppLogger.warning('UniversalBleReceiver: data chunk error: $e',
          tag: 'BLE_RECEIVER');
      if (!_completion.isCompleted) {
        _completion.completeError(e);
      }
    }
  }

  Future<void> _finalize() async {
    await _fileSink?.flush();
    await _fileSink?.close();
    _fileSink = null;
    _emit('completed');
    AppLogger.info(
        'UniversalBleReceiver: file saved to $_targetPath', tag: 'BLE_RECEIVER');
    if (!_completion.isCompleted) {
      _completion.complete(_targetPath ?? '');
    }
    if (_targetDeviceId != null) {
      await _cleanup(_targetDeviceId!);
    }
  }

  String _sanitize(String name) {
    return p
        .basename(name)
        .replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_')
        .trim()
        .let((s) => s.isEmpty ? 'received_file' : s);
  }

  String _uniquePath(String path) {
    var candidate = path;
    var counter = 1;
    while (File(candidate).existsSync()) {
      final ext = p.extension(path);
      final stem = p.basenameWithoutExtension(path);
      candidate = p.join(p.dirname(path), '$stem ($counter)$ext');
      counter++;
    }
    return candidate;
  }

  void _emit(String phase) {
    if (_progressController.isClosed) return;
    _progressController.add(UniversalBleReceiveProgress(
      phase: phase,
      fileName: _fileName,
      received: _receivedBytes,
      total: _totalBytes,
    ));
  }

  Future<void> _cleanup(String deviceId) async {
    for (final sub in _extraSubs) {
      await sub.cancel();
    }
    _extraSubs = [];
    await _valueSub?.cancel();
    _valueSub = null;
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {}
  }

  Future<void> cancel() async {
    await _fileSink?.close();
    _fileSink = null;
    if (_targetPath != null) {
      final partial = File(_targetPath!);
      if (await partial.exists()) await partial.delete();
    }
    if (!_completion.isCompleted) {
      _completion.completeError(Exception('Cancelled by user'));
    }
    if (_targetDeviceId != null) {
      await _cleanup(_targetDeviceId!);
    }
  }

  Future<void> dispose() async {
    await stopScanning();
    await _devicesController.close();
    await _progressController.close();
  }
}

// Dart doesn't have .let(), so add a tiny extension.
extension _LetExt<T> on T {
  R let<R>(R Function(T) block) => block(this);
}

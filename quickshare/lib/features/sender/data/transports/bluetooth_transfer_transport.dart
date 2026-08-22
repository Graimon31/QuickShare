import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, RandomAccessFile;
import 'dart:math' show max;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/utils/mime_compression.dart';
import 'package:quickshare/core/utils/wakelock_guard.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'linux_bluetooth_sender.dart';

/// BLE sender shared by the desktop and mobile builds.
///
/// Apple builds keep using the tested CoreBluetooth bridge in the Runner
/// targets. Android and Windows use universal_ble's GATT peripheral API, but
/// expose the same service, characteristics, START:<token> command, metadata
/// and raw data stream. That means an iPhone or Mac can receive from either
/// of those platforms without a second transfer protocol.
class BluetoothTransferTransport implements TransferTransport {
  static const _method = MethodChannel('quickshare/bluetooth');
  static const _events = EventChannel('quickshare/bluetooth/events');

  static const _serviceUuid =
      'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';
  static const _controlUuid =
      'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B11';
  static const _metadataUuid =
      'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B12';
  static const _dataUuid =
      'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B13';
  static const _cccdUuid =
      '00002902-0000-1000-8000-00805F9B34FB';

  final _progressController = StreamController<double>.broadcast();
  final _statusController = StreamController<TransferStatus>.broadcast();
  final _universalSubscriptions = <StreamSubscription<dynamic>>[];

  StreamSubscription? _nativeEventSub;
  RandomAccessFile? _universalFile;
  LinuxBluetoothSender? _linuxSender;
  String? _universalSessionToken;
  String? _universalClientId;
  bool _universalDataSubscribed = false;
  bool _universalStartReceived = false;
  bool _universalTransferStarted = false;
  int _totalBytes = 0;

  /// §6 — keeps CPU/display awake during the BLE transfer (universal path).
  final _wakelockGuard = WakelockGuard();

  bool get _usesNativeAppleBridge =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  bool get _usesLinuxBridge => defaultTargetPlatform == TargetPlatform.linux;

  @override
  Stream<double> get progressStream => _progressController.stream;

  @override
  Stream<TransferStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _statusController.add(TransferStatus.initial);
    if (_usesNativeAppleBridge) {
      _nativeEventSub = _events.receiveBroadcastStream().listen(
        _handleNativeEvent,
        onError: (Object e) {
          debugPrint('Bluetooth sender event stream error: $e');
          _statusController.add(TransferStatus.failed);
        },
      );
      return;
    }
    if (_usesLinuxBridge) return;

    // universal_ble exposes peripheral callbacks as process-wide handlers;
    // install them once for this sender instance and release the streams in
    // stopSharing().
    _universalSubscriptions.add(
      UniversalBlePeripheral.characteristicSubscriptionStream.listen((event) {
        if (event.characteristicId.toLowerCase() != _dataUuid.toLowerCase() ||
            !event.isSubscribed ||
            _universalSessionToken == null) {
          return;
        }
        _universalClientId = event.deviceId;
        _universalDataSubscribed = true;
        _statusController.add(TransferStatus.connecting);
        unawaited(_maybeStartUniversalTransfer());
      }),
    );

    UniversalBlePeripheral.setWriteRequestHandlers(
      (deviceId, characteristicId, offset, value) {
        if (characteristicId.toLowerCase() == _controlUuid.toLowerCase() &&
            value != null &&
            _universalSessionToken != null) {
          final command = utf8.decode(value, allowMalformed: true);
          final expected = 'START:$_universalSessionToken';
          if (command == 'START' || command == expected) {
            _universalClientId = deviceId;
            _universalStartReceived = true;
            unawaited(_maybeStartUniversalTransfer());
          }
        }
        return PeripheralWriteRequestResult();
      },
    );
  }

  void _handleNativeEvent(dynamic event) {
    final map = Map<String, dynamic>.from(event as Map);
    switch (map['type']) {
      case 'advertisingStarted':
        _statusController.add(TransferStatus.serving);
        break;
      case 'centralConnected':
        _statusController.add(TransferStatus.connecting);
        break;
      case 'senderProgress':
        final sent = map['sent'] as int;
        if (_totalBytes > 0) {
          _progressController.add(sent / _totalBytes);
        }
        break;
      case 'senderCompleted':
        _progressController.add(1.0);
        _statusController.add(TransferStatus.completed);
        break;
      case 'senderFailed':
        debugPrint('Bluetooth send failed: ${map['error']}');
        _statusController.add(TransferStatus.failed);
        break;
    }
  }

  @override
  Future<String> startSharing(FileMetadata file, String token) async {
    _totalBytes = file.size;
    if (_usesNativeAppleBridge) {
      try {
        await _method.invokeMethod('startAdvertising', {
          'filePath': file.path,
          'fileName': file.name,
          'fileSize': file.size,
          'mimeType': file.mimeType,
          'sessionToken': token,
        });
      } on PlatformException catch (e) {
        throw Exception('Failed to start Bluetooth advertising: ${e.message}');
      } on MissingPluginException {
        throw Exception('Bluetooth is unavailable in this platform build.');
      }
      return file.name;
    }

    if (_usesLinuxBridge) {
      _linuxSender = LinuxBluetoothSender();
      await _linuxSender!.start(
        file,
        token,
        onProgress: (sent, total) {
          if (total > 0) _progressController.add(sent / total);
        },
        onStatus: (status, [error]) {
          switch (status) {
            case 'advertising':
              _statusController.add(TransferStatus.serving);
              break;
            case 'connected':
              _statusController.add(TransferStatus.connecting);
              break;
            case 'completed':
              _progressController.add(1.0);
              _statusController.add(TransferStatus.completed);
              break;
            case 'failed':
              debugPrint('Bluetooth Linux sender failed: $error');
              _statusController.add(TransferStatus.failed);
              break;
          }
        },
      );
      return file.name;
    }

    await _startUniversalAdvertising(file, token);
    return file.name;
  }

  Future<void> _startUniversalAdvertising(FileMetadata file, String token) async {
    await UniversalBle.requestPermissions(withAndroidFineLocation: false);
    final capabilities = await UniversalBlePeripheral.getCapabilities();
    if (!capabilities.supportsPeripheralMode) {
      throw Exception('Bluetooth sending is not supported on this platform.');
    }
    final readiness = await UniversalBlePeripheral.getAvailabilityState();
    if (readiness != PeripheralReadinessState.ready) {
      throw Exception('Bluetooth is not ready: ${readiness.name}.');
    }

    _universalSessionToken = token;
    _universalFilePath = file.path;
    _universalFileName = file.name;
    _universalMime = file.mimeType;
    _universalClientId = null;
    _universalDataSubscribed = false;
    _universalStartReceived = false;
    _universalTransferStarted = false;

    final notifyDescriptor = BlePeripheralDescriptor(uuid: _cccdUuid);
    await UniversalBlePeripheral.clearServices();
    await UniversalBlePeripheral.addService(
      BlePeripheralService(
        uuid: _serviceUuid,
        primary: true,
        characteristics: [
          BlePeripheralCharacteristic(
            uuid: _controlUuid,
            properties: [
              CharacteristicProperty.write,
              CharacteristicProperty.writeWithoutResponse,
            ],
            permissions: [PeripheralAttributePermission.writeable],
          ),
          BlePeripheralCharacteristic(
            uuid: _metadataUuid,
            properties: [CharacteristicProperty.notify],
            descriptors: [notifyDescriptor],
            permissions: [PeripheralAttributePermission.readable],
          ),
          BlePeripheralCharacteristic(
            uuid: _dataUuid,
            properties: [CharacteristicProperty.notify],
            descriptors: [BlePeripheralDescriptor(uuid: _cccdUuid)],
            permissions: [PeripheralAttributePermission.readable],
          ),
        ],
      ),
    );

    // Windows GattServiceProvider does not accept a custom local name. The
    // service remains discoverable there; the QR token is verified by the
    // START:<token> command after the connection is established.
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    await UniversalBlePeripheral.startAdvertising(
      services: [_serviceUuid],
      localName: isWindows ? null : 'QuickShare-${token.substring(0, 8)}',
      platformConfig: PeripheralPlatformConfig(
        android: PeripheralAndroidOptions(
          addServicesInScanResponse: false,
          addManufacturerDataInScanResponse: false,
        ),
      ),
    );
    _statusController.add(TransferStatus.serving);
  }

  Future<void> _maybeStartUniversalTransfer() async {
    if (_universalTransferStarted ||
        !_universalDataSubscribed ||
        !_universalStartReceived ||
        _universalClientId == null ||
        _universalSessionToken == null) {
      return;
    }
    _universalTransferStarted = true;

    await _wakelockGuard.acquire(); // §6
    try {
      final path = _universalFilePath;
      if (path == null) throw Exception('No file selected for Bluetooth transfer.');
      _universalFile = await File(path).open();

      // §8: decide whether to compress this payload.
      final compress =
          shouldCompressForTransfer(_universalMime, _universalFileName);

      final metadata = utf8.encode(jsonEncode({
        'name': _universalFileName,
        'size': _totalBytes,
        'mime': _universalMime,
        'compressed': compress, // §8
      }));
      await UniversalBlePeripheral.updateCharacteristicValue(
        characteristicId: _metadataUuid,
        value: Uint8List.fromList(metadata),
        deviceId: _universalClientId,
      );

      final maxNotify = await UniversalBlePeripheral.getMaximumNotifyLength(
        _universalClientId!,
      );
      final chunkSize = max((maxNotify ?? 185) - 3, 20);

      var sent = 0;
      while (sent < _totalBytes) {
        final chunk = await _universalFile!.read(chunkSize);
        if (chunk.isEmpty) break;

        // §8: compress the chunk if applicable.
        final payload = compress
            ? Uint8List.fromList(GZipEncoder().encode(chunk)!)
            : Uint8List.fromList(chunk);

        await UniversalBlePeripheral.updateCharacteristicValue(
          characteristicId: _dataUuid,
          value: payload,
          deviceId: _universalClientId,
        );
        sent += chunk.length;
        _progressController.add(_totalBytes > 0 ? sent / _totalBytes : 1.0);
      }

      if (sent >= _totalBytes) {
        _progressController.add(1.0);
        _statusController.add(TransferStatus.completed);
      } else {
        throw Exception('Bluetooth sender reached end of file unexpectedly.');
      }
    } catch (e) {
      debugPrint('Bluetooth universal sender failed: $e');
      _statusController.add(TransferStatus.failed);
    } finally {
      await _universalFile?.close();
      _universalFile = null;
      await _wakelockGuard.release(); // §6
    }
  }

  String? _universalFilePath;
  String _universalFileName = 'file';
  String _universalMime = 'application/octet-stream';

  @override
  Future<void> stopSharing() async {
    if (_usesNativeAppleBridge) {
      try {
        await _method.invokeMethod('stopAdvertising');
      } catch (_) {
        // best effort
      }
      await _nativeEventSub?.cancel();
      _nativeEventSub = null;
    } else if (_usesLinuxBridge) {
      await _linuxSender?.stop();
      _linuxSender = null;
    } else {
      try {
        await UniversalBlePeripheral.stopAdvertising();
        await UniversalBlePeripheral.clearServices();
      } catch (_) {
        // best effort
      }
      await _universalFile?.close();
      _universalFile = null;
      for (final subscription in _universalSubscriptions) {
        await subscription.cancel();
      }
      _universalSubscriptions.clear();
      UniversalBlePeripheral.setWriteRequestHandlers(null);
      _universalSessionToken = null;
      _universalClientId = null;
      _universalDataSubscribed = false;
      _universalStartReceived = false;
      _universalTransferStarted = false;
      _universalFilePath = null;
    }
    _statusController.add(TransferStatus.cancelled);
  }
}

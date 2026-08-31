import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, RandomAccessFile;
import 'dart:math' show max;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/transfer/ble_control_protocol.dart';
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
///
/// ## More than one file
///
/// A session is a list, not a file. The metadata characteristic is notified
/// once per item — `{name, path, size, mime, compressed, index, count,
/// sessionBytes}` — and the bytes of that item follow on the data
/// characteristic before the next metadata arrives. Notifications on one
/// characteristic are delivered in order over a single ATT connection, so the
/// receiver needs no framing beyond "a new metadata means the previous file
/// is finished".
///
/// `path` is what makes a folder possible here: the relative path each file
/// keeps, root folder included. Before it, this channel could carry exactly
/// one object of a known size, and a folder had to be zipped into one to fit
/// — which is what the recipient then had to unpack.
class BluetoothTransferTransport implements TransferTransport {
  static const _method = MethodChannel('quickshare/bluetooth');
  static const _events = EventChannel('quickshare/bluetooth/events');

  static const _serviceUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';
  static const _controlUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B11';
  static const _metadataUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B12';
  static const _dataUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B13';
  static const _cccdUuid = '00002902-0000-1000-8000-00805F9B34FB';

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

  /// What the receiver said it can take, from its `CAPS:` write.
  ///
  /// Null means it never sent one, which is what every build up to v1.0.10
  /// does — and those finish at the first file and disconnect, so a list must
  /// not be sent to them.
  int? _universalPeerGeneration;

  /// Bytes across the whole session, so progress does not restart per file.
  int _totalBytes = 0;

  /// §6 — keeps CPU/display awake during the BLE transfer (universal path).
  final _wakelockGuard = WakelockGuard();

  /// Why the last failure happened, in words meant for the person sending.
  ///
  /// The status stream can only say "failed", and every reason this transport
  /// has — an unreadable file, a receiver too old for a folder — used to end
  /// up in a debugPrint while the screen said "Bluetooth transfer failed
  /// unexpectedly". Read synchronously by the bloc when the status arrives;
  /// it is always set before the status that follows it.
  String? lastFailureReason;

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
          // Always ahead of START, so it is on record before the decision
          // about what this session may send is taken.
          final generation = BleControlProtocol.parseCapabilities(command);
          if (generation != null) {
            _universalPeerGeneration = generation;
          } else if (BleControlProtocol.isStart(
              command, _universalSessionToken)) {
            _universalClientId = deviceId;
            _universalStartReceived = true;
            unawaited(_maybeStartUniversalTransfer());
          } else if (BleControlProtocol.isUnauthorizedStart(
              command, _universalSessionToken)) {
            // A START without the session token — a receiver too old to pair
            // securely. Say so rather than leaving both sides waiting.
            lastFailureReason = BleControlProtocol.staleReceiverMessage;
            _statusController.add(TransferStatus.failed);
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
        final error = map['error'] as String?;
        debugPrint('Bluetooth send failed: $error');
        lastFailureReason = error;
        _statusController.add(TransferStatus.failed);
        break;
    }
  }

  /// Advertises [files] — or just [file] when a caller has only one.
  ///
  /// [file] still names the session for the screens that show it. The list is
  /// what actually goes out, and it is the whole reason a folder no longer
  /// has to be flattened into an archive to travel over Bluetooth.
  /// Advertises the session over BLE. Not part of [TransferTransport]: this
  /// transport's UX is device discovery, not a shareable code.
  Future<String> startSharing(FileMetadata file, String token,
      {List<FileMetadata>? files}) async {
    final session = (files == null || files.isEmpty) ? [file] : files;
    _totalBytes = session.fold<int>(0, (sum, f) => sum + f.size);
    lastFailureReason = null;
    if (_usesNativeAppleBridge) {
      try {
        await _method.invokeMethod('startAdvertising', {
          // The list the bridge streams. Kept beside the single-file keys
          // below, which every earlier build sent and which still name the
          // session in the bridge's own logs.
          'files': [
            for (final f in session)
              {
                'filePath': f.path,
                'fileName': f.name,
                'relativePath': f.relPath,
                'fileSize': f.size,
                'mimeType': f.mimeType,
              },
          ],
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
        session,
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
              lastFailureReason = error;
              _statusController.add(TransferStatus.failed);
              break;
          }
        },
      );
      return file.name;
    }

    await _startUniversalAdvertising(session, token);
    return file.name;
  }

  Future<void> _startUniversalAdvertising(
      List<FileMetadata> session, String token) async {
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
    _universalFiles = session;
    _universalPeerGeneration = null;
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
      final session = _universalFiles;
      if (session.isEmpty) {
        throw Exception('No file selected for Bluetooth transfer.');
      }
      _refuseListToAnOlderPeer(session, _universalPeerGeneration);

      final maxNotify = await UniversalBlePeripheral.getMaximumNotifyLength(
        _universalClientId!,
      );
      final chunkSize = max((maxNotify ?? 185) - 3, 20);

      // Counted across the session rather than per file: a folder of forty
      // photos should fill one progress ring, not forty.
      var sessionSent = 0;

      for (var index = 0; index < session.length; index++) {
        final item = session[index];
        _universalFile = await File(item.path).open();

        // §8: decide whether to compress this payload. Per file, because a
        // folder holds documents worth deflating next to photos that are
        // already compressed and would only be slowed down by it.
        final compress = shouldCompressForTransfer(item.mimeType, item.name);

        final metadata = utf8.encode(jsonEncode({
          'name': item.name,
          // The relative path this file keeps on the far side. Equal to the
          // name for a file picked directly; `Trip/Day 1/IMG_0042.HEIC` for
          // one inside a folder.
          'path': item.relPath,
          'size': item.size,
          'mime': item.mimeType,
          'compressed': compress, // §8
          // What tells the receiver this is a list and where it is in it. A
          // build that predates them reads a session of one, which is what
          // every session used to be.
          'index': index,
          'count': session.length,
          'sessionBytes': _totalBytes,
        }));
        await UniversalBlePeripheral.updateCharacteristicValue(
          characteristicId: _metadataUuid,
          value: Uint8List.fromList(metadata),
          deviceId: _universalClientId,
        );

        var fileSent = 0;
        try {
          while (fileSent < item.size) {
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
            fileSent += chunk.length;
            sessionSent += chunk.length;
            _progressController
                .add(_totalBytes > 0 ? sessionSent / _totalBytes : 1.0);
          }
        } finally {
          await _universalFile?.close();
          _universalFile = null;
        }

        if (fileSent < item.size) {
          throw Exception(
              'Bluetooth sender reached the end of "${item.name}" with '
              '$fileSent of ${item.size} bytes sent.');
        }
      }

      _progressController.add(1.0);
      _statusController.add(TransferStatus.completed);
    } catch (e) {
      debugPrint('Bluetooth universal sender failed: $e');
      lastFailureReason = e is Exception ? '$e'.replaceFirst('Exception: ', '') : '$e';
      _statusController.add(TransferStatus.failed);
    } finally {
      await _universalFile?.close();
      _universalFile = null;
      await _wakelockGuard.release(); // §6
    }
  }

  /// The session the universal path is serving, in the order it is sent.
  List<FileMetadata> _universalFiles = const [];

  /// Stops a multi-file session from being half-delivered in silence.
  ///
  /// A receiver older than [BleControlProtocol.generation] treats the first
  /// file's last byte as the end of the transfer and disconnects. It shows a
  /// completed transfer, with one file in it, and no indication that a folder
  /// was ever sent — which is worse than any error, because nobody goes
  /// looking for what is missing.
  static void _refuseListToAnOlderPeer(
      List<FileMetadata> session, int? peerGeneration) {
    if (BleControlProtocol.peerCanTakeSession(
        fileCount: session.length, peerGeneration: peerGeneration)) {
      return;
    }
    throw Exception(BleControlProtocol.sessionRefusedMessage);
  }

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
      _universalFiles = const [];
      _universalPeerGeneration = null;
    }
    _statusController.add(TransferStatus.cancelled);
  }
}

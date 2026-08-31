import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Progress event emitted by [UniversalBleReceiverTransport].
class UniversalBleReceiveProgress {
  final String
      phase; // 'scanning' | 'connecting' | 'transferring' | 'completed' | 'failed'
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
/// | …6B12       | Metadata — sender notifies a JSON blob per file |
/// | …6B13       | Data — sender streams file chunks as GATT notify |
///
/// This class handles the GATT-client side: scanning, connecting, writing the
/// START command, receiving metadata + data chunks, and writing the assembled
/// files to disk.
///
/// ## A session is a list
///
/// One metadata notification per file — `{name, path, size, mime, compressed,
/// index, count, sessionBytes}` — followed by that file's bytes. A new
/// metadata means the previous file is finished; the session is finished when
/// the last index announced has all its bytes. Notifications on a single
/// characteristic arrive in order over one ATT connection, so nothing more is
/// needed to tell the files apart.
///
/// `path` carries the folder structure: files land under the directories they
/// came from rather than in one flat heap, which is what lets a folder cross
/// this channel without being zipped into a single object first. A sender on
/// an older build sends neither `path` nor `count`, which reads exactly as it
/// should — one file, at the root.
///
/// On iOS and macOS the native CoreBluetooth bridge is used instead — see
/// [BluetoothReceiverTransport].
class UniversalBleReceiverTransport {
  static const _serviceUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';
  static const _controlUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B11';
  static const _metadataUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B12';
  static const _dataUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B13';

  final _devicesController = StreamController<BleDevice>.broadcast();
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

  /// The current file's handle and where its bytes land before the rename.
  ///
  /// BLE has no manifest and its notify handlers are not awaited, so the write
  /// is kept synchronous — a data frame can arrive the instant after the
  /// metadata one, with no chance to await an open in between. Each file still
  /// goes through its own `.qs.partial` and an fsync + atomic rename on close;
  /// what BLE does not do is stage a whole folder, since the common root is
  /// not known until the files have all arrived.
  RandomAccessFile? _raf;
  String? _targetPath;
  String? _partialPath;
  String _baseDir = '';
  bool _metadataReceived = false;

  /// Bytes for the file currently open, and how many of them have landed.
  int _fileTotalBytes = 0;
  int _fileReceivedBytes = 0;

  /// Where the session is in its list of files.
  int _itemIndex = 0;
  int _itemCount = 1;

  /// Everything written so far, in arrival order.
  final List<String> _writtenPaths = [];

  List<String> get receivedPaths => List.unmodifiable(_writtenPaths);

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
    final prefix =
        _sessionToken!.substring(0, _sessionToken!.length.clamp(0, 8));
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
    if (token.isEmpty) {
      // The sender no longer accepts a START without the session token, so a
      // connect without one cannot go anywhere — fail here with something the
      // user can act on rather than time out against a silent peer.
      throw Exception('Missing session token — scan the QR code again.');
    }
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

      // Say what this build can take, before START rather than after: a
      // sender that reaches START without having seen this knows the far side
      // is old and refuses to half-deliver a folder to it.
      //
      // Best-effort on purpose. Senders up to v1.0.10 answer this write with
      // an ATT error, which is not a failed connection — it is an older
      // sender behaving exactly as it always did, and the transfer that
      // follows is a perfectly good one-file transfer.
      try {
        await UniversalBle.write(
          deviceId,
          _serviceUuid,
          _controlUuid,
          Uint8List.fromList(utf8.encode(BleControlProtocol.capabilities())),
          // With a response, not without: a write that can be silently
          // dropped would make a current sender believe the receiver is old
          // and refuse a folder it could perfectly well have taken. An older
          // sender's error is caught below; a lost write could not be.
          withoutResponse: false,
        );
      } catch (e) {
        AppLogger.info(
            'UniversalBleReceiver: sender did not take the CAPS write ($e) — '
            'it is on an older build',
            tag: 'BLE_RECEIVER');
      }

      // Send the START command — the sender only starts streaming once it
      // receives this, so we cannot arrive before the notify subscriptions.
      final command = utf8.encode(BleControlProtocol.start(token));
      await UniversalBle.write(
        deviceId,
        _serviceUuid,
        _controlUuid,
        Uint8List.fromList(command),
        withoutResponse: false,
      );
      AppLogger.info('UniversalBleReceiver: START command sent',
          tag: 'BLE_RECEIVER');
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
      // Whatever was open belongs to the previous file: a metadata frame is
      // the only end-of-file marker this channel has.
      unawaited(_sealCurrentFile());

      _fileName = json['name'] as String? ?? 'received_file';
      _fileTotalBytes = json['size'] as int? ?? 0;
      _isCompressed = (json['compressed'] as bool?) ?? false;
      _itemIndex = json['index'] as int? ?? 0;
      // A sender that says nothing is a sender with one file — which is what
      // every build before folders could carry.
      _itemCount = json['count'] as int? ?? 1;
      _metadataReceived = true;
      _fileReceivedBytes = 0;

      if (_itemIndex <= 0) {
        _receivedBytes = 0;
        _writtenPaths.clear();
        _totalBytes = json['sessionBytes'] as int? ?? _fileTotalBytes;
      }

      final relative = json['path'] as String? ?? _fileName;
      _targetPath = _uniquePath(_resolveTargetPath(relative));
      _partialPath = '${_targetPath!}$kPartialSuffix';
      // The folder this file came from has to exist before it can be written
      // into. Created as the files arrive rather than up front: a session may
      // announce thousands, and one that fails leaves no empty shells behind.
      Directory(p.dirname(_targetPath!)).createSync(recursive: true);
      _raf = File(_partialPath!).openSync(mode: FileMode.writeOnly);

      AppLogger.info(
          'UniversalBleReceiver: metadata — $relative, '
          '$_fileTotalBytes bytes, compressed=$_isCompressed, '
          'item ${_itemIndex + 1} of $_itemCount',
          tag: 'BLE_RECEIVER');
      _emit('transferring');
    } catch (e) {
      AppLogger.warning('UniversalBleReceiver: bad metadata chunk: $e',
          tag: 'BLE_RECEIVER');
    }
  }

  void _handleData(Uint8List value) {
    if (!_metadataReceived || _raf == null) return;

    try {
      // §8: decompress if the sender said so.
      final bytes = _isCompressed
          ? Uint8List.fromList(GZipDecoder().decodeBytes(value))
          : value;

      _raf!.writeFromSync(bytes);
      _fileReceivedBytes += bytes.length;
      _receivedBytes += bytes.length;
      _emit('transferring');

      if (_fileTotalBytes > 0 && _fileReceivedBytes >= _fileTotalBytes) {
        // The last file the sender announced, with all of its bytes in: that
        // is the session, and nothing more is coming.
        if (_itemIndex >= _itemCount - 1) {
          unawaited(_finalize());
        } else {
          unawaited(_sealCurrentFile());
        }
      }
    } catch (e) {
      AppLogger.warning('UniversalBleReceiver: data chunk error: $e',
          tag: 'BLE_RECEIVER');
      if (!_completion.isCompleted) {
        _completion.completeError(e);
      }
    }
  }

  /// fsyncs, closes and atomically renames whatever file is open, recording it
  /// exactly once.
  ///
  /// The handle and its paths are taken before the first await on purpose. The
  /// caller opens the next file immediately after — that is what a metadata
  /// frame means — so reading `_targetPath` after would file every finished
  /// item under the name of the one that came next.
  Future<void> _sealCurrentFile() async {
    final raf = _raf;
    final partial = _partialPath;
    final finalPath = _targetPath;
    _raf = null;
    _partialPath = null;
    if (raf == null || partial == null || finalPath == null) return;
    if (!_writtenPaths.contains(finalPath)) _writtenPaths.add(finalPath);
    try {
      raf.flushSync(); // fsync the bytes onto the device
      raf.closeSync();
      File(partial).renameSync(finalPath);
      await syncDirectory(p.dirname(finalPath));
    } catch (e) {
      AppLogger.warning('UniversalBleReceiver: could not seal $finalPath: $e',
          tag: 'BLE_RECEIVER');
    }
  }

  Future<void> _finalize() async {
    await _sealCurrentFile();
    _emit('completed');
    AppLogger.info(
        'UniversalBleReceiver: ${_writtenPaths.length} file(s) saved under '
        '$_baseDir',
        tag: 'BLE_RECEIVER');
    if (!_completion.isCompleted) {
      _completion.complete(
          _writtenPaths.isNotEmpty ? _writtenPaths.first : (_targetPath ?? ''));
    }
    if (_targetDeviceId != null) {
      await _cleanup(_targetDeviceId!);
    }
  }

  /// Where a file announced as [relative] is written, under [_baseDir].
  ///
  /// Every segment came off the wire, so every segment is cleaned the way a
  /// flat filename is, and `.`/`..` are dropped rather than resolved — a
  /// sender cannot climb out of the destination by naming its way out. The
  /// containment check afterwards is deliberate belt and braces.
  String _resolveTargetPath(String relative) {
    final segments = relative
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .map(_sanitize)
        .toList();
    final resolved = p.normalize(
        p.join(_baseDir, segments.isEmpty ? 'received_file' : p.joinAll(segments)));
    if (!p.isWithin(_baseDir, resolved)) {
      throw Exception('Path traversal detected in "$relative"');
    }
    return resolved;
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
    try {
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
    // A cancelled transfer leaves no debris: the in-flight partial and any
    // final name it might already carry both go.
    for (final path in [_partialPath, _targetPath]) {
      if (path == null) continue;
      final f = File(path);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    _partialPath = null;
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

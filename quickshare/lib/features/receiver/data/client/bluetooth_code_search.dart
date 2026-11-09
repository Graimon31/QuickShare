import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/transfer/ble_code_pairing.dart';
import 'package:quickshare/core/transfer/ble_frame.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'code_search.dart';
import 'code_session_resolver.dart';

void _ignore(Future<void> future) {
  unawaited(future.catchError((Object _) {}));
}

/// A short-lived connection used to prove a typed code, before START is ever
/// written. The regular Bluetooth receiver handles the resulting offer.
abstract interface class BleCodeRadio {
  Stream<String> get devices;
  Stream<Map<String, dynamic>> get frames;
  Future<void> scan();
  Future<void> stopScan();
  Future<void> connect(String device);
  Future<void> write(String command);
  Future<void> disconnect();
  Future<void> dispose();
}

class BluetoothCodeSearch {
  BluetoothCodeSearch({
    BleCodeRadio Function()? radio,
    this.discoveryWindow = const Duration(seconds: 4),
    this.attemptWindow = const Duration(seconds: 8),
    this.searchWindow = const Duration(seconds: 25),
    this.cleanupWindow = const Duration(seconds: 2),
  }) : _radio = radio ?? _newRadio;

  final BleCodeRadio Function() _radio;
  final Duration discoveryWindow;
  final Duration attemptWindow;
  final Duration searchWindow;
  final Duration cleanupWindow;

  static BleCodeRadio _newRadio() =>
      defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.macOS
          ? _NativeCodeRadio()
          : _UniversalCodeRadio();

  Future<CodeSessionOutcome> run(SessionCode code,
      {required SearchGate gate}) async {
    final radio = _radio();
    final candidates = <String>{};
    final subscription = radio.devices.listen(candidates.add);
    // An independent deadline also releases a plugin call that never answers.
    final deadline = Completer<void>();
    final timer = Timer(searchWindow, deadline.complete);
    bool stopped = false;
    bool connectionOpen = false;
    Future<void>? closing;
    Future<void> closeConnection() => closing ??= connectionOpen
        ? Future<void>.sync(radio.disconnect)
        : Future<void>.value();
    final stop = Future.any([gate.stopped, deadline.future]).then((_) {
      stopped = true;
    });
    try {
      Future<CodeSessionOutcome> search() async {
        await radio.scan();
        await Future.any([Future<void>.delayed(discoveryWindow), stop]);
        await radio.stopScan();
        for (final device in candidates.take(12)) {
          if (stopped || gate.isStopped) break;
          String? payload;
          try {
            connectionOpen = true;
            payload = await _ask(radio, device, code, stop);
          } catch (_) {
            // An unrelated sender, an older build or a lost radio connection.
          }
          if (stopped || gate.isStopped) break;
          if (payload != null && gate.tryClaim()) {
            return CodeSessionFoundBluetooth(payload);
          }
          try {
            // Do not reuse a radio whose previous connection cannot be torn
            // down: late operations could otherwise interfere with the next.
            await Future.any([closeConnection(), stop]).timeout(attemptWindow);
            if (!stopped && !gate.isStopped) {
              connectionOpen = false;
              closing = null;
            }
          } catch (_) {
            break;
          }
        }
        return const CodeSessionNotFound();
      }

      return await Future.any([
        search(),
        stop.then<CodeSessionOutcome>((_) => const CodeSessionNotFound()),
      ]);
    } catch (_) {
      // Bluetooth off/denied/unsupported must leave LAN and internet usable.
      return const CodeSessionNotFound();
    } finally {
      stopped = true;
      timer.cancel();
      // Finish the old connection before handing its radio to a new receiver,
      // while keeping a stuck plugin from holding the result indefinitely.
      final watch = Stopwatch()..start();
      final cancelled = subscription.cancel().catchError((Object _) {});
      final disconnect = closeConnection();
      try {
        await disconnect.timeout(cleanupWindow);
      } catch (_) {}
      final disposal = Future<void>.sync(radio.dispose);
      final remaining = cleanupWindow - watch.elapsed;
      final cleanup = Future.wait<void>([cancelled, disposal]);
      if (remaining > Duration.zero) {
        try {
          await cleanup.timeout(remaining);
        } catch (_) {}
      } else {
        _ignore(cleanup.then<void>((_) {}));
      }
    }
  }

  Future<String?> _ask(BleCodeRadio radio, String device, SessionCode code,
      Future<void> stop) async {
    final id = BleCodePairing.newId();
    final reply = Completer<Map<String, dynamic>>();
    final sealed = Completer<Map<String, dynamic>>();
    final subscription = radio.frames.listen((frame) {
      if (frame['id'] != id) return;
      if (frame['pB'] != null && !reply.isCompleted) reply.complete(frame);
      if (frame['sealed'] != null && !sealed.isCompleted) {
        sealed.complete(frame);
      }
    });
    bool active = true;
    void checkActive() {
      if (!active) throw StateError('Pairing stopped');
    }

    Future<String?> exchange() async {
      await radio.connect(device);
      checkActive();
      final begun = await BleCodePairing.begin(code);
      checkActive();
      await radio.write(BleCodePairing.command(
          {'id': id, 'pA': CodePake.encode(begun.share)}));
      final response = await reply.future;
      checkActive();
      final pB = CodePake.decode(response['pB'], length: Spake2.shareLength);
      final cB = CodePake.decode(response['cB'], length: CodePake.tagLength);
      if (pB == null || cB == null) return null;
      final keys = await BleCodePairing.complete(begun, pB, id);
      checkActive();
      if (!keys.verifies(Spake2Role.b, cB)) return null;
      await radio.write(BleCodePairing.command(
          {'id': id, 'cA': CodePake.encode(keys.confirmationA)}));
      final envelope = await sealed.future;
      checkActive();
      return BleCodePairing.open(keys, id, envelope['sealed']);
    }

    try {
      return await Future.any([
        exchange(),
        stop.then<String?>((_) => null),
      ]).timeout(attemptWindow);
    } finally {
      active = false;
      _ignore(subscription.cancel());
    }
  }
}

class _NativeCodeRadio implements BleCodeRadio {
  static const _method = MethodChannel('quickshare/bluetooth');
  static const _events = EventChannel('quickshare/bluetooth/events');
  final _devices = StreamController<String>.broadcast();
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _ready;
  String? _readyDevice;
  bool _disposed = false;

  @override
  Stream<String> get devices => _devices.stream;
  @override
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  @override
  Future<void> scan() async {
    _subscription = _events.receiveBroadcastStream().listen((event) {
      if (_disposed || event is! Map) return;
      switch (event['type']) {
        case 'deviceDiscovered':
          if (event['id'] case final String id) _devices.add(id);
        case 'pairingReady':
          if (event['deviceId'] == _readyDevice &&
              _ready?.isCompleted == false) {
            _ready!.complete();
          }
        case 'pairingFrame':
          if (event['deviceId'] != _readyDevice || _readyDevice == null) break;
          if (event['pair'] case final Map frame) {
            _frames.add(Map<String, dynamic>.from(frame));
          }
        case 'receiverFailed':
          if (event['deviceId'] != null && event['deviceId'] != _readyDevice) {
            break;
          }
          if (_ready?.isCompleted == false) {
            _ready!.completeError(StateError('Bluetooth pairing failed'));
          }
      }
    });
    await _method.invokeMethod('startScanning', {'pairingOnly': true});
    if (_disposed) await stopScan();
  }

  @override
  Future<void> stopScan() async {
    try {
      await _method.invokeMethod('stopScanning');
    } catch (_) {}
  }

  @override
  Future<void> connect(String device) async {
    if (_disposed) throw StateError('Pairing stopped');
    final ready = _ready = Completer<void>();
    _readyDevice = device;
    // Install the error listener before starting the native operation.
    final waiting = ready.future;
    unawaited(waiting.then<void>((_) {}, onError: (Object _) {}));
    await _method.invokeMethod('connect', {'deviceId': device});
    await waiting;
  }

  @override
  Future<void> write(String command) async {
    if (_disposed) throw StateError('Pairing stopped');
    await _method.invokeMethod('sendPairingCommand', {'command': command});
  }

  @override
  Future<void> disconnect() async {
    if (_readyDevice == null) return;
    if (_ready?.isCompleted == false) {
      _ready!.completeError(StateError('Pairing stopped'));
    }
    _ready = null;
    _readyDevice = null;
    try {
      await _method.invokeMethod('disconnectPairing');
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await Future.wait<void>([
      if (_subscription != null) _subscription!.cancel(),
      stopScan(),
      disconnect(),
      _devices.close(),
      _frames.close(),
    ]);
  }
}

class _UniversalCodeRadio implements BleCodeRadio {
  final _devices = StreamController<String>.broadcast();
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _scan;
  StreamSubscription<dynamic>? _values;
  late final BleFrameAssembler _assembler = BleFrameAssembler(
      onFrame: (bytes) {
        if (_disposed) return;
        try {
          final json = jsonDecode(utf8.decode(bytes));
          if (json is Map && json['pair'] is Map) {
            _frames.add(Map<String, dynamic>.from(json['pair'] as Map));
          }
        } catch (_) {}
      },
      onFault: (_) {});
  final _splitter = BleFrameSplitter();
  String? _device;
  bool _disposed = false;
  int _generation = 0;

  @override
  Stream<String> get devices => _devices.stream;
  @override
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  @override
  Future<void> scan() async {
    await UniversalBle.requestPermissions(withAndroidFineLocation: false);
    if (_disposed) return;
    _scan = UniversalBle.scanStream.listen((device) {
      if (!_disposed) _devices.add(device.deviceId);
    });
    await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [BleGatt.service]));
    if (_disposed) await stopScan();
  }

  @override
  Future<void> stopScan() async {
    await _scan?.cancel();
    _scan = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }

  @override
  Future<void> connect(String device) async {
    if (_disposed) throw StateError('Pairing stopped');
    _device = device;
    final generation = ++_generation;
    void checkActive() {
      if (_disposed || _generation != generation) {
        throw StateError('Pairing stopped');
      }
    }

    _assembler.reset();
    await UniversalBle.connect(device);
    if (_disposed || (_generation != generation && _device != device)) {
      // A timed-out connect can succeed after its earlier disconnect ran.
      _ignore(UniversalBle.disconnect(device));
    }
    checkActive();
    try {
      await UniversalBle.requestMtu(device, 247,
          timeout: const Duration(seconds: 2));
    } catch (_) {}
    checkActive();
    await UniversalBle.discoverServices(device);
    checkActive();
    _values = UniversalBle.characteristicValueStream(device, BleGatt.metadata)
        .listen(_assembler.add);
    await UniversalBle.subscribeNotifications(
        device, BleGatt.service, BleGatt.metadata);
    checkActive();
    // The existing native sender's write queue requires both subscriptions.
    await UniversalBle.subscribeNotifications(
        device, BleGatt.service, BleGatt.data);
    checkActive();
  }

  @override
  Future<void> write(String command) async {
    final device = _device;
    final generation = _generation;
    if (_disposed || device == null) throw StateError('Pairing stopped');
    final parts = _splitter.split(Uint8List.fromList(utf8.encode(command)),
        notificationBytes: BleFrame.defaultNotificationBytes);
    for (final part in parts) {
      if (_disposed || _generation != generation) {
        throw StateError('Pairing stopped');
      }
      await UniversalBle.write(device, BleGatt.service, BleGatt.control, part,
          withoutResponse: false);
    }
  }

  @override
  Future<void> disconnect() async {
    final device = _device;
    _device = null;
    _generation++;
    final cancel = _values?.cancel();
    _values = null;
    _assembler.reset();
    final close =
        device == null ? Future<void>.value() : UniversalBle.disconnect(device);
    try {
      await Future.wait<void>([if (cancel != null) cancel, close]);
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final stop = stopScan();
    final close = disconnect();
    _assembler.dispose();
    await Future.wait<void>([stop, close, _devices.close(), _frames.close()]);
  }
}

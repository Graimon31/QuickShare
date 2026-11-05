import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_frame.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'ble_receiver_failure.dart';

/// A BLE-central (GATT client) receiver for Android and Windows.
///
/// The sender runs `BluetoothTransferTransport` in peripheral/GATT-server mode
/// with three characteristics ([BleGatt]):
///
/// | UUID suffix | Role |
/// |-------------|------|
/// | …6B11       | Control — receiver writes CAPS, KEX, AP and `START:<token>` |
/// | …6B12       | Metadata — sender notifies the `link` and `serve` frames |
/// | …6B13       | Data — subscribed to, and nothing ever arrives on it |
///
/// This class handles the GATT-client side: scanning, connecting, subscribing,
/// writing the rendezvous commands, and handing the frames it hears to the
/// `DirectLinkCoordinator`. **No file crosses this channel.** Since protocol
/// generation 4 the bytes cross a Wi-Fi link the two devices raise between
/// them, over QHTP; a sender that still tries to push them over Bluetooth is
/// an older build, and is refused with the update it needs rather than
/// received from (see [failures]).
///
/// On iOS and macOS the native CoreBluetooth bridge is used instead — see
/// `BluetoothReceiverTransport`.
class UniversalBleReceiverTransport {
  /// [frameTimeout] is how long a frame that has begun may take to finish; see
  /// [BleFrame.assemblyTimeout]. Shorter in a test that has to wait it out.
  UniversalBleReceiverTransport({
    Duration frameTimeout = BleFrame.assemblyTimeout,
  }) {
    _frames = BleFrameAssembler(
      onFrame: _handleFrame,
      onFault: _handleFrameFault,
      timeout: frameTimeout,
    );
  }

  late final BleFrameAssembler _frames;

  final _devicesController = StreamController<BleDevice>.broadcast();

  Stream<BleDevice> get devices => _devicesController.stream;

  /// Who raises the direct Wi-Fi link and how to reach it — the sender's
  /// `{"link": …}` frames, decoded for the coordinator.
  final _linkDirectiveController =
      StreamController<DirectLinkDirective>.broadcast();

  /// Where the file is served once the link is up — the sender's
  /// `{"serve": …}` frames, decoded.
  final _serveInfoController = StreamController<LinkServeInfo>.broadcast();

  /// What went wrong after connecting: the sender is a build that sends files
  /// over Bluetooth, a frame arrived that cannot be read, or the connection
  /// dropped. The session decides which of those still matter — after the
  /// serve frame the radio is not needed any more.
  final _failureController = StreamController<BleReceiverFailure>.broadcast();

  Stream<DirectLinkDirective> get linkDirectives =>
      _linkDirectiveController.stream;

  Stream<LinkServeInfo> get serveInfos => _serveInfoController.stream;

  Stream<BleReceiverFailure> get failures => _failureController.stream;

  /// Tells the sender about a network this receiver raised: an `AP:` write
  /// on its control characteristic, carrying the sealed credentials.
  Future<void> sendApOffer(String sealed) async {
    await _writeControl(BleControlProtocol.apOffer(sealed));
  }

  /// Hands the sender this side's public half for the negotiation.
  Future<void> sendKeyExchange(String publicKey) async {
    await _writeControl(BleControlProtocol.keyExchange(publicKey));
  }

  Future<void> _writeControl(String command) async {
    final deviceId = _targetDeviceId;
    if (deviceId == null) {
      throw StateError('control write before connect — no sender to answer.');
    }
    await UniversalBle.write(
      deviceId,
      BleGatt.service,
      BleGatt.control,
      Uint8List.fromList(utf8.encode(command)),
      // With a response, for the same reason CAPS is: a silently dropped
      // write is a session that never finds its network.
      withoutResponse: false,
    );
  }

  StreamSubscription<BleDevice>? _scanSub;
  List<StreamSubscription<dynamic>> _subs = [];

  String? _targetDeviceId;
  String? _sessionToken;

  /// The session's locator, which is what an Apple or Linux sender advertises.
  /// Android and Windows senders advertise none; see
  /// [BleAdvertisement.accepts].
  String? _locator;
  bool _cancelled = false;
  bool _failedReported = false;

  /// Starts BLE scanning and emits discovered devices on [devices].
  ///
  /// The scan is filtered to [BleGatt.service], so every device that arrives
  /// is a DirectDrop sender. Among those, one that advertises a `QuickShare-`
  /// name has to carry this session's locator; one that advertises none is
  /// accepted, because the Windows and Android senders cannot (see
  /// [BleAdvertisement.accepts]).
  Future<void> startScanning({String? sessionToken, String? locator}) async {
    _sessionToken = sessionToken;
    _locator = locator;

    await UniversalBle.requestPermissions(withAndroidFineLocation: false);

    _scanSub = UniversalBle.scanStream.listen((device) {
      if (BleAdvertisement.accepts(
        advertisedName: device.name,
        locator: _locator,
        sessionToken: _sessionToken,
      )) {
        _devicesController.add(device);
      }
    });

    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [BleGatt.service]),
    );

    AppLogger.info('UniversalBleReceiver: scan started', tag: 'BLE_RECEIVER');
  }

  Future<void> stopScanning() async {
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }

  /// Connects to [deviceId] and does the receiver's half of the handshake:
  /// subscribes to the metadata and data characteristics, says what this build
  /// can take (CAPS), and sends `START:<token>`. Completes when START has been
  /// written — from then on the sender may begin the rendezvous, and the
  /// frames it sends arrive on [linkDirectives] and [serveInfos].
  ///
  /// Throws when the device cannot be connected to or does not offer the
  /// service; a problem after that is reported on [failures].
  Future<void> connect(String deviceId, {required String token}) async {
    if (token.isEmpty) {
      // The sender no longer accepts a START without the session token, so a
      // connect without one cannot go anywhere — fail here with something the
      // user can act on rather than time out against a silent peer.
      throw Exception('Missing session token — scan the QR code again.');
    }
    await stopScanning();

    _targetDeviceId = deviceId;
    _cancelled = false;
    _failedReported = false;
    _frames.reset();

    try {
      await UniversalBle.connect(deviceId);
      AppLogger.info('UniversalBleReceiver: connected to $deviceId',
          tag: 'BLE_RECEIVER');

      // Android before 14 starts at the 23-byte default ATT MTU, which holds
      // 20 bytes of a frame that is two hundred. Asked for, not insisted on:
      // Windows negotiates its own, and a platform that refuses is no reason
      // not to try.
      try {
        final mtu = await UniversalBle.requestMtu(deviceId, 247,
            timeout: const Duration(seconds: 3));
        AppLogger.info('UniversalBleReceiver: MTU is $mtu', tag: 'BLE_RECEIVER');
      } catch (e) {
        AppLogger.info('UniversalBleReceiver: MTU request not taken ($e)',
            tag: 'BLE_RECEIVER');
      }

      _subs
        ..add(UniversalBle.connectionStream(deviceId).listen((connected) {
          if (!connected && !_cancelled) {
            _fail('The connection to the sending device dropped.',
                FailureCode.linkPeerLost);
          }
        }))
        // Per-characteristic streams — cleaner than the global onValueChange
        // setter, which holds one handler process-wide.
        ..add(UniversalBle.characteristicValueStream(deviceId, BleGatt.metadata)
            .listen(_handleMetadata))
        ..add(UniversalBle.characteristicValueStream(deviceId, BleGatt.data)
            .listen(_refuseBytesOnData));

      await UniversalBle.discoverServices(deviceId);

      // Subscribe to metadata and data. The sender treats the data
      // subscription as "this receiver is fully connected", so it has to be
      // there even though nothing is ever sent on it.
      await UniversalBle.subscribeNotifications(
          deviceId, BleGatt.service, BleGatt.metadata);
      await UniversalBle.subscribeNotifications(
          deviceId, BleGatt.service, BleGatt.data);

      // Say what this build can take, before START rather than after: a
      // sender that reaches START without having seen this knows the far side
      // is old and refuses it with the update it needs.
      //
      // With a response, not without: a write that can be silently dropped
      // would make a current sender believe the receiver is old. An older
      // sender's error is caught below; a lost write could not be.
      try {
        await UniversalBle.write(
          deviceId,
          BleGatt.service,
          BleGatt.control,
          Uint8List.fromList(utf8.encode(BleControlProtocol.capabilities())),
          withoutResponse: false,
        );
      } catch (e) {
        AppLogger.info(
            'UniversalBleReceiver: sender did not take the CAPS write ($e) — '
            'it is on an older build',
            tag: 'BLE_RECEIVER');
      }

      // The sender only begins once it receives this, so it cannot arrive
      // before the notify subscriptions.
      await _writeControl(BleControlProtocol.start(token));
      AppLogger.info('UniversalBleReceiver: START command sent',
          tag: 'BLE_RECEIVER');
    } catch (e) {
      await _release(deviceId);
      rethrow;
    }
  }

  /// The metadata characteristic carries the rendezvous' frames and nothing
  /// else, each cut into parts that fit a notification (see [BleFrame]). Every
  /// notification goes to the assembler, which hands back whole frames and
  /// says what is wrong with anything that is not part of one.
  void _handleMetadata(Uint8List value) {
    if (_cancelled || _failedReported) return;
    _frames.add(value);
  }

  /// A whole frame. A generation-5 sender's are `{"link": …}` and
  /// `{"serve": …}`; a valid-looking frame that is neither is not one this
  /// build can act on.
  void _handleFrame(Uint8List frame) {
    if (_cancelled || _failedReported) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(frame));
    } catch (_) {
      _failDamaged(
          'A frame of ${frame.length} bytes arrived complete but is not '
          'JSON.');
      return;
    }
    AppLogger.info(
        'UniversalBleReceiver: a ${frame.length}-byte frame is whole '
        '(${decoded is Map ? decoded.keys.join(', ') : 'not an object'})',
        tag: 'BLE_RECEIVER');
    if (decoded is Map<String, dynamic>) {
      final link = decoded['link'];
      if (link is Map<String, dynamic>) {
        // A sender of generation 4 or below, still putting the code's digits
        // in the frame. Refused here, at the first frame, with the update it
        // needs: nothing it seals would open, and the negotiation would only
        // say so after running out its whole budget.
        if (DirectLinkDirective.fromOlderGeneration(link)) {
          _failSenderTooOld();
          return;
        }
        final directive = DirectLinkDirective.fromJson(link);
        if (directive != null) _linkDirectiveController.add(directive);
        return;
      }
      final serve = decoded['serve'];
      if (serve is Map<String, dynamic>) {
        final info = LinkServeInfo.fromJson(serve);
        if (info == null) {
          // The last frame of the rendezvous, with nothing after it to carry on
          // without: dropping it would leave the screen waiting for an address
          // that was never going to arrive.
          _failDamaged('The serve frame is missing what a receiver needs to '
              'pull the file.');
          return;
        }
        _serveInfoController.add(info);
        return;
      }
    }
    _failDamaged('A frame of ${frame.length} bytes arrived complete but is '
        'neither a link nor a serve frame.');
  }

  void _handleFrameFault(BleFrameException fault) {
    if (_cancelled || _failedReported) return;
    // "An older version" is said when the sender's frames are not cut into
    // parts at all, which only a build from before the parts did. A part
    // missing, repeated, foreign or late is a connection having a bad time (or
    // somebody else's write), and the update would not help.
    if (fault.isOlderSender) {
      _failSenderTooOld();
      return;
    }
    _failDamaged(fault.message);
  }

  /// A frame that could not be put together or read, which is not the sender's
  /// version: the person is told the transfer stopped, and the log says why.
  void _failDamaged(String why) => _fail(
        '${BleFrame.damagedMessage} $why',
        FailureCode.bluetoothTransferFailed,
      );

  /// Nothing is sent on the data characteristic any more. Bytes arriving on it
  /// are a sender that is still pushing a file over Bluetooth, which this
  /// build does not receive — and does not quietly write to disk either.
  void _refuseBytesOnData(Uint8List value) {
    if (_cancelled || value.isEmpty) return;
    _failSenderTooOld();
  }

  void _failSenderTooOld() => _fail(
        BleControlProtocol.senderTooOldMessage,
        FailureCode.senderTooOldForDirectLink,
      );

  void _fail(String message, String code) {
    // Once is enough: a stale sender's file is thousands of notifications.
    if (_failedReported) return;
    _failedReported = true;
    AppLogger.warning('UniversalBleReceiver: $message', tag: 'BLE_RECEIVER');
    if (!_failureController.isClosed) {
      _failureController.add(BleReceiverFailure(message, code));
    }
  }

  Future<void> _release(String deviceId) async {
    _frames.reset();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs = [];
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {}
  }

  Future<void> cancel() async {
    _cancelled = true;
    final deviceId = _targetDeviceId;
    if (deviceId != null) await _release(deviceId);
  }

  Future<void> dispose() async {
    _cancelled = true;
    _frames.dispose();
    await stopScanning();
    final deviceId = _targetDeviceId;
    if (deviceId != null) await _release(deviceId);
    await _devicesController.close();
    await _linkDirectiveController.close();
    await _serveInfoController.close();
    await _failureController.close();
  }
}

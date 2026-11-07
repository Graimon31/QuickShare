import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_frame.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'linux_bluetooth_sender.dart';

/// BLE sender shared by the desktop and mobile builds.
///
/// Apple builds use the CoreBluetooth bridge in the Runner targets, Linux the
/// BlueZ one. Android and Windows use universal_ble's GATT peripheral API and
/// expose the same service, characteristics, `START:<token>` command and link
/// frames, so an iPhone can receive from either of them with no second
/// protocol.
///
/// ## Generation 4: the rendezvous, not the road
///
/// No file crosses this channel, and none ever will: the owner's decision is
/// that a file does not travel over plain Bluetooth. Once a receiver that
/// scanned this session's QR says what it is (CAPS) and asks (START), the
/// session negotiates a direct Wi-Fi link over the control and metadata
/// characteristics — see `DirectLinkCoordinator` — and the file crosses that
/// link at Wi-Fi speed. What remains here is the radio's part of that
/// negotiation: the advertisement, the writes, and [sendLinkFrame].
class BluetoothTransferTransport implements TransferTransport {
  /// [advertisingTimeout] is how long to wait for the platform to say it is
  /// advertising before saying so out loud. A platform that accepts the
  /// request and then never answers would otherwise leave the person looking
  /// at a spinner until the app is killed.
  ///
  /// [notificationPacing] is the pause after each notification sent through
  /// `universal_ble`; see [_pacing]. Null picks the platform's own.
  BluetoothTransferTransport({
    Duration advertisingTimeout = const Duration(seconds: 10),
    Duration? notificationPacing,
  })  : _advertisingTimeout = advertisingTimeout,
        _notificationPacing = notificationPacing;

  static const _method = MethodChannel('quickshare/bluetooth');
  static const _events = EventChannel('quickshare/bluetooth/events');

  final Duration _advertisingTimeout;
  final Duration? _notificationPacing;

  /// The peripheral local name Apple and Linux senders advertise.
  ///
  /// Carries the session's locator and never the authorization token or any
  /// slice of it. The locator is random (see [BleAdvertisement.newLocator]) and
  /// related to no code, token or network name, so reading it off the air gives
  /// a listener nothing to search with — it exists only so that a receiver that
  /// was shown the QR can tell this sender from another one in range. It used to
  /// be `SessionCode.publicId`: forty bits of a hash over a 33-bit space, which
  /// anyone in range could search for the code. Android and Windows senders do
  /// not advertise a name — see [_startUniversalSession].
  static String bleAdvertisedName({String locator = ''}) =>
      BleAdvertisement.nameFor(locator);

  final _statusController = StreamController<TransferStatus>.broadcast();
  final _universalSubscriptions = <StreamSubscription<dynamic>>[];

  StreamSubscription? _nativeEventSub;
  LinuxBluetoothSender? _linuxSender;
  String? _universalSessionToken;
  String? _universalClientId;
  bool _universalDataSubscribed = false;
  bool _universalStartReceived = false;
  bool _universalTransferStarted = false;

  /// Numbers the frames of one session, so a stray part of one cannot pass for
  /// a part of the next. Replaced for every session.
  BleFrameSplitter _universalSplitter = BleFrameSplitter();

  /// Whether this session has put a notification on the radio yet; see
  /// [_notifyUniversal].
  bool _universalNotified = false;

  /// What the receiver said it can take, from its `CAPS:` write.
  ///
  /// Null means it never sent one, which is what every build up to v1.0.10
  /// does — and those cannot take the direct link at all.
  int? _universalPeerGeneration;

  /// Fires when a generation-4 receiver is connected and the session may
  /// start — the direct-link negotiation begins from here.
  final _receiverReadyController = StreamController<void>.broadcast();

  /// Sealed credentials of a network the receiver raised, offered over the
  /// control channel (`AP:`), in arrival order. Opaque here: only the
  /// coordinator's `LinkSecret` can open one.
  final _apOfferController = StreamController<String>.broadcast();

  /// The receiver's public half for the negotiation, from its `KEX:` write.
  final _peerKeyController = StreamController<String>.broadcast();

  /// The last one seen, replayed to whoever subscribes next.
  ///
  /// The order on the wire is fixed and against us: a receiver writes its
  /// key while connecting, and the coordinator that wants it does not exist
  /// until the session is ready — which is announced afterwards. On a
  /// broadcast stream that key is simply gone, and every negotiation would
  /// end with "the other device did not answer".
  String? _lastPeerKey;

  Stream<void> get receiverReady => _receiverReadyController.stream;

  Stream<String> get apOffers => _apOfferController.stream;

  Stream<String> get peerKeys async* {
    final remembered = _lastPeerKey;
    if (remembered != null) yield remembered;
    yield* _peerKeyController.stream;
  }

  void _rememberPeerKey(String key) {
    _lastPeerKey = key;
    _peerKeyController.add(key);
  }

  /// This transport as the coordinator's signal channel.
  DirectLinkSignal get linkSignal => _SenderLinkSignal(this);

  /// Sends a negotiation frame — `{"link": …}` or `{"serve": …}` — to the
  /// connected receiver over the metadata characteristic, whole.
  ///
  /// A frame is longer than a notification (203 bytes for the directive that
  /// carries credentials, 225 for the serve frame, against 182 on an iPhone and
  /// 20 on a connection nobody negotiated), so it crosses as parts that each fit
  /// and the far side puts it back together: see [BleFrame]. Every platform cuts
  /// and sends in the order of the parts, and a frame is finished before the
  /// next begins — calls made while one is still going wait for it, so the
  /// parts of two frames are never mixed.
  ///
  /// What differs between the platforms is how big a part may be and what
  /// happens when the radio cannot take the next one yet:
  ///
  ///  * Apple: the bridge reads `maximumUpdateValueLength` of the central and
  ///    keeps the parts it could not hand over (`updateValue` returned false)
  ///    until `peripheralManagerIsReady`; this call completes when the last one
  ///    has gone, or fails if the radio never becomes ready.
  ///  * Linux: BlueZ reports the negotiated MTU with each write the receiver
  ///    makes; there is no way to ask the stack to wait, and its queue keeps
  ///    the order.
  ///  * Android and Windows: [_notifyUniversal].
  Future<void> sendLinkFrame(Map<String, Object?> frame) => _inOrder(() async {
        if (_usesNativeAppleBridge) {
          await _method.invokeMethod('sendLinkFrame', {'frame': frame});
          return;
        }
        if (_usesLinuxBridge) {
          try {
            await _linuxSender?.notifyLinkFrame(frame);
          } on BleFrameException catch (e) {
            AppLogger.error(e.message, tag: 'BT_SENDER');
            throw BluetoothRadioException(
                e.message, FailureCode.bluetoothTransferFailed);
          }
          return;
        }
        await _notifyUniversal(frame);
      });

  Future<void> _frameQueue = Future<void>.value();

  /// Runs [send] when every frame before it has been sent. The queue never
  /// carries a failure forward: a frame that failed is that caller's to deal
  /// with, and the next one starts clean.
  Future<void> _inOrder(Future<void> Function() send) {
    final turn = Completer<void>();
    final previous = _frameQueue;
    _frameQueue = turn.future;
    return previous.then((_) => send()).whenComplete(turn.complete);
  }

  /// The pause between two notifications handed to `universal_ble`.
  ///
  /// **Android needs one, and the plugin gives no other way to know.** Its
  /// `updateCharacteristic` sets the characteristic's value, posts
  /// `notifyCharacteristicChanged` to the main thread and returns; it does not
  /// wait for `onNotificationSent` and it throws away the boolean the call
  /// answers with. Android's stack takes one notification at a time, so a
  /// second one asked for before the first has gone is refused — and nothing
  /// here would hear of it. A part that disappears that way is not a silent
  /// loss for the receiver (the next part arrives with its predecessor missing,
  /// and that is a fault, see [BleFrameAssembler]) but it is a failed session,
  /// so the parts are spaced. 30 ms is a little more than a connection
  /// interval on the slow end of what a phone negotiates, which is when the
  /// stack hands the controller its next packet. That is a measure taken from
  /// how the stack behaves, not from a radio on a bench: see the report.
  ///
  /// Windows' `NotifyValueAsync` is awaited to completion by the plugin, which
  /// is the flow control; no pause is needed.
  Duration get _pacing =>
      _notificationPacing ??
      (defaultTargetPlatform == TargetPlatform.android
          ? const Duration(milliseconds: 30)
          : Duration.zero);

  @visibleForTesting
  Duration get debugPacing => _pacing;

  /// What one notification to the connected receiver can carry.
  ///
  /// Asked of the platform where it knows (the negotiated ATT MTU less three:
  /// Android once the central has negotiated one, Windows from the GATT
  /// session). Everywhere it does not — no answer, an answer of nothing — it is
  /// [BleFrame.defaultNotificationBytes], what even a connection nobody
  /// negotiated carries. Assuming more is how a frame reaches the far side
  /// cut in half; assuming the least costs a few more parts.
  Future<int> _notificationBytes(String? clientId) async {
    int? limit;
    if (clientId != null) {
      try {
        limit = await UniversalBlePeripheral.getMaximumNotifyLength(clientId);
      } catch (_) {
        // Unknown, which is not the same as large.
      }
    }
    if (limit == null || limit <= 0) return BleFrame.defaultNotificationBytes;
    return math.min(limit, BleFrame.maxNotificationBytes);
  }

  /// One frame as one or more notifications on the metadata characteristic.
  Future<void> _notifyUniversal(Map<String, Object?> frame) async {
    final clientId = _universalClientId;
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(frame)));
    final notificationBytes = await _notificationBytes(clientId);

    final List<Uint8List> parts;
    try {
      parts =
          _universalSplitter.split(bytes, notificationBytes: notificationBytes);
    } on BleFrameException catch (e) {
      // A real excess — a frame past the largest there is, a connection that
      // cannot hold a header — and the only reason left to refuse one.
      AppLogger.error(e.message, tag: 'BT_SENDER');
      throw BluetoothRadioException(
          e.message, FailureCode.bluetoothTransferFailed);
    }
    AppLogger.info(
        'Frame of ${bytes.length} bytes goes out as ${parts.length} '
        '${parts.length == 1 ? 'part' : 'parts'} of at most '
        '$notificationBytes bytes.',
        tag: 'BT_SENDER');

    final pause = _pacing;
    for (final part in parts) {
      // Before every notification but the first of the session, so the pause
      // separates two notifications wherever they belong — two parts of one
      // frame, or the last of one and the first of the next — and a caller
      // that has just sent the last part is not kept waiting for a pause that
      // protects nothing: the reply it is waiting for may come first.
      if (pause > Duration.zero && _universalNotified) {
        await Future<void>.delayed(pause);
      }
      _universalNotified = true;
      await UniversalBlePeripheral.updateCharacteristicValue(
        characteristicId: BleGatt.metadata,
        value: part,
        // Windows' GattLocalCharacteristic notifies every subscribed client and
        // universal_ble answers "does not support targeting a specific device"
        // to any call that names one. There is one receiver per session anyway.
        deviceId:
            defaultTargetPlatform == TargetPlatform.windows ? null : clientId,
      );
    }
  }

  /// Why the last failure happened, in words meant for the person sending.
  ///
  /// The status stream can only say "failed", and every reason this transport
  /// has — an unreadable file, a receiver too old for a folder — used to end
  /// up in a debugPrint while the screen said "Bluetooth transfer failed
  /// unexpectedly". Read synchronously by the bloc when the status arrives;
  /// it is always set before the status that follows it.
  String? lastFailureReason;

  /// The same reason as a value, where this transport knows it — see
  /// [FailureCode]. Null where the reason is a native bridge's own error
  /// text, which no table can translate. Set and cleared alongside
  /// [lastFailureReason]; read by the bloc when the status arrives.
  String? lastFailureCode;

  bool get _usesNativeAppleBridge =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  bool get _usesLinuxBridge => defaultTargetPlatform == TargetPlatform.linux;

  /// Nothing reports progress from here: no byte crosses this radio. The
  /// transfer's progress is the QHTP server's, which the bloc listens to.
  @override
  Stream<double> get progressStream => const Stream<double>.empty();

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
        if (!BleUuidParser.compareStrings(
                event.characteristicId, BleGatt.data) ||
            !event.isSubscribed ||
            _universalSessionToken == null) {
          return;
        }
        _universalClientId = event.deviceId;
        _universalDataSubscribed = true;
        _statusController.add(TransferStatus.connecting);
        _onUniversalSessionReady();
      }),
    );

    UniversalBlePeripheral.setWriteRequestHandlers(
      (deviceId, characteristicId, offset, value) {
        if (BleUuidParser.compareStrings(characteristicId, BleGatt.control) &&
            value != null &&
            _universalSessionToken != null) {
          final command = utf8.decode(value, allowMalformed: true);
          // Always ahead of START, so it is on record before the decision
          // about what this session may send is taken.
          final generation = BleControlProtocol.parseCapabilities(command);
          if (generation != null) {
            _universalPeerGeneration = generation;
          } else if (BleControlProtocol.parseHello(command) case final name?) {
            // Written by an Apple receiver ahead of its START. Display text
            // from the far side, read only to tell an Apple device from the
            // rest.
            _universalClientId ??= deviceId;
            _receiverName = name;
          } else if (BleControlProtocol.parseKeyExchange(command)
              case final key?) {
            _universalClientId ??= deviceId;
            _rememberPeerKey(key);
          } else if (BleControlProtocol.parseApOffer(command)
              case final sealed?) {
            // A receiver that raised the network itself says where — sealed.
            _universalClientId ??= deviceId;
            _apOfferController.add(sealed);
          } else if (BleControlProtocol.isStart(
              command, _universalSessionToken)) {
            _universalClientId = deviceId;
            _universalStartReceived = true;
            _onUniversalSessionReady();
          } else if (BleControlProtocol.isUnauthorizedStart(
              command, _universalSessionToken)) {
            // A START without the session token — a receiver too old to pair
            // securely. Say so rather than leaving both sides waiting.
            lastFailureReason = BleControlProtocol.staleReceiverMessage;
            lastFailureCode = FailureCode.receiverTooOldToPair;
            _statusController.add(TransferStatus.failed);
            // And refuse the write itself. Answering success here told that
            // receiver its transfer had begun while this side was tearing
            // the session down behind it, so it waited on bytes that were
            // never coming. Apple's bridges have always answered this way.
            return PeripheralWriteRequestResult(
                status: BleControlProtocol.attInsufficientAuthentication);
          }
        }
        return PeripheralWriteRequestResult();
      },
    );
  }

  /// What the receiver on the radio calls itself, when it said.
  ///
  /// The Apple bridge and the universal one both report the name a connected
  /// receiver writes ahead of its START. It is display text from the far side,
  /// read by the sender only to tell whether that device is an Apple one (see
  /// `_beginBluetoothDirectLink`), and is never shown as a choice: nothing is
  /// listed and nothing is picked. Null until a receiver has said, and for
  /// receivers that do not — which is every Android one, and nothing depends
  /// on it being set.
  String? get receiverName => _receiverName;
  String? _receiverName;

  void _handleNativeEvent(dynamic event) {
    final map = Map<String, dynamic>.from(event as Map);
    switch (map['type']) {
      case 'bleDiagnostic':
        final message = map['message'];
        if (message is String) AppLogger.info(message, tag: 'BLE_NATIVE');
        break;
      case 'advertisingStarted':
        _statusController.add(TransferStatus.serving);
        break;
      case 'centralConnected':
        _statusController.add(TransferStatus.connecting);
        break;
      case 'receiverAnnounced':
        final name = map['name'] as String?;
        if (name != null && name.isNotEmpty) _receiverName = name;
        break;
      case 'receiverReady':
        // A generation-4 receiver is connected and the session may start —
        // the direct-link negotiation begins from here.
        _receiverReadyController.add(null);
        break;
      case 'apOffer':
        // A receiver that raised the network itself says where — sealed.
        final sealed = map['sealed'] as String?;
        if (sealed != null && sealed.isNotEmpty) _apOfferController.add(sealed);
        break;
      case 'peerKey':
        final key = map['key'] as String?;
        if (key != null && key.isNotEmpty) _rememberPeerKey(key);
        break;
      case 'senderFailed':
        final error = map['error'] as String?;
        debugPrint('Bluetooth send failed: $error');
        lastFailureReason = error;
        // Apple's bridge names the two refusals it decides itself; anything
        // else it reports is CoreBluetooth's own text, which stays as-is.
        lastFailureCode = map['code'] as String?;
        _statusController.add(TransferStatus.failed);
        break;
    }
  }

  /// Advertises the session over BLE, and waits until the platform says it is
  /// on the air. Not part of [TransferTransport]: this transport's UX is a QR
  /// code a receiver scans, not a shareable link.
  ///
  /// [file] names the session for the screens that show it. [files] is the
  /// whole selection and is not sent anywhere: since generation 4 the receiver
  /// learns what it is getting from the QHTP manifest on the Wi-Fi link, and
  /// a folder no longer has to be described to a radio that cannot carry it.
  ///
  /// [locator] is what goes out over the air on Apple and Linux, when there is
  /// one: random, drawn for this session, and the same one the QR carries, so a
  /// receiver that scanned the QR can pick this device out of several. It is
  /// public by design and tied to nothing — not to [token], not to a code, not
  /// to a network name. Advertising a slice of [token] instead, which is what
  /// every earlier build did, puts the first eight characters of the session's
  /// secret in a packet anyone in radio range can read; advertising a value
  /// worked out from the session's digits, which the build before this one did,
  /// puts something in range that can be searched for them. Android and Windows
  /// do not advertise it at all.
  ///
  /// Throws [BluetoothRadioException] on Android and Windows when the radio
  /// cannot advertise, with a code the screen can say in the person's own
  /// language. Never completes without the platform's answer.
  Future<String> startSharing(FileMetadata file, String token,
      {List<FileMetadata>? files, String locator = ''}) async {
    lastFailureReason = null;
    lastFailureCode = null;
    _receiverName = null;
    if (_usesNativeAppleBridge) {
      final ready = Completer<TransferStatus>();
      final subscription = statusStream.listen((status) {
        if (ready.isCompleted) return;
        if (status == TransferStatus.serving) {
          ready.complete(status);
        } else if (status == TransferStatus.failed ||
            status == TransferStatus.cancelled) {
          ready.complete(status);
        }
      });
      try {
        // The native method starts an asynchronous CoreBluetooth operation.
        // The delegate's success or failure, not the method return, is the
        // point at which an offer can truthfully be shown to a receiver.
        await _method.invokeMethod('startAdvertising', {
          'sessionToken': token,
          if (locator.isNotEmpty) 'locator': locator,
        });
        final result = await ready.future.timeout(_advertisingTimeout);
        if (result == TransferStatus.cancelled) {
          throw const BluetoothRadioException(
              'Bluetooth advertising was cancelled.',
              FailureCode.cancelledHere);
        }
        if (result == TransferStatus.failed) {
          throw BluetoothRadioException(
              lastFailureReason ?? 'Bluetooth advertising failed.',
              FailureCode.bluetoothTransferFailed);
        }
      } on TimeoutException {
        try {
          await _method.invokeMethod('stopAdvertising');
        } catch (_) {}
        throw const BluetoothRadioException(
            'Bluetooth did not report that advertising had started.',
            FailureCode.bluetoothTransferFailed);
      } on PlatformException catch (e) {
        throw Exception('Failed to start Bluetooth: ${e.message}');
      } on MissingPluginException {
        throw Exception('Bluetooth is unavailable in this platform build.');
      } finally {
        await subscription.cancel();
      }
      return file.name;
    }

    if (_usesLinuxBridge) {
      _linuxSender = LinuxBluetoothSender();
      await _linuxSender!.start(
        token,
        locator: locator,
        onStatus: (status, [error, code]) {
          switch (status) {
            case 'advertising':
              _statusController.add(TransferStatus.serving);
              break;
            case 'connected':
              _statusController.add(TransferStatus.connecting);
              break;
            case 'ready':
              // A generation-4 receiver is connected; the direct-link
              // negotiation begins from here.
              _receiverReadyController.add(null);
              break;
            case 'failed':
              debugPrint('Bluetooth Linux sender failed: $error');
              lastFailureReason = error;
              lastFailureCode = code;
              _statusController.add(TransferStatus.failed);
              break;
          }
        },
        onApOffer: _apOfferController.add,
        onPeerKey: _rememberPeerKey,
      );
      return file.name;
    }

    await _startUniversalSession(token);
    return file.name;
  }

  /// Makes this Android phone or Windows PC findable, and answerable.
  ///
  /// ## What is on the air, and why not more
  ///
  /// The service UUID, in the primary packet, and no local name.
  ///
  /// A legacy advertising packet holds 31 bytes. Three go to the flags, a
  /// 128-bit service UUID takes 18, and `QuickShare-` plus the eight-character
  /// locator would take 21 more — 42 in all, which Android refuses with
  /// `ADVERTISE_FAILED_DATA_TOO_LARGE`. That is what the first version of this
  /// code asked for, and it could not have started on a phone. The plugin can
  /// move the UUID to the scan response and keep the name in the primary
  /// packet, but both receivers scan with the UUID as the filter, and a
  /// filter that has to look inside a scan response is one more way for the
  /// device not to be found; the UUID stays where every scan stack looks for
  /// it. Setting a name also renames the phone's own Bluetooth name for as
  /// long as the advertisement lasts, which a killed app would leave behind.
  ///
  /// Windows cannot set a name at all (`GattServiceProvider` does not take
  /// one), so it was never going to carry a locator. Neither does it need
  /// to: the locator is random and public, so leaving it off the air costs
  /// nothing and hides nothing.
  ///
  /// What the receivers do with an advertisement that has no `QuickShare-`
  /// name is accept it: the service UUID is the proof that it is a DirectDrop
  /// sender, and the `START:<token>` write after the connection is what proves
  /// it is the one the QR named (see [BleAdvertisement.accepts]).
  Future<void> _startUniversalSession(String token) async {
    _universalSessionToken = null;
    _lastPeerKey = null;
    _universalClientId = null;
    _universalDataSubscribed = false;
    _universalStartReceived = false;
    _universalTransferStarted = false;
    _universalSplitter = BleFrameSplitter();
    _universalNotified = false;
    // Nothing is assumed about the receiver: a build that never says what it
    // can take (everything before v1.0.10) is refused at START rather than
    // trusted with a directive it cannot read.
    _universalPeerGeneration = null;

    try {
      await UniversalBle.requestPermissions(withAndroidFineLocation: false);
    } catch (e) {
      throw BluetoothRadioException('Bluetooth permission was refused: $e',
          FailureCode.bluetoothPermissionDenied);
    }

    final capabilities = await UniversalBlePeripheral.getCapabilities();
    if (!capabilities.supportsPeripheralMode) {
      throw const BluetoothRadioException(
          'This device\'s Bluetooth cannot act as the sending end '
          '(peripheral mode is not supported).',
          FailureCode.bluetoothSendUnsupported);
    }
    final readiness = await UniversalBlePeripheral.getAvailabilityState();
    switch (readiness) {
      case PeripheralReadinessState.ready:
        break;
      case PeripheralReadinessState.bluetoothOff:
        throw const BluetoothRadioException(
            'Bluetooth is turned off.', FailureCode.bluetoothOff);
      case PeripheralReadinessState.unauthorized:
        throw const BluetoothRadioException(
            'Bluetooth is not authorized for this app.',
            FailureCode.bluetoothPermissionDenied);
      case PeripheralReadinessState.unsupported:
        throw const BluetoothRadioException(
            'This device\'s Bluetooth cannot act as the sending end.',
            FailureCode.bluetoothSendUnsupported);
      case PeripheralReadinessState.unknown:
        throw const BluetoothRadioException(
            'Bluetooth is not ready: the platform could not say what state '
            'it is in.',
            FailureCode.bluetoothAdvertiseFailed);
    }

    // Before anything is on the air, so a receiver that connects the instant
    // it sees the advertisement is already answered.
    _universalSessionToken = token;
    try {
      await _ensureUniversalService();
      await _advertiseAndWait();
    } catch (_) {
      // A half-started advertiser answers "already started" to the next try.
      try {
        await UniversalBlePeripheral.stopAdvertising();
      } catch (_) {}
      _universalSessionToken = null;
      rethrow;
    }
    _statusController.add(TransferStatus.serving);
  }

  /// Registers the GATT service, once for the life of the process.
  ///
  /// Not once per session: universal_ble's Android side caches the
  /// characteristic objects it builds by UUID, keeps the first of each, and
  /// does not clear that cache on `clearServices()`. A service added a second
  /// time is a service whose characteristics `updateCharacteristicValue`
  /// resolves to the first one's objects — notifications through handles the
  /// server no longer owns, which is a negotiation frame that goes nowhere on
  /// the second code of a session, the first rotation. A service that stays
  /// registered and an advertisement that comes and goes has none of that.
  Future<void> _ensureUniversalService() async {
    var known = const <String>[];
    try {
      known = await UniversalBlePeripheral.getServices();
    } catch (_) {}
    if (known.any((s) => BleUuidParser.compareStrings(s, BleGatt.service))) {
      return;
    }

    final cccd = BlePeripheralDescriptor(uuid: BleGatt.cccd);
    try {
      await UniversalBlePeripheral.addService(
        BlePeripheralService(
          uuid: BleGatt.service,
          primary: true,
          characteristics: [
            BlePeripheralCharacteristic(
              uuid: BleGatt.control,
              properties: [
                CharacteristicProperty.write,
                CharacteristicProperty.writeWithoutResponse,
              ],
              permissions: [PeripheralAttributePermission.writeable],
            ),
            BlePeripheralCharacteristic(
              uuid: BleGatt.metadata,
              properties: [CharacteristicProperty.notify],
              descriptors: [cccd],
              permissions: [PeripheralAttributePermission.readable],
            ),
            BlePeripheralCharacteristic(
              uuid: BleGatt.data,
              properties: [CharacteristicProperty.notify],
              descriptors: [BlePeripheralDescriptor(uuid: BleGatt.cccd)],
              permissions: [PeripheralAttributePermission.readable],
            ),
          ],
        ),
      );
    } on PlatformException catch (e) {
      throw _serviceRefused(e);
    }
  }

  /// What the platform's refusal to register the service means for the person.
  static BluetoothRadioException _serviceRefused(PlatformException e) {
    final said = e.message ?? e.code;
    final lower = said.toLowerCase();
    // Windows: GattServiceProvider.CreateAsync says why in its BluetoothError.
    if (lower.contains('notsupported')) {
      return BluetoothRadioException(
          'This adapter cannot act as the sending end: $said',
          FailureCode.bluetoothSendUnsupported);
    }
    if (lower.contains('radionotavailable') ||
        lower.contains('disabledbyuser') ||
        lower.contains('disabledbypolicy')) {
      return BluetoothRadioException(
          'Bluetooth is turned off: $said', FailureCode.bluetoothOff);
    }
    return BluetoothRadioException(
        'Bluetooth could not register the sending service: $said',
        FailureCode.bluetoothAdvertiseFailed);
  }

  /// Asks the platform to advertise and returns when it says it is doing so.
  ///
  /// The plugin's `startAdvertising` returns as soon as the request is made.
  /// Whether the advertisement started arrives later, on
  /// `advertisingStateStream` — Android's "data too large" and "too many
  /// advertisers" among them — so a caller that only awaited the call would
  /// report success for an advertisement that never existed.
  Future<void> _advertiseAndWait() async {
    final answered = Completer<void>();
    // The answer can land while this method is awaiting something else, with
    // nobody yet listening to the future. An error with no listener is
    // reported as unhandled, even though the code below will read it.
    answered.future.then<void>((_) {}, onError: (Object _) {});
    final subscription =
        UniversalBlePeripheral.advertisingStateStream.listen((event) {
      if (answered.isCompleted) return;
      switch (event.state) {
        case PeripheralAdvertisingState.advertising:
          answered.complete();
        case PeripheralAdvertisingState.error:
          answered.completeError(BluetoothRadioException(
              'Bluetooth advertising failed: '
              '${event.error ?? 'the platform gave no reason'}',
              FailureCode.bluetoothAdvertiseFailed));
        case PeripheralAdvertisingState.idle:
        case PeripheralAdvertisingState.starting:
        case PeripheralAdvertisingState.stopping:
          break;
      }
    });
    try {
      try {
        await UniversalBlePeripheral.startAdvertising(
          services: [BleGatt.service],
          // See _startUniversalSession: a name does not fit, and cannot be
          // set at all on Windows.
          localName: null,
          platformConfig: PeripheralPlatformConfig(
            android: PeripheralAndroidOptions(
              addServicesInScanResponse: false,
              addManufacturerDataInScanResponse: false,
            ),
          ),
        );
      } on PlatformException catch (e) {
        throw _advertiseRefused(e);
      } on BluetoothRadioException {
        rethrow;
      } catch (e) {
        throw _advertiseRefused(
            PlatformException(code: 'failed', message: '$e'));
      }

      // The answer may already be in: ask once rather than wait for an event
      // that came before the listener's turn.
      if (await _isAdvertising()) return;

      await answered.future.timeout(_advertisingTimeout, onTimeout: () async {
        if (await _isAdvertising()) return;
        throw BluetoothRadioException(
            'Bluetooth did not report that advertising had started within '
            '${_advertisingTimeout.inSeconds} seconds.',
            FailureCode.bluetoothAdvertiseFailed);
      });
    } finally {
      // Not awaited: letting go of a listener is not something a start-up
      // should be able to wait on.
      unawaited(subscription.cancel());
    }
  }

  Future<bool> _isAdvertising() async {
    try {
      return await UniversalBlePeripheral.getAdvertisingState() ==
          PeripheralAdvertisingState.advertising;
    } catch (_) {
      return false;
    }
  }

  static BluetoothRadioException _advertiseRefused(PlatformException e) {
    final said = e.message ?? e.code;
    if (e.code == 'bluetooth-advertise-permission-denied') {
      return const BluetoothRadioException(
          'Bluetooth advertise permission was refused.',
          FailureCode.bluetoothPermissionDenied);
    }
    if (said.toLowerCase().contains('not enabled') ||
        said.toLowerCase().contains('bluetooth is off')) {
      return BluetoothRadioException(
          'Bluetooth is turned off: $said', FailureCode.bluetoothOff);
    }
    return BluetoothRadioException(
        'Bluetooth refused to start advertising: $said',
        FailureCode.bluetoothAdvertiseFailed);
  }

  /// The session is fully dressed — subscribed and asked for — so it begins.
  ///
  /// Since generation 4 "begins" never means streaming bytes here: a peer
  /// that understands the direct link is announced on [receiverReady] and
  /// the coordinator builds the network the file actually crosses, and a
  /// peer below it is refused with the update it needs rather than sent
  /// anything slowly.
  void _onUniversalSessionReady() {
    if (_universalTransferStarted ||
        !_universalDataSubscribed ||
        !_universalStartReceived ||
        _universalClientId == null ||
        _universalSessionToken == null) {
      return;
    }
    _universalTransferStarted = true;
    if (!BleControlProtocol.peerSupportsDirectLink(_universalPeerGeneration)) {
      lastFailureReason = BleControlProtocol.directLinkRequiredMessage;
      lastFailureCode = FailureCode.receiverTooOldForDirectLink;
      _statusController.add(TransferStatus.failed);
      return;
    }
    _receiverReadyController.add(null);
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
        // The service stays registered; see _ensureUniversalService.
        await UniversalBlePeripheral.stopAdvertising();
      } catch (_) {
        // best effort
      }
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
      _universalPeerGeneration = null;
    }
    _statusController.add(TransferStatus.cancelled);
  }
}

/// The sender side of the rendezvous' signal channel.
///
/// Directives go out over the metadata characteristic; a sender never
/// receives one — the receiver does not decide who hosts, it is told. What
/// comes back is the credentials of the network the receiver was asked to
/// raise.
class _SenderLinkSignal implements DirectLinkSignal {
  final BluetoothTransferTransport _transport;

  _SenderLinkSignal(this._transport);

  @override
  Future<void> sendDirective(DirectLinkDirective directive) =>
      _transport.sendLinkFrame({'link': directive.toJson()});

  @override
  Stream<DirectLinkDirective> get directives => const Stream.empty();

  @override
  Future<void> sendApOffer(String sealed) =>
      throw UnsupportedError('a sender makes no offers');

  @override
  Stream<String> get apOffers => _transport.apOffers;

  @override
  Future<void> sendKeyExchange(String publicKey) =>
      throw UnsupportedError('a sender does not offer its key this way');

  @override
  Stream<String> get peerKeys => _transport.peerKeys;
}

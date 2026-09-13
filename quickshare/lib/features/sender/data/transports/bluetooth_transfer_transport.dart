import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'linux_bluetooth_sender.dart';

/// A nearby receiver this sender can pick, found by scanning.
class BleWaitingPeer {
  final String id;
  final String name;
  const BleWaitingPeer({required this.id, required this.name});
}

/// BLE sender shared by the desktop and mobile builds.
///
/// Apple builds keep using the tested CoreBluetooth bridge in the Runner
/// targets. Android and Windows use universal_ble's GATT peripheral API, but
/// expose the same service, characteristics, START:<token> command, metadata
/// and raw data stream. That means an iPhone or Mac can receive from either
/// of those platforms without a second transfer protocol.
///
/// ## Generation 4: the rendezvous, not the road
///
/// Since protocol generation 4 no bytes cross this channel. Once a receiver
/// says what it is (CAPS) and asks (START) or is picked (HELLO), the session
/// negotiates a direct Wi-Fi link over the control and metadata
/// characteristics — see `DirectLinkCoordinator` — and the file crosses
/// that link at Wi-Fi speed. What remains here is the radio's part of that
/// negotiation: the advertisement, the writes, and [sendLinkFrame].
class BluetoothTransferTransport implements TransferTransport {
  static const _method = MethodChannel('quickshare/bluetooth');
  static const _events = EventChannel('quickshare/bluetooth/events');

  static const _serviceUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';
  static const _controlUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B11';
  static const _metadataUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B12';
  static const _dataUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B13';

  /// The peripheral local name to advertise over BLE.
  ///
  /// Safe to broadcast: carries only the non-secret public identifier, never the
  /// authorization token or its prefix.
  static String bleAdvertisedName({String publicId = ''}) =>
      'QuickShare-${publicId.isNotEmpty ? publicId : 'directdrop'}';

  final _progressController = StreamController<double>.broadcast();
  final _statusController = StreamController<TransferStatus>.broadcast();
  final _universalSubscriptions = <StreamSubscription<dynamic>>[];

  StreamSubscription? _nativeEventSub;
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
  /// connected receiver over the metadata characteristic.
  ///
  /// Retried briefly where the platform queue can refuse: CoreBluetooth
  /// answers a full queue with a BUSY error rather than a lost frame, and a
  /// negotiation frame lost is a session that never begins.
  Future<void> sendLinkFrame(Map<String, Object?> frame) async {
    if (_usesNativeAppleBridge) {
      PlatformException? lastBusy;
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          await _method.invokeMethod('sendLinkFrame', {'frame': frame});
          return;
        } on PlatformException catch (e) {
          if (e.code != 'BUSY') rethrow;
          lastBusy = e;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      throw lastBusy!;
    }
    if (_usesLinuxBridge) {
      await _linuxSender?.notifyLinkFrame(frame);
      return;
    }
    final clientId = _universalClientId;
    if (clientId != null) {
      await UniversalBle.write(
        clientId,
        _serviceUuid,
        _metadataUuid,
        Uint8List.fromList(utf8.encode(jsonEncode(frame))),
        withoutResponse: false,
      );
      return;
    }
    await UniversalBlePeripheral.updateCharacteristicValue(
      characteristicId: _metadataUuid,
      value: Uint8List.fromList(utf8.encode(jsonEncode(frame))),
      deviceId: _universalClientId,
    );
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
        _onUniversalSessionReady();
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

  final _waitingController = StreamController<BleWaitingPeer>.broadcast();

  /// Receivers this sender has seen advertising, waiting to be picked.
  Stream<BleWaitingPeer> get waitingReceivers => _waitingController.stream;

  String? _scanSessionToken;

  /// Starts sending to the device the person picked off that list.
  ///
  /// Nothing new is negotiated: the receiver connected and subscribed when it
  /// announced itself, so this is the go-ahead that used to arrive as its own
  /// START.
  Future<void> beginTransfer() async {
    if (!_usesNativeAppleBridge) return;
    try {
      await _method.invokeMethod('beginTransfer');
    } on MissingPluginException {
      // An older platform build. The receiver-led path still works.
    }
  }

  /// Connect to a waiting receiver and start the rendezvous as GATT central.
  Future<void> connectToReceiver(String deviceId) async {
    final token = _scanSessionToken;
    if (token == null || token.isEmpty) {
      throw StateError('Bluetooth session has no token');
    }
    if (_usesNativeAppleBridge) {
      await _method.invokeMethod('connect', {
        'deviceId': deviceId,
        'asSender': true,
        'sessionToken': token,
      });
      return;
    }
    await _connectUniversalReceiver(deviceId, token);
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
      case 'receiverAnnounced':
        final name = map['name'] as String?;
        if (name != null && name.isNotEmpty) {
          _waitingController.add(BleWaitingPeer(id: name, name: name));
        }
        break;
      case 'deviceDiscovered':
        final id = map['id'] as String?;
        final name = map['name'] as String?;
        if (id != null && id.isNotEmpty) {
          _waitingController.add(BleWaitingPeer(
            id: id,
            name: (name != null && name.isNotEmpty) ? name : id,
          ));
        }
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
        // Apple's bridge names the two refusals it decides itself; anything
        // else it reports is CoreBluetooth's own text, which stays as-is.
        lastFailureCode = map['code'] as String?;
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
  /// [publicId] is what goes out over the air, when there is one.
  ///
  /// Derived from the session's digits and not reversible, so a receiver who
  /// was read the code can pick this device out of several without the code
  /// itself being broadcast. Advertising a slice of [token] instead — which is
  /// what happens when this is absent, and what every earlier build did — puts
  /// the first eight characters of the session's secret in a packet anyone in
  /// radio range can read.
  Future<String> startSharing(FileMetadata file, String token,
      {List<FileMetadata>? files, String publicId = ''}) async {
    final session = (files == null || files.isEmpty) ? [file] : files;
    _totalBytes = session.fold<int>(0, (sum, f) => sum + f.size);
    lastFailureReason = null;
    lastFailureCode = null;
    _scanSessionToken = token;
    if (_usesNativeAppleBridge) {
      try {
        // Sender finds receivers: we scan, they advertise.
        await _method.invokeMethod('startScanning', {
          'sessionToken': token,
          if (publicId.isNotEmpty) 'publicId': publicId,
          'forReceivers': true,
        });
        _statusController.add(TransferStatus.serving);
      } on PlatformException catch (e) {
        throw Exception('Failed to start Bluetooth scan: ${e.message}');
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
        publicId: publicId,
        onProgress: (sent, total) {
          if (total > 0) _progressController.add(sent / total);
        },
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
            case 'completed':
              _progressController.add(1.0);
              _statusController.add(TransferStatus.completed);
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

    await _startUniversalScan(token, publicId);
    return file.name;
  }

  Future<void> _connectUniversalReceiver(String deviceId, String token) async {
    _universalClientId = deviceId;
    await UniversalBle.connect(deviceId);
    await UniversalBle.discoverServices(deviceId);
    await UniversalBle.subscribeNotifications(
        deviceId, _serviceUuid, _metadataUuid);
    UniversalBle.characteristicValueStream(deviceId, _metadataUuid).listen((value) {
      final text = utf8.decode(value, allowMalformed: true);
      if (BleControlProtocol.parseApOffer(text) case final sealed?) {
        _apOfferController.add(sealed);
        return;
      }
      if (BleControlProtocol.parseKeyExchange(text) case final key?) {
        _rememberPeerKey(key);
      }
    });
    await UniversalBle.write(
      deviceId,
      _serviceUuid,
      _controlUuid,
      Uint8List.fromList(utf8.encode(BleControlProtocol.capabilities())),
      withoutResponse: false,
    );
    await UniversalBle.write(
      deviceId,
      _serviceUuid,
      _controlUuid,
      Uint8List.fromList(utf8.encode(BleControlProtocol.start(token))),
      withoutResponse: false,
    );
    _receiverReadyController.add(null);
  }

  Future<void> _startUniversalScan(String token, String publicId) async {
    await UniversalBle.requestPermissions(withAndroidFineLocation: false);
    _universalSessionToken = token;
    _lastPeerKey = null;
    _universalPeerGeneration = 4;
    _universalClientId = null;
    UniversalBle.scanStream.listen((device) {
      final name = device.name ?? '';
      _waitingController.add(BleWaitingPeer(
        id: device.deviceId,
        name: name.isNotEmpty ? name : device.deviceId,
      ));
    });
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [_serviceUuid]),
    );
    _statusController.add(TransferStatus.serving);
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
        await _method.invokeMethod('stopScanning');
      } catch (_) {}
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
        await UniversalBle.stopScan();
      } catch (_) {}
      try {
        await UniversalBlePeripheral.stopAdvertising();
        await UniversalBlePeripheral.clearServices();
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

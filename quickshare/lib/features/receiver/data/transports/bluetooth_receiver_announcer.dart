import 'dart:async';
import 'dart:io';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/network/device_presence.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/direct_link_driver.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';
import 'package:quickshare/features/receiver/data/transports/receiver_link_signal.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

/// Advertises this device over Bluetooth Low Energy so a nearby sender can
/// find it and send.
///
/// Generation 4 puts the search on the sender: this side is a GATT peripheral
/// ("I am waiting"), the sender scans, the person sending picks the row.
/// Connecting the other way around — this side finding the sender — is what
/// made a Mac receiving from an iPhone vanish from the list.
///
/// When the sender connects and later writes a `serve` frame, this converts
/// that into a [QRPayload] and notifies [onServeReceived].
class BluetoothReceiverAnnouncer {
  final BleReceiver _transport;
  final DirectLinkDriver _driver;
  final NetworkInfoService _networkInfo;
  final LocalHotspotService _hotspotService;

  StreamSubscription? _deviceSub;
  StreamSubscription? _progressSub;
  StreamSubscription? _serveSub;
  int? _peerLinkPort;
  Completer<int?>? _peerLinkCompleter;
  bool _joinedAsGuest = false;
  bool _isActive = false;
  bool _isConnecting = false;

  final void Function(QRPayload payload)? onServeReceived;

  BluetoothReceiverAnnouncer({
    BleReceiver? transport,
    DirectLinkDriver? driver,
    NetworkInfoService? networkInfo,
    LocalHotspotService? hotspotService,
    this.onServeReceived,
  })  : _transport = transport ?? BluetoothReceiverTransport.forPlatform(),
        _driver = driver ?? LocalHotspotDriver(),
        _networkInfo = networkInfo ?? NetworkInfoService(),
        _hotspotService = hotspotService ?? LocalHotspotService();

  bool get isActive => _isActive;
  bool get joinedAsGuest => _joinedAsGuest;
  int? get peerLinkPort => _peerLinkPort;

  Future<void> start() async {
    if (_isActive) return;
    _isActive = true;
    _peerLinkPort = null;
    _peerLinkCompleter = null;

    _deviceSub = _transport.devices.listen((device) async {
      if (!_isActive || _isConnecting) return;
      if (!device.name.startsWith('QuickShare-')) return;
      _isConnecting = true;
      AppLogger.info(
        'Found sender "${device.name}", connecting as central (≤3s handshake)…',
        tag: 'BT_ANNOUNCE',
      );
      try {
        await _transport.connect(
          device.id,
          token: null,
          targetDir: Directory.systemTemp.path,
        );
      } catch (e) {
        AppLogger.warning('Could not connect to sender: $e', tag: 'BT_ANNOUNCE');
        _isConnecting = false;
      }
    });

    _progressSub = _transport.progressStream.listen((progress) {
      if (!_isActive) return;
      if (progress.phase == 'waiting') {
        AppLogger.info(
          'Sender connected, negotiating direct link in background...',
          tag: 'BT_ANNOUNCE',
        );
        _peerLinkCompleter ??= Completer<int?>();
        unawaited(_negotiateDirectLink());
      } else if (progress.phase == 'failed' || progress.phase == 'disconnected') {
        AppLogger.warning(
          'Bluetooth waiting advertisement ended: phase=${progress.phase}',
          tag: 'BT_ANNOUNCE',
        );
      }
    });

    _serveSub = _transport.serveInfos.listen((serve) async {
      if (!_isActive) return;
      AppLogger.info(
        'Received serve frame from sender: ${serve.ip}:${serve.port} (lanIp: ${serve.lanIp})',
        tag: 'BT_ANNOUNCE',
      );

      String targetIp = serve.ip;
      int targetPort = serve.port;

      if (serve.ip == '127.0.0.1' || _peerLinkCompleter != null) {
        if (_peerLinkPort == null && _peerLinkCompleter != null && !_peerLinkCompleter!.isCompleted) {
          try {
            await _peerLinkCompleter!.future.timeout(const Duration(seconds: 6));
          } catch (_) {}
        }

        if (_peerLinkPort != null) {
          targetIp = '127.0.0.1';
          targetPort = _peerLinkPort!;
        } else if (serve.lanIp.isNotEmpty) {
          targetIp = serve.lanIp;
          targetPort = serve.port;
        }
      }

      final payload = QRPayload(
        version: AppConstants.qhtpPayloadVersion,
        ip: targetIp,
        port: targetPort,
        token: serve.token,
        sessionId: serve.token,
        mode: 'http-lan',
        tlsFingerprint: serve.tlsFingerprint,
        fileName: serve.fileName,
        fileSize: serve.fileSize,
        itemCount: serve.itemCount,
        senderName: serve.senderName,
      );

      onServeReceived?.call(payload);
    });

    try {
      await _transport.startWaitingAdvertisement(
        deviceName: DevicePresence.describeThisDevice(),
      );
      AppLogger.info('Bluetooth receiver waiting advertisement started',
          tag: 'BT_ANNOUNCE');
    } catch (e) {
      AppLogger.warning('Could not advertise over Bluetooth: $e',
          tag: 'BT_ANNOUNCE');
    }
    try {
      await _transport.startScanning(sessionToken: null, publicId: null);
      AppLogger.info('Bluetooth receiver also scanning for senders',
          tag: 'BT_ANNOUNCE');
    } catch (e) {
      AppLogger.warning('Could not scan for senders: $e', tag: 'BT_ANNOUNCE');
    }
  }

  Future<void> _negotiateDirectLink() async {
    _peerLinkCompleter ??= Completer<int?>();
    try {
      final outcome = await DirectLinkCoordinator(
        driver: _driver,
        signal: ReceiverLinkSignal(_transport),
        probeLink: () async {
          for (var i = 0; i < 20; i++) {
            final ip = await _networkInfo.getLocalIpAddress();
            if (ip != null && !ip.startsWith('127.') && ip.isNotEmpty) {
              return true;
            }
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          return false;
        },
      ).runReceiver(null);

      switch (outcome) {
        case DirectLinkUnavailable(message: final msg):
          AppLogger.info('DirectLink unavailable: $msg', tag: 'BT_ANNOUNCE');
          if (!_peerLinkCompleter!.isCompleted) _peerLinkCompleter!.complete(null);
        case DirectLinkOverPeerLink(localPort: final port):
          _peerLinkPort = port;
          if (!_peerLinkCompleter!.isCompleted) _peerLinkCompleter!.complete(port);
        case DirectLinkReady(hosting: final hosting):
          if (!hosting) {
            _joinedAsGuest = true;
          }
          _peerLinkPort = null;
          if (!_peerLinkCompleter!.isCompleted) _peerLinkCompleter!.complete(null);
      }
    } catch (e) {
      AppLogger.warning('DirectLink negotiation failed: $e', tag: 'BT_ANNOUNCE');
      if (!_peerLinkCompleter!.isCompleted) {
        _peerLinkCompleter!.complete(null);
      }
    }
  }

  /// Pauses scanning/listening for incoming transfers while keeping
  /// any active direct link alive for download.
  Future<void> detachForTransfer() async {
    _isActive = false;
    await _deviceSub?.cancel();
    _deviceSub = null;
    await _progressSub?.cancel();
    _progressSub = null;
    await _serveSub?.cancel();
    _serveSub = null;
  }

  /// Stops advertisement and leaves Wi-Fi network if joined as a guest.
  Future<void> stop() async {
    _isActive = false;
    _peerLinkPort = null;
    if (_peerLinkCompleter != null && !_peerLinkCompleter!.isCompleted) {
      _peerLinkCompleter!.complete(null);
    }
    _peerLinkCompleter = null;
    await _deviceSub?.cancel();
    _deviceSub = null;
    await _progressSub?.cancel();
    _progressSub = null;
    await _serveSub?.cancel();
    _serveSub = null;

    try {
      await _transport.cancel();
    } catch (_) {}

    if (_joinedAsGuest) {
      _joinedAsGuest = false;
      unawaited(_hotspotService.leaveNetwork());
    }
  }
}

import 'dart:async';
import 'dart:io';

import 'package:mime/mime.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/direct_link_driver.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/storage/receive_destination.dart';
import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/client/isolated_qhtp_receiver.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';
import 'package:quickshare/features/receiver/data/transports/receiver_link_signal.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class BluetoothReceiverSessionResult {
  final String preferredPath;
  final String displayName;
  final List<ReceivedItem> items;
  final bool placed;

  BluetoothReceiverSessionResult({
    required this.preferredPath,
    required this.displayName,
    required this.items,
    required this.placed,
  });
}

class BluetoothReceiverSession {
  final BleReceiver _transport;
  final DirectLinkDriver _driver;
  final NetworkInfoService _networkInfo;
  final LocalHotspotService _hotspotService;
  final IsolatedQhtpReceiver _qhtpReceiver;

  StreamSubscription? _deviceSub;
  StreamSubscription? _bleProgressSub;
  StreamSubscription? _serveSub;
  Timer? _searchTimeout;
  bool _cancelled = false;
  bool _completed = false;
  bool _joinedAsGuest = false;
  int? _peerLinkPort;

  BluetoothReceiverSession({
    BleReceiver? transport,
    DirectLinkDriver? driver,
    NetworkInfoService? networkInfo,
    LocalHotspotService? hotspotService,
    IsolatedQhtpReceiver? qhtpReceiver,
  })  : _transport = transport ?? BluetoothReceiverTransport.forPlatform(),
        _driver = driver ?? LocalHotspotDriver(),
        _networkInfo = networkInfo ?? NetworkInfoService(),
        _hotspotService = hotspotService ?? LocalHotspotService(),
        _qhtpReceiver = qhtpReceiver ?? IsolatedQhtpReceiver();

  Future<BluetoothReceiverSessionResult> run({
    required String token,
    required String publicId,
    required ReceiveDestination destination,
    required void Function(int received, int total, String fileName) onProgress,
    required void Function() onVerifying,
  }) async {
    final completer = Completer<BluetoothReceiverSessionResult>();

    void fail(String message) {
      if (_completed || completer.isCompleted) return;
      _completed = true;
      _cleanup();
      completer.completeError(Exception(message));
    }

    _searchTimeout = Timer(const Duration(seconds: 25), () {
      fail('Timed out searching for sender. Make sure Bluetooth is enabled and sender is advertising.');
    });

    _deviceSub = _transport.devices.listen((device) async {
      _searchTimeout?.cancel();
      await _transport.stopScanning();
      if (_cancelled || _completed) return;

      AppLogger.info('BluetoothReceiverSession: connecting to ${device.name} (${device.id})', tag: 'BT_RECEIVER');

      _bleProgressSub = _transport.progressStream.listen((p) {
        if (_cancelled || _completed) return;
        if (p.phase == 'transferring') {
          onProgress(p.received, p.total, p.fileName);
        }
      });

      _serveSub = _transport.serveInfos.listen((serve) async {
        if (_cancelled || _completed) return;
        AppLogger.info('BluetoothReceiverSession: received serve frame on ${serve.ip}:${serve.port}', tag: 'BT_RECEIVER');
        try {
          final result = await _qhtpReceiver.downloadSession(
            payload: QRPayload(
              version: 2,
              ip: _peerLinkPort != null ? '127.0.0.1' : serve.ip,
              port: _peerLinkPort ?? serve.port,
              token: serve.token,
              sessionId: serve.token,
              mode: 'http-lan',
              tlsFingerprint: serve.tlsFingerprint,
            ),
            targetBaseDir: destination.path,
            onProgress: (qp) {
              if (_cancelled || _completed) return;
              if (qp.phase == 'verifying') {
                if (qp.itemCount <= 1 || qp.itemIndex >= qp.itemCount) {
                  onVerifying();
                }
              } else if (qp.phase == 'transferring') {
                onProgress(qp.sessionReceived, qp.sessionTotal, qp.itemPath);
              }
            },
          );

          if (_cancelled || _completed) return;
          _completed = true;
          _cleanup();

          result.fold(
            (failure) => fail(failure.message),
            (received) {
              final items = destination.placed
                  ? received.placedPaths
                      .map((p) => ReceivedItem.fromCacheFile(
                            File(p),
                            lookupMimeType(p) ?? 'application/octet-stream',
                          ))
                      .toList()
                  : TransferCache.itemsIn(Directory(destination.path));
              completer.complete(BluetoothReceiverSessionResult(
                preferredPath: received.preferredResultPath,
                displayName: items.length == 1 ? items.single.name : received.displayName,
                items: items,
                placed: destination.placed,
              ));
            },
          );
        } catch (e) {
          fail('Download failed: $e');
        }
      });

      try {
        final connectFuture = _transport.connect(
          device.id,
          token: token,
          targetDir: destination.path,
        );

        // Start direct link negotiation in parallel
        unawaited(() async {
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

          if (_cancelled || _completed) return;
          switch (outcome) {
            case DirectLinkUnavailable(message: final msg):
              AppLogger.info('DirectLink unavailable: $msg', tag: 'BT_RECEIVER');
            case DirectLinkOverPeerLink(localPort: final port):
              _peerLinkPort = port;
            case DirectLinkReady(hosting: final hosting):
              if (!hosting) {
                _joinedAsGuest = true;
              }
          }
        }());

        final path = await connectFuture;
        // If it resolved via legacy BLE:
        if (_completed || completer.isCompleted) return;
        _completed = true;
        _cleanup();
        final file = File(path);
        final items = [
          ReceivedItem.fromCacheFile(
            file,
            lookupMimeType(path) ?? 'application/octet-stream',
          )
        ];
        completer.complete(BluetoothReceiverSessionResult(
          preferredPath: path,
          displayName: file.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => 'file'),
          items: items,
          placed: destination.placed,
        ));
      } catch (e) {
        if (!_completed) {
          fail(e.toString());
        }
      }
    });

    try {
      await _transport.startScanning(sessionToken: token, publicId: publicId);
    } catch (e) {
      fail('Failed to start scanning for Bluetooth sender: $e');
    }

    return completer.future;
  }

  void _cleanup() {
    _searchTimeout?.cancel();
    _deviceSub?.cancel();
    _bleProgressSub?.cancel();
    _serveSub?.cancel();
    unawaited(_transport.stopScanning());
    if (_joinedAsGuest) {
      unawaited(_hotspotService.leaveNetwork());
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    _cleanup();
    await _transport.stopScanning();
  }
}

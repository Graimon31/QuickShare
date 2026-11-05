import 'dart:async';
import 'dart:io';

import 'package:mime/mime.dart';
import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/errors/failures.dart';
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

  /// How long the handshake with a sender that has been found may take. Finding
  /// the other device is bounded separately; this is the connect, the service
  /// discovery and the two subscriptions that follow it.
  final Duration _handshakeBudget;

  StreamSubscription? _deviceSub;
  StreamSubscription? _failureSub;
  StreamSubscription? _serveSub;
  Timer? _searchTimeout;
  bool _cancelled = false;
  bool _completed = false;
  bool _joinedAsGuest = false;
  bool _connecting = false;

  /// The serve frame has arrived: the file is on a Wi-Fi link and the radio has
  /// done what it is for. From here a dropped Bluetooth connection is nothing.
  bool _served = false;
  int? _peerLinkPort;

  BluetoothReceiverSession({
    BleReceiver? transport,
    DirectLinkDriver? driver,
    NetworkInfoService? networkInfo,
    LocalHotspotService? hotspotService,
    IsolatedQhtpReceiver? qhtpReceiver,
    Duration handshakeBudget = const Duration(seconds: 20),
  })  : _transport = transport ?? BluetoothReceiverTransport.forPlatform(),
        _driver = driver ?? LocalHotspotDriver(),
        _networkInfo = networkInfo ?? NetworkInfoService(),
        _hotspotService = hotspotService ?? LocalHotspotService(),
        _qhtpReceiver = qhtpReceiver ?? IsolatedQhtpReceiver(),
        _handshakeBudget = handshakeBudget;

  Future<BluetoothReceiverSessionResult> run({
    required String token,
    required String locator,
    required ReceiveDestination destination,
    required void Function(int received, int total, String fileName) onProgress,
    required void Function() onVerifying,
  }) async {
    final completer = Completer<BluetoothReceiverSessionResult>();

    // [code] is a [FailureCode], when the failure has one: it rides on the
    // error so the screen can say "the disk is full", or "the sending device
    // is on an older version", in the user's language instead of repeating a
    // sentence in English.
    void fail(String message, {String? code}) {
      // A session the person cancelled has nobody left to tell: cancelling the
      // radio below makes its pending connect fail, and that failure is the
      // cancellation arriving, not a second problem to report.
      if (_completed || completer.isCompleted || _cancelled) return;
      _completed = true;
      _cleanup();
      unawaited(_transport.cancel());
      completer.completeError(
          code == null ? Exception(message) : FileException(message, code));
    }

    _searchTimeout = Timer(const Duration(seconds: 25), () {
      fail('Timed out searching for sender. Make sure Bluetooth is enabled and sender is advertising.');
    });

    _deviceSub = _transport.devices.listen((device) async {
      _searchTimeout?.cancel();
      await _transport.stopScanning();
      // The first sender that matches is the one. A scan that repeats its
      // results must not start a second connection.
      if (_cancelled || _completed || _connecting) return;
      _connecting = true;
      unawaited(_deviceSub?.cancel());

      AppLogger.info('BluetoothReceiverSession: connecting to ${device.name} (${device.id})', tag: 'BT_RECEIVER');

      // Anything the radio reports before the serve frame ends the session:
      // the negotiation rides on it, and it cannot go on without it. After the
      // serve frame the file crosses Wi-Fi, so the radio dropping is not news.
      _failureSub = _transport.failures.listen((failure) {
        if (_served) return;
        fail(failure.message, code: failure.code);
      });

      _serveSub = _transport.serveInfos.listen((serve) async {
        if (_cancelled || _completed) return;
        _served = true;
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

          // A failed session still owes run() its ending: fail() refuses to
          // act once _completed is set, so marking completion before the fold
          // would leave the receive screen spinning on a future nobody
          // finishes. The failure branch must reach fail() with it unset.
          await result.fold(
            (failure) async => fail(failure.message,
                code: FailureCode.isStorage(failure.code) ? failure.code : null),
            (received) async {
              _completed = true;
              _cleanup();
              unawaited(_transport.cancel());
              try {
                final items = destination.placed
                    ? received.placedPaths
                        .map((p) => ReceivedItem.fromCacheFile(
                              File(p),
                              lookupMimeType(p) ?? 'application/octet-stream',
                            ))
                        .toList()
                    : await TransferCache.itemsIn(Directory(destination.path));
                if (!completer.isCompleted) {
                  completer.complete(BluetoothReceiverSessionResult(
                    preferredPath: received.preferredResultPath,
                    displayName: items.length == 1
                        ? items.single.name
                        : received.displayName,
                    items: items,
                    placed: destination.placed,
                  ));
                }
              } catch (e) {
                // fail() is out of reach by now — _completed is set — so the
                // future is ended here directly.
                if (!completer.isCompleted) {
                  completer.completeError(Exception('Download failed: $e'));
                }
              }
            },
          );
        } catch (e) {
          fail('Download failed: $e');
        }
      });

      try {
        await _transport
            .connect(device.id, token: token)
            .timeout(_handshakeBudget, onTimeout: () {
          throw TimeoutException(
              'The sending device did not complete the Bluetooth handshake '
              'within ${_handshakeBudget.inSeconds} seconds.');
        });
      } catch (e) {
        fail(e is TimeoutException
            ? (e.message ?? e.toString())
            : e.toString().replaceFirst('Exception: ', ''),
            code: e is TimeoutException ? FailureCode.linkPeerLost : null);
        return;
      }
      if (_cancelled || _completed) return;

      // The negotiation starts once the handshake is done, not beside it: its
      // first act is a write to the sender, and a write to a device whose
      // services are not discovered yet is a write that fails.
      unawaited(_negotiate(fail, locator));
    });

    try {
      await _transport.startScanning(sessionToken: token, locator: locator);
    } catch (e) {
      fail('Failed to start scanning for Bluetooth sender: $e');
    }

    return completer.future;
  }

  /// Settles with the sender which of them raises the Wi-Fi network, and
  /// joins or raises it. The file is pulled afterwards, when the serve frame
  /// says where.
  Future<void> _negotiate(
      void Function(String, {String? code}) fail, String locator) async {
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
      ).runReceiver(sessionId: locator);

      if (_cancelled || _completed) return;
      switch (outcome) {
        case DirectLinkUnavailable(message: final msg, code: final code):
          // No link, so no serve frame is coming. It used to be logged and the
          // screen sat there waiting for a transfer that could not start.
          AppLogger.info('DirectLink unavailable: $msg', tag: 'BT_RECEIVER');
          if (!_served) fail(msg, code: code);
        case DirectLinkOverPeerLink(localPort: final port):
          _peerLinkPort = port;
        case DirectLinkReady(hosting: final hosting):
          if (!hosting) {
            _joinedAsGuest = true;
          }
      }
    } catch (e) {
      if (!_served) fail('Could not set up the direct Wi-Fi link: $e');
    }
  }

  void _cleanup() {
    _searchTimeout?.cancel();
    _deviceSub?.cancel();
    _failureSub?.cancel();
    _serveSub?.cancel();
    unawaited(_transport.stopScanning());
    if (_joinedAsGuest) {
      unawaited(_hotspotService.leaveNetwork());
    }
  }

  /// Stops the session, and the radio under it.
  ///
  /// The radio is told separately because the native bridge keeps a connection
  /// of its own: stopping this object alone left it standing until something
  /// else happened to cancel it.
  Future<void> cancel() async {
    _cancelled = true;
    _cleanup();
    await _transport.stopScanning();
    await _transport.cancel();
  }
}

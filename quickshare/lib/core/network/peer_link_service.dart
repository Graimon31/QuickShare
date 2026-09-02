import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:quickshare/core/utils/app_logger.dart';

class PeerLinkException implements Exception {
  final String message;
  const PeerLinkException(this.message);
  @override
  String toString() => message;
}

/// A direct Wi-Fi link between two Apple devices, with no router involved.
///
/// This is a *link*, not a transport. QHTP already carries manifests, folders,
/// multi-file sessions, resume and checksums, and every bit of that is tested;
/// what it lacks on this pair is a network to run over. Neither iOS nor macOS
/// can raise a hotspot for the other — see [LocalHotspotService], where
/// `canHost` is Android-only — so an iPhone and a Mac with no shared Wi-Fi have
/// had nothing but Bluetooth, measured at 13 KB/s.
///
/// The native side brings up the same peer-to-peer Wi-Fi that AirDrop uses and
/// exposes it as an ordinary localhost port. The sender keeps serving QHTP on
/// its own port; the receiver points the existing QHTP client at the port
/// [join] hands back. Neither end knows the difference.
///
/// Apple only, and that is the point of it: this closes the one pair that
/// nothing else covers. Android hosts its own hotspot, Windows can be taught
/// to, and both of those any device can join.
class PeerLinkService {
  static const MethodChannel _defaultChannel =
      MethodChannel('quickshare/peerlink');
  static const EventChannel _defaultEvents =
      EventChannel('quickshare/peerlink/events');

  final MethodChannel _channel;
  final EventChannel _events;

  const PeerLinkService({MethodChannel? channel, EventChannel? events})
      : _channel = channel ?? _defaultChannel,
        _events = events ?? _defaultEvents;

  /// Whether this platform can take part in a peer-to-peer Wi-Fi link.
  static bool get isSupported =>
      !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  /// The name this session advertises under, derived from its own token.
  ///
  /// Nothing new goes in the QR code: both ends already hold the session
  /// token, so both can work out the same name without being told it. A
  /// prefix of it is enough to be unique among the handful of transfers
  /// within radio range, and short enough to stay well inside the 63 bytes a
  /// Bonjour instance name allows.
  static String serviceNameFor(String sessionToken) {
    final cleaned = sessionToken.replaceAll(RegExp('[^A-Za-z0-9]'), '');
    final stem = cleaned.length > 16 ? cleaned.substring(0, 16) : cleaned;
    return 'dd-$stem';
  }

  /// Progress and failures from the native side, for logging and the UI.
  Stream<Map<Object?, Object?>> get events => _events
      .receiveBroadcastStream()
      .map((event) => event as Map<Object?, Object?>);

  /// Announces this device under [serviceName] and forwards anything a peer
  /// sends to the QHTP server already listening on [localPort].
  ///
  /// Bounded by [timeout]: bringing up a listener is the work of a moment, and
  /// this is an optional extra route offered while the sender waits to show
  /// its QR code. A native side that never answers must cost that wait a few
  /// seconds, not the whole session — both callers treat a failure here as
  /// "no direct link this time" and carry on over the network.
  Future<void> host({
    required String serviceName,
    required int localPort,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _requireSupport();
    try {
      await _channel.invokeMethod<void>('host', {
        'serviceName': serviceName,
        'localPort': localPort,
      }).timeout(timeout);
      AppLogger.info('Peer link hosting as $serviceName -> :$localPort',
          tag: 'PEERLINK');
    } on TimeoutException {
      throw PeerLinkException(
          'hosting did not come up within ${timeout.inSeconds}s');
    } on PlatformException catch (e) {
      throw PeerLinkException(e.message ?? 'could not start hosting');
    } on MissingPluginException {
      throw const PeerLinkException(
          'peer-to-peer Wi-Fi is unavailable in this build');
    }
  }

  /// Finds [serviceName] and returns a localhost port that reaches it.
  ///
  /// The caller then talks to `127.0.0.1:<returned port>` exactly as it would
  /// talk to the sender directly.
  Future<int> join({
    required String serviceName,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    _requireSupport();
    try {
      final port = await _channel.invokeMethod<int>('join', {
        'serviceName': serviceName,
        'timeoutMs': timeout.inMilliseconds,
      });
      if (port == null || port <= 0) {
        throw const PeerLinkException('the link opened without a port');
      }
      AppLogger.info('Peer link joined $serviceName via 127.0.0.1:$port',
          tag: 'PEERLINK');
      return port;
    } on PlatformException catch (e) {
      throw PeerLinkException(e.message ?? 'could not reach the other device');
    } on MissingPluginException {
      throw const PeerLinkException(
          'peer-to-peer Wi-Fi is unavailable in this build');
    }
  }

  /// Whether a Wi-Fi path exists for the direct link to run over.
  ///
  /// Deliberately not "is the radio switched on": iOS has no public answer to
  /// that, and it is not quite the question anyway. What matters to a transfer
  /// is whether Wi-Fi can carry it — and if it cannot, the file goes over
  /// Bluetooth at a fraction of the speed, which is worth saying out loud
  /// before it happens rather than leaving as a mystery afterwards.
  Future<bool> get wifiReady async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('wifiReady') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Turns the Wi-Fi radio on, where the platform allows an app to.
  ///
  /// True only if it actually happened. macOS allows it and nothing is
  /// disturbed by doing so; iOS does not, at any price, so there the answer is
  /// always false and the caller should offer [openWifiSettings] instead.
  Future<bool> enableWifi() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('enableWifi') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the system settings, for the platforms that will not do it for us.
  Future<bool> openWifiSettings() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('openWifiSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      AppLogger.warning('Peer link would not stop cleanly: ${e.message}',
          tag: 'PEERLINK');
    } on MissingPluginException {
      // Nothing was ever started.
    }
  }

  void _requireSupport() {
    if (!isSupported) {
      throw const PeerLinkException(
          'peer-to-peer Wi-Fi exists only between Apple devices');
    }
  }
}

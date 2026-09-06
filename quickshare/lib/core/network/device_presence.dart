import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// This device, as the others on the network see it.
///
/// Wraps [LanDiscoveryService] with the answers to "who are we": a name worth
/// showing in a list, the platform, and an identifier stable enough that a
/// device heard twice is one row.
///
/// Kept apart from the discovery service because those are different
/// questions. The service moves datagrams; this decides what goes in them, and
/// that involves a hostname, a platform check and a random id — none of which
/// belong in something otherwise testable with no I/O at all.
class DevicePresence {
  final LanDiscoveryService _discovery;

  /// New every launch, deliberately.
  ///
  /// A persistent identifier would let anyone within radio range of two
  /// different networks tell that the same machine was on both. Nothing here
  /// needs that: the list only has to be stable while it is on screen, and a
  /// launch is far longer than that.
  final String _sessionId = _randomId();

  DiscoveryAnnouncement? _announcement;

  DevicePresence({LanDiscoveryService? discovery})
      : _discovery = discovery ?? LanDiscoveryService();

  Stream<List<DiscoveredPeer>> get peers => _discovery.peers;

  List<DiscoveredPeer> get current => _discovery.current;

  bool get isRunning => _discovery.isRunning;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// What this machine is called, as far as the network is concerned.
  ///
  /// `Platform.localHostname` is what the user named their machine, which is
  /// exactly what belongs in a list of devices — "Farman's MacBook" rather
  /// than a model number. Trailing `.local` comes off because Bonjour puts it
  /// there and nobody thinks of it as part of the name.
  ///
  /// A phone rarely has a useful hostname, so those fall back to the platform.
  static String describeThisDevice() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty && !Platform.isAndroid && !Platform.isIOS) {
        return host.replaceFirst(RegExp(r'\.local\.?$'), '');
      }
    } catch (_) {
      // Some sandboxes refuse the hostname. The platform name still tells the
      // other side something.
    }
    switch (Platform.operatingSystem) {
      case 'android':
        return 'Android device';
      case 'ios':
        return 'iPhone';
      case 'macos':
        return 'Mac';
      case 'windows':
        return 'Windows PC';
      case 'linux':
        return 'Linux PC';
      default:
        return 'Device';
    }
  }

  /// Starts announcing this device and listening for others.
  ///
  /// Returns false when the network will not carry it — guest Wi-Fi and
  /// captive portals block multicast — which is a fact the screen has to know,
  /// because an empty list then means "we cannot look here", not "nobody is
  /// nearby".
  Future<bool> start({String? name}) async {
    _announcement = DiscoveryAnnouncement(
      id: _sessionId,
      name: name ?? describeThisDevice(),
      platform: Platform.operatingSystem,
    );
    final started = await _discovery.start(_announcement!);
    if (!started) {
      AppLogger.info(
          'Not announcing on this network — the QR path still works',
          tag: 'DISCOVERY');
    }
    return started;
  }

  /// Says that this device is now serving a session, so the others can dial
  /// it without being told separately.
  void nowServing({required int port, required String tlsFingerprint}) {
    final current = _announcement;
    if (current == null) return;
    _announcement = DiscoveryAnnouncement(
      id: current.id,
      name: current.name,
      platform: current.platform,
      port: port,
      tlsFingerprint: tlsFingerprint,
    );
    _discovery.update(_announcement!);
  }

  /// Says the session is over. The device stays listed, just not as serving.
  void noLongerServing() {
    final current = _announcement;
    if (current == null || current.port == 0) return;
    _announcement = DiscoveryAnnouncement(
      id: current.id,
      name: current.name,
      platform: current.platform,
    );
    _discovery.update(_announcement!);
  }

  Future<void> stop() async {
    await _discovery.stop();
    _announcement = null;
  }

  Future<void> dispose() async {
    await _discovery.dispose();
    _announcement = null;
  }
}

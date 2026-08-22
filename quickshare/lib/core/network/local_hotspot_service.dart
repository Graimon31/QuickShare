import 'dart:io';

import 'package:flutter/services.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// Credentials for a temporary Wi-Fi network raised by the sender.
///
/// This is the way out of [NetworkFallbackPage]: when a VPN or a symmetric NAT
/// kills the internet path, the two devices build their own network instead of
/// arguing with somebody else's. QHTP then runs over it at full link speed with
/// no size cap, because nothing leaves the room.
class HotspotCredentials {
  final String ssid;
  final String passphrase;

  /// Address the QHTP server must bind to and the receiver must dial. Read
  /// from the live interface rather than assumed: the 192.168.43.1 that gets
  /// quoted everywhere is the *tethering* address, and a local-only hotspot
  /// does not necessarily use it.
  final String? hostAddress;

  const HotspotCredentials({
    required this.ssid,
    required this.passphrase,
    this.hostAddress,
  });

  factory HotspotCredentials.fromMap(Map<Object?, Object?> map) {
    final ssid = map['ssid'] as String?;
    final passphrase = map['passphrase'] as String?;
    if (ssid == null || ssid.isEmpty) {
      throw const HotspotException('the platform returned a hotspot with no SSID');
    }
    return HotspotCredentials(
      ssid: ssid,
      passphrase: passphrase ?? '',
      hostAddress: map['hostAddress'] as String?,
    );
  }

  HotspotCredentials withHost(String? address) => HotspotCredentials(
        ssid: ssid,
        passphrase: passphrase,
        hostAddress: address ?? hostAddress,
      );

  /// The standard `WIFI:` payload every phone camera understands, so a
  /// receiver without the app installed can still join the network.
  String toWifiQrPayload() {
    String escape(String value) => value.replaceAllMapped(
        RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');
    return 'WIFI:T:WPA;S:${escape(ssid)};P:${escape(passphrase)};;';
  }

  @override
  String toString() => 'HotspotCredentials($ssid, host: $hostAddress)';
}

class HotspotException implements Exception {
  final String message;
  const HotspotException(this.message);
  @override
  String toString() => message;
}

/// Raising a hotspot is not something Flutter can do, and the two platforms
/// that matter can do opposite halves of it:
///
/// * Android can *create* a local-only hotspot from API 26 and hand back the
///   generated SSID and passphrase.
/// * iOS cannot create one programmatically at all, but it can *join* one
///   through NEHotspotConfiguration, with a system prompt.
///
/// So the host is always the Android or desktop side, and the iPhone is always
/// the guest. iPhone-to-iPhone is not reachable this way — that pair needs
/// Personal Hotspot turned on by hand.
class LocalHotspotService {
  static const MethodChannel _channel =
      MethodChannel('quickshare/hotspot');

  final MethodChannel _methodChannel;

  LocalHotspotService({MethodChannel? channel})
      : _methodChannel = channel ?? _channel;

  /// True when this platform can raise a network for the other device.
  bool get canHost => Platform.isAndroid;

  /// True when this platform can join one from inside the app.
  bool get canJoinProgrammatically => Platform.isAndroid || Platform.isIOS;

  /// Raises a local-only hotspot and returns its credentials.
  ///
  /// The network carries no internet connection, which is the point: Android
  /// keeps mobile data alive on its own interface while the Wi-Fi radio serves
  /// the guest.
  Future<HotspotCredentials> startHosting() async {
    if (!canHost) {
      throw HotspotException(
          '${Platform.operatingSystem} cannot create a hotspot from inside an '
          'app; the other device has to host');
    }
    try {
      final result =
          await _methodChannel.invokeMethod<Map<Object?, Object?>>('startHotspot');
      if (result == null) {
        throw const HotspotException('the platform returned no hotspot details');
      }
      final credentials = HotspotCredentials.fromMap(result)
          .withHost(await awaitHotspotAddress());
      AppLogger.info('Local hotspot up: $credentials', tag: 'HOTSPOT');
      return credentials;
    } on PlatformException catch (e) {
      throw HotspotException(e.message ?? 'could not start the hotspot');
    }
  }

  Future<void> stopHosting() async {
    if (!canHost) return;
    try {
      await _methodChannel.invokeMethod<void>('stopHotspot');
    } on PlatformException catch (e) {
      AppLogger.warning('Stopping the hotspot failed: ${e.message}',
          tag: 'HOTSPOT');
    }
  }

  /// Joins [credentials] from the guest side.
  ///
  /// On iOS this raises the system "Join network?" prompt and needs the
  /// `com.apple.developer.networking.HotspotConfiguration` entitlement; without
  /// it the call fails at runtime rather than at build time.
  Future<void> join(HotspotCredentials credentials) async {
    try {
      await _methodChannel.invokeMethod<void>('joinHotspot', {
        'ssid': credentials.ssid,
        'passphrase': credentials.passphrase,
      });
      AppLogger.info('Joined ${credentials.ssid}', tag: 'HOTSPOT');
    } on PlatformException catch (e) {
      throw HotspotException(e.message ?? 'could not join ${credentials.ssid}');
    }
  }

  /// Waits for the hotspot interface to be assigned an address.
  ///
  /// The callback that says the hotspot started fires before the interface has
  /// an address on it — the kernel brings the link up and the address arrives a
  /// few hundred milliseconds later. Reading once at that moment usually
  /// returns nothing, and a QR code built from nothing points nowhere, so this
  /// polls instead of sampling.
  ///
  /// Note that the file server itself needs no restart: it binds
  /// `InternetAddress.anyIPv4`, so it is already listening on the hotspot
  /// interface the moment that interface exists. Only the address printed into
  /// the QR code has to wait.
  Future<String?> awaitHotspotAddress({
    int attempts = 15,
    Duration interval = const Duration(milliseconds: 200),
  }) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      final address = await _resolveHotspotAddress();
      if (address != null) {
        AppLogger.info(
            'Hotspot address $address appeared after '
            '${attempt * interval.inMilliseconds} ms',
            tag: 'HOTSPOT');
        return address;
      }
      await Future<void>.delayed(interval);
    }
    AppLogger.warning(
        'No hotspot address after ${attempts * interval.inMilliseconds} ms',
        tag: 'HOTSPOT');
    return null;
  }

  /// One look at the interface list. See [awaitHotspotAddress] for why callers
  /// should not rely on a single look.
  ///
  /// Enumerated rather than hardcoded. Vendors differ on both the interface
  /// name (`ap0`, `wlan1`, `swlan0`) and the subnet, and a wrong guess here
  /// produces a QR code pointing at an address nobody is listening on.
  Future<String?> _resolveHotspotAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        final looksLikeAccessPoint = name.startsWith('ap') ||
            name.startsWith('swlan') ||
            name.startsWith('wlan1');
        if (!looksLikeAccessPoint) continue;
        for (final address in interface.addresses) {
          if (!address.isLinkLocal) return address.address;
        }
      }
      return null;
    } catch (e) {
      AppLogger.warning('Could not enumerate interfaces: $e', tag: 'HOTSPOT');
      return null;
    }
  }
}

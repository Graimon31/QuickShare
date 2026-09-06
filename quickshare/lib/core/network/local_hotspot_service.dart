import 'dart:io';

import 'package:flutter/services.dart';

import 'package:quickshare/core/network/linux_hotspot.dart';
import 'package:quickshare/core/network/session_code.dart';
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
      throw const HotspotException(
          'the platform returned a hotspot with no SSID');
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
    String escape(String value) =>
        value.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');
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
  static const MethodChannel _channel = MethodChannel('quickshare/hotspot');

  final MethodChannel _methodChannel;

  /// Linux is driven through NetworkManager rather than a native plugin —
  /// see [LinuxHotspot] for why.
  final LinuxHotspot _linux;

  LocalHotspotService({MethodChannel? channel, LinuxHotspot? linux})
      : _methodChannel = channel ?? _channel,
        _linux = linux ?? LinuxHotspot();

  /// True when this platform can raise a network for the other device.
  ///
  /// A platform answer, not a hardware one: on Linux plenty of adapters cannot
  /// act as an access point at all, and only the driver knows. [startHosting]
  /// asks it there and refuses with something the user can act on, because
  /// that question needs a process to answer and this getter has to be cheap
  /// enough to call while drawing a screen.
  bool get canHost => Platform.isAndroid || Platform.isLinux;

  /// True when this platform can join one from inside the app.
  ///
  /// macOS belongs here as much as iOS does — `CWInterface.associate` is
  /// public API and has been for years — and leaving it out is what made a Mac
  /// look like it could not take part in a transfer where the other device
  /// raises the network. It cannot *host* one, which is a different question
  /// and the one [canHost] answers.
  bool get canJoinProgrammatically =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// True when this platform can list the networks around it.
  ///
  /// This is how two desktops find each other with no camera between them: a
  /// host's network is in the air before anyone joins it, so the other side can
  /// show the `DirectDrop-…` networks as devices. iOS has no API for the list
  /// at all — an iPhone always has a camera, so it scans a QR instead.
  bool get canScanForNetworks =>
      Platform.isMacOS || Platform.isAndroid || Platform.isWindows ||
      Platform.isLinux;

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
    if (Platform.isLinux) return _startHostingOnLinux();

    try {
      final result = await _methodChannel
          .invokeMethod<Map<Object?, Object?>>('startHotspot');
      if (result == null) {
        throw const HotspotException(
            'the platform returned no hotspot details');
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
    if (Platform.isLinux) return _linux.stop();
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
  /// it the call fails at runtime rather than at build time. On macOS it goes
  /// through CoreWLAN and needs no prompt, but does leave the Mac off whatever
  /// network it was on — [stopHosting] puts it back.
  Future<void> join(HotspotCredentials credentials) async {
    if (Platform.isLinux) {
      try {
        await _linux.join(
          ssid: credentials.ssid,
          passphrase: credentials.passphrase,
        );
        AppLogger.info('Joined ${credentials.ssid}', tag: 'HOTSPOT');
        return;
      } on HotspotCommandException catch (e) {
        throw HotspotException(e.message);
      }
    }

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

  /// The networks in range whose name starts with [prefix].
  ///
  /// Empty rather than throwing when the platform cannot scan: a caller that
  /// has to draw a list wants an empty list, and "this platform has no API for
  /// it" is not a failure the user did anything to cause. A refusal by the
  /// system — Location Services on macOS 14 and later — does throw, because
  /// that one the user can act on.
  Future<List<String>> scanForNetworks({String? prefix}) async {
    if (!canScanForNetworks) return const [];
    if (Platform.isLinux) {
      try {
        return await _linux.scan(prefix: prefix);
      } on HotspotCommandException catch (e) {
        throw HotspotException(e.message);
      }
    }
    try {
      final found = await _methodChannel.invokeMethod<List<Object?>>(
        'scanForNetworks',
        {if (prefix != null) 'prefix': prefix},
      );
      return [
        for (final entry in found ?? const []) if (entry is String) entry,
      ];
    } on MissingPluginException {
      // A platform whose bridge is not built yet.
      return const [];
    } on PlatformException catch (e) {
      throw HotspotException(e.message ?? 'could not scan for networks');
    }
  }

  /// Whether the system will let this app look at nearby networks.
  ///
  /// 'granted', 'denied', 'restricted', 'notDetermined', or 'unavailable' on
  /// platforms that do not gate it. Only macOS 14 and later actually withholds
  /// this, and it does so silently — an unauthorised scan returns an empty
  /// list rather than an error — so a caller that draws "no devices found"
  /// has to ask this before believing it.
  Future<String> locationAuthorization() async {
    if (!Platform.isMacOS) return 'unavailable';
    try {
      return await _methodChannel.invokeMethod<String>('locationAuthorization') ??
          'unknown';
    } on MissingPluginException {
      return 'unavailable';
    } on PlatformException {
      return 'unknown';
    }
  }

  /// Asks for the access [locationAuthorization] reports on.
  ///
  /// Returns the state afterwards, which is 'notDetermined' while the system
  /// prompt is still on screen — the answer arrives later, so a caller should
  /// re-read rather than treat this as final.
  Future<String> requestLocationAccess() async {
    if (!Platform.isMacOS) return 'unavailable';
    try {
      return await _methodChannel.invokeMethod<String>('requestLocationAccess') ??
          'unknown';
    } on MissingPluginException {
      return 'unavailable';
    } on PlatformException {
      return 'unknown';
    }
  }

  /// The network this device is on, or null when it is on none.
  ///
  /// Recorded before joining a transfer network so the device can be put back
  /// afterwards: joining means leaving whatever had the internet on it, and
  /// leaving somebody stranded there with no explanation is worse than the
  /// transfer was good.
  Future<String?> currentSsid() async {
    if (Platform.isLinux) return _linux.currentSsid();

    try {
      return await _methodChannel.invokeMethod<String>('currentSsid');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Raises the network through NetworkManager, having first asked the driver
  /// whether it can.
  ///
  /// The capability check is here rather than in [canHost] because it costs a
  /// process, and because failing at this point can say what is wrong: an
  /// adapter with no AP mode is a fact about the hardware, and telling someone
  /// to host from the other device is more use than "could not create
  /// network".
  Future<HotspotCredentials> _startHostingOnLinux() async {
    if (!await _linux.isAvailable) {
      throw const HotspotException(
          'NetworkManager is not running, so this machine cannot create a '
          'network. The other device can host instead.');
    }
    if (!await _linux.canHost) {
      throw const HotspotException(
          "This machine's Wi-Fi adapter cannot act as an access point. The "
          'other device has to create the network.');
    }

    // Both halves come from a session code, which is the point of having one:
    // the far side derives the same pair from the code it was shown, so
    // nothing about the network has to be transmitted. `startHosting` does not
    // take the code yet — the sender still has to thread it through — so one
    // is minted here and its name and passphrase used.
    final code = SessionCode.generate();
    final credentials = HotspotCredentials(
      ssid: code.ssid,
      passphrase: code.passphrase,
    );

    try {
      await _linux.start(
        ssid: credentials.ssid,
        passphrase: credentials.passphrase,
      );
    } on HotspotCommandException catch (e) {
      throw HotspotException(e.message);
    }

    return credentials.withHost(await awaitHotspotAddress());
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

import 'dart:async';
import 'dart:io';
import 'package:network_info_plus/network_info_plus.dart';

import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/utils/app_logger.dart';

class NetworkInfoService {
  final NetworkInfo _networkInfo = NetworkInfo();

  static const List<String> _ignoredInterfaces = [
    'utun',
    'tun',
    'tap',
    'wg',
    'tailscale',
    'zerotier',
    'docker',
    'vboxnet',
    'bridge',
    'vmnet',
    'ppp',
    'clash',
    'sing-box',
    'v2ray',
    'awdl',
    'llw',
    'ap'
  ];

  /// How long the platform gets to answer "what is the Wi-Fi address".
  ///
  /// On the other side of this method channel are two syscalls; it answers in
  /// single-digit milliseconds or it does not answer at all, and nothing here
  /// can make it. Unbounded, it was the one wait on the path between choosing
  /// files and the QR appearing that could last forever — a sender left on
  /// "indexing" with no work happening anywhere in the process, because a
  /// plugin reply never arrived. The interface enumeration below answers the
  /// same question locally in about two milliseconds, so falling through to it
  /// costs the transfer nothing.
  static const Duration _pluginAnswerBudget = Duration(seconds: 2);

  Future<String?> _wifiIpFromPlugin() async {
    try {
      return await _networkInfo.getWifiIP().timeout(_pluginAnswerBudget);
    } on TimeoutException {
      AppLogger.warning(
          'The Wi-Fi address lookup did not answer within '
          '${_pluginAnswerBudget.inSeconds}s — reading the interface list '
          'instead',
          tag: 'NET');
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> getLocalIpAddress() async {
    final wifiIp = await _wifiIpFromPlugin();
    if (wifiIp != null && _isValidPrivateIp(wifiIp)) {
      return wifiIp;
    }

    // Fallback for Desktop / Ethernet / Multiple Interfaces
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      // Sort interfaces so primary Wi-Fi / Ethernet network adapters (en0, en1, wlan0, eth0) are prioritized
      interfaces.sort((a, b) {
        final aName = a.name.toLowerCase();
        final bName = b.name.toLowerCase();
        if (aName == 'en0' || aName == 'wlan0') return -1;
        if (bName == 'en0' || bName == 'wlan0') return 1;
        if (aName.startsWith('en') ||
            aName.startsWith('wlan') ||
            aName.startsWith('eth')) {
          return -1;
        }
        if (bName.startsWith('en') ||
            bName.startsWith('wlan') ||
            bName.startsWith('eth')) {
          return 1;
        }
        return 0;
      });

      String? bestFallback;

      for (final interface in interfaces) {
        final lowerName = interface.name.toLowerCase();
        if (_ignoredInterfaces.any((ignored) => lowerName.contains(ignored))) {
          continue;
        }

        for (final addr in interface.addresses) {
          final ip = addr.address;
          if (_isValidPrivateIp(ip)) {
            return ip; // Return true private LAN IPv4 (e.g. 192.168.x.x / 10.x.x.x)
          } else if (!_isIgnoredIp(ip) && bestFallback == null) {
            bestFallback = ip;
          }
        }
      }

      if (bestFallback != null) return bestFallback;
    } catch (_) {}

    return null;
  }

  bool _isValidPrivateIp(String ip) {
    if (_isIgnoredIp(ip)) return false;
    final parts = ip.split('.').map((e) => int.tryParse(e) ?? -1).toList();
    if (parts.length != 4 || parts.any((p) => p < 0 || p > 255)) return false;

    // 192.168.0.0/16
    if (parts[0] == 192 && parts[1] == 168) return true;
    // 10.0.0.0/8
    if (parts[0] == 10) return true;
    // 172.16.0.0/12
    if (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) return true;

    return false;
  }

  bool _isIgnoredIp(String ip) {
    return ip.isEmpty ||
        ip == '0.0.0.0' ||
        ip.startsWith('127.') ||
        ip.startsWith(
            '198.18.') || // Synthetic Proxy / VPN benchmark (RFC 2544)
        ip.startsWith('169.254.'); // Link-local
  }

  Future<bool> isConnectedToWifi() async {
    try {
      final ip = await getLocalIpAddress();
      return ip != null && ip.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Whether the "Wi-Fi / Local Network" transport has anything to run over.
  ///
  /// On mobile this must be a real Wi-Fi address: iOS hands the cellular
  /// interface carrier-NAT IPv4s from 10.0.0.0/8, which the generic fallback
  /// in [getLocalIpAddress] cannot tell apart from a LAN. On desktop an
  /// Ethernet-only machine is a perfectly good LAN peer, so any usable local
  /// address passes there.
  Future<bool> hasWifiTransportNetwork() async {
    if (Platform.isIOS || Platform.isAndroid) {
      // Three ways of asking, because one plugin call answering "no" is not
      // the same fact as there being no Wi-Fi.
      //
      // Hanging the whole decision on it is what put a "turn Wi-Fi on"
      // dialog in front of people whose Wi-Fi was plainly on: the call can
      // time out, and on iOS it can also answer about the wrong interface
      // once the app's own peer-to-peer link has brought `awdl0` up beside
      // `en0`. Any one of the three saying yes is enough — none of them can
      // say yes when there is genuinely no Wi-Fi.
      final wifiIp = await _wifiIpFromPlugin();
      if (wifiIp != null && _isValidPrivateIp(wifiIp)) return true;
      if (await _hasPrivateAddressOnWifiInterface()) return true;
      return _systemSaysWifiIsUsable();
    }
    return isConnectedToWifi();
  }

  /// A real LAN address on an interface that is the Wi-Fi one.
  ///
  /// By name, deliberately: `getLocalIpAddress`'s generic sweep cannot be
  /// used here because iOS hands the cellular interface carrier-NAT
  /// addresses out of 10.0.0.0/8, which look exactly like a home LAN. The
  /// name does not — Wi-Fi is `en*` on iOS and `wlan*` on Android, while
  /// cellular is `pdp_ip*` and `rmnet*` — so this tells the two apart where
  /// the address alone cannot. Tunnels, AWDL and the rest stay excluded by
  /// [_ignoredInterfaces].
  Future<bool> _hasPrivateAddressOnWifiInterface() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (_ignoredInterfaces.any((ignored) => name.contains(ignored))) {
          continue;
        }
        if (!name.startsWith('en') && !name.startsWith('wlan')) continue;
        for (final address in interface.addresses) {
          if (_isValidPrivateIp(address.address)) return true;
        }
      }
    } catch (_) {
      // An interface list this platform will not give up says nothing either
      // way; the last check decides.
    }
    return false;
  }

  /// Apple's own answer to "is there a usable Wi-Fi path right now".
  ///
  /// `NWPathMonitor` needs no address and no permission, and it is the same
  /// signal the system uses itself. Only Apple platforms answer; everywhere
  /// else this is simply not available and the checks above stand alone.
  Future<bool> _systemSaysWifiIsUsable() async {
    if (!PeerLinkService.isSupported) return false;
    try {
      return await const PeerLinkService().wifiReady;
    } catch (_) {
      return false;
    }
  }

  /// Any active network connection at all, cellular included — the bar the
  /// Internet transport has to clear.
  Future<bool> hasAnyActiveConnection() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        final lowerName = interface.name.toLowerCase();
        if (_ignoredInterfaces.any((ignored) => lowerName.contains(ignored))) {
          continue;
        }
        for (final addr in interface.addresses) {
          if (!_isIgnoredIp(addr.address)) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<bool> isOnSameNetwork(String targetIp) async {
    final localIp = await getLocalIpAddress();
    if (localIp == null || targetIp.isEmpty) return false;

    final localParts = localIp.split('.');
    final targetParts = targetIp.split('.');

    if (localParts.length != 4 || targetParts.length != 4) return false;

    return localParts.take(3).join('.') == targetParts.take(3).join('.');
  }
}

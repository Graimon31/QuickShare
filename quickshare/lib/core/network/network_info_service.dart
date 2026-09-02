import 'dart:async';
import 'dart:io';
import 'package:network_info_plus/network_info_plus.dart';

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
      final wifiIp = await _wifiIpFromPlugin();
      return wifiIp != null && _isValidPrivateIp(wifiIp);
    }
    return isConnectedToWifi();
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

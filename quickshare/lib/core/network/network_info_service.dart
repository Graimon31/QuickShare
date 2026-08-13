import 'dart:io';
import 'package:network_info_plus/network_info_plus.dart';

class NetworkInfoService {
  final NetworkInfo _networkInfo = NetworkInfo();

  static const List<String> _ignoredInterfaces = [
    'utun', 'tun', 'tap', 'wg', 'tailscale', 'zerotier', 'docker', 'vboxnet',
    'bridge', 'vmnet', 'ppp', 'clash', 'sing-box', 'v2ray', 'awdl', 'llw', 'ap'
  ];

  Future<String?> getLocalIpAddress() async {
    try {
      final wifiIp = await _networkInfo.getWifiIP();
      if (wifiIp != null && _isValidPrivateIp(wifiIp)) {
        return wifiIp;
      }
    } catch (_) {}

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
        if (aName.startsWith('en') || aName.startsWith('wlan') || aName.startsWith('eth')) return -1;
        if (bName.startsWith('en') || bName.startsWith('wlan') || bName.startsWith('eth')) return 1;
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
        ip.startsWith('198.18.') || // Synthetic Proxy / VPN benchmark (RFC 2544)
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

  Future<bool> isOnSameNetwork(String targetIp) async {
    final localIp = await getLocalIpAddress();
    if (localIp == null || targetIp.isEmpty) return false;

    final localParts = localIp.split('.');
    final targetParts = targetIp.split('.');
    
    if (localParts.length != 4 || targetParts.length != 4) return false;
    
    return localParts.take(3).join('.') == targetParts.take(3).join('.');
  }
}

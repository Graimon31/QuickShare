import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/network/upnp_port_forwarder.dart';

/// Zero-config auto-tunneling and NAT-traversal service.
/// Enables 100% serverless end-to-end internet connections between sender
/// and receiver across different networks (e.g. LTE ↔ Wi-Fi).
class AutoTunnelService {
  static final AutoTunnelService _instance = AutoTunnelService._internal();
  factory AutoTunnelService() => _instance;
  AutoTunnelService._internal();

  final NetworkInfoService _networkInfo = NetworkInfoService();
  final UpnpPortForwarder _upnpForwarder = UpnpPortForwarder();
  String? _cachedPublicIp;

  /// Attempts to discover the sender's public IPv4 address using public STUN/HTTP endpoints.
  Future<String?> getPublicIpAddress() async {
    if (_cachedPublicIp != null) return _cachedPublicIp;

    final endpoints = [
      'https://api.ipify.org',
      'https://icanhazip.com',
      'https://ifconfig.me/ip',
    ];

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);

    for (final url in endpoints) {
      try {
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        if (res.statusCode == 200) {
          final body = await res.transform(utf8.decoder).join();
          final ip = body.trim();
          if (_isValidPublicIp(ip)) {
            _cachedPublicIp = ip;
            client.close();
            return ip;
          }
        }
      } catch (_) {}
    }

    client.close();
    return null;
  }

  /// Checks if [url] contains a private RFC 1918 IPv4 address (192.168.x.x, 10.x.x.x, 172.16.x.x).
  static bool isPrivateLanUrl(String url) {
    if (url.contains('localhost') || url.contains('127.0.0.1')) return true;
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    if (host.isEmpty) return false;

    final parts = host.split('.').map((e) => int.tryParse(e) ?? -1).toList();
    if (parts.length != 4) return false;

    if (parts[0] == 192 && parts[1] == 168) return true;
    if (parts[0] == 10) return true;
    if (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) return true;

    return false;
  }

  /// Explicitly checks whether UPnP/NAT-PMP port forwarding succeeded.
  Future<PortMappingResult> checkServerlessReachability({int localPort = 3000}) async {
    try {
      final upnpResult = await _upnpForwarder.forwardPort(internalPort: localPort);
      if (upnpResult.success) {
        return upnpResult;
      }
    } catch (e) {
      debugPrint('UPnP reachability check error: $e');
    }
    return const PortMappingResult(
      success: false,
      method: 'none',
      error: 'UPnP unavailable (Double NAT / strict network)',
    );
  }

  /// Generates a peer-reachable signaling URL for the receiver, attempting UPnP/NAT-PMP
  /// port mapping to obtain a public Internet-reachable endpoint.
  Future<String> resolveReachableSignalingUrl(String configuredUrl, {int localPort = 3000}) async {
    final rawUrl = configuredUrl.trim();
    if (rawUrl.isNotEmpty && !isPrivateLanUrl(rawUrl)) {
      return rawUrl;
    }

    // 1. Attempt UPnP/NAT-PMP port mapping for serverless public reachability
    try {
      final upnpResult = await _upnpForwarder.forwardPort(internalPort: localPort);
      if (upnpResult.success && upnpResult.publicIp != null) {
        final scheme = rawUrl.startsWith('wss://') ? 'wss://' : 'ws://';
        final mappedPort = upnpResult.externalPort ?? localPort;
        return '$scheme${upnpResult.publicIp}:$mappedPort';
      }
    } catch (e) {
      debugPrint('AutoTunnelService UPnP forward failed: $e');
    }

    // 2. Try Public IP if STUN / WAN IP is known
    final publicIp = await getPublicIpAddress();
    if (publicIp != null && publicIp.isNotEmpty) {
      final scheme = rawUrl.startsWith('wss://') ? 'wss://' : 'ws://';
      return '$scheme$publicIp:$localPort';
    }

    // 3. Fallback to LAN IP
    final lanIp = await _networkInfo.getLocalIpAddress();
    if (lanIp != null && lanIp.isNotEmpty) {
      final scheme = rawUrl.startsWith('wss://') ? 'wss://' : 'ws://';
      return '$scheme$lanIp:$localPort';
    }

    return rawUrl.isEmpty ? 'ws://localhost:$localPort' : rawUrl;
  }

  bool _isValidPublicIp(String ip) {
    final parts = ip.split('.').map((e) => int.tryParse(e) ?? -1).toList();
    if (parts.length != 4 || parts.any((p) => p < 0 || p > 255)) return false;

    if (parts[0] == 192 && parts[1] == 168) return false;
    if (parts[0] == 10) return false;
    if (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) return false;
    if (parts[0] == 127) return false;
    if (parts[0] == 169 && parts[1] == 254) return false;

    return true;
  }
}

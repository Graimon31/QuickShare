import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/turn_credential_service.dart';

/// Builds the `iceServers` list both peers hand to WebRTC.
///
/// Lived in duplicate inside the sender and receiver transports, where the two
/// copies had already started to drift. One list, one ordering, one place to
/// change when a host dies — and the last one did die: the previous default
/// `openrelay.metered.ca` stopped resolving entirely.
///
/// Ordering matters more than it looks. On the target setup a split-tunnel VPN
/// holds the default route, and under it UDP to 3478 is unreliable while
/// TCP/TLS to 443 is exactly what the tunnel is built to carry. So relay
/// transports are offered 443-first, and plain UDP comes last rather than
/// first.
class IceServers {
  const IceServers._();

  /// Credentials never appear here as literals — they come from
  /// `--dart-define` (or CI secrets) through [AppConstants], so a build can be
  /// pointed at a private TURN account without touching this file.
  static List<Map<String, dynamic>> build({
    List<String>? stunUrls,
    List<String>? turnUrls,
    String? username,
    String? credential,
  }) {
    final servers = <Map<String, dynamic>>[
      for (final url in stunUrls ?? AppConstants.stunServers) {'urls': url},
    ];

    final user = username ?? AppConstants.turnUsername;
    final secret = credential ?? AppConstants.turnCredential;

    for (final url in turnUrls ?? AppConstants.turnServerUrls) {
      if (url.trim().isEmpty) continue;
      final entry = <String, dynamic>{'urls': url.trim()};
      if (user.isNotEmpty) entry['username'] = user;
      if (secret.isNotEmpty) entry['credential'] = secret;
      servers.add(entry);
    }

    return servers;
  }

  static Map<String, dynamic> configuration({
    List<String>? stunUrls,
    List<String>? turnUrls,
    String? username,
    String? credential,
  }) =>
      {
        'iceServers': build(
          stunUrls: stunUrls,
          turnUrls: turnUrls,
          username: username,
          credential: credential,
        ),
        // 'all' rather than 'relay': a direct path is still preferable when it
        // exists, and it is free.
        'iceTransportPolicy': 'all',
      };

  /// Same shape as [configuration], but tries the Worker's `/turn` endpoint
  /// for short-lived credentials first (ТЗ v2.0 §3) and only falls back to
  /// the static, build-time [configuration] if that fails or no Worker is
  /// configured at all.
  ///
  /// This does not refresh mid-session — the credentials returned are good
  /// for the Worker's TTL (30 min), and rotating them into a live
  /// `RTCPeerConnection` via `setConfiguration()` before they expire (ТЗ v2.0
  /// §9) is a separate piece of work, not yet wired in.
  static Future<Map<String, dynamic>> configurationDynamic({
    String? workerBaseUrl,
  }) async {
    final url = workerBaseUrl ?? AppConstants.workerBaseUrl;
    if (url.trim().isEmpty) return configuration();

    try {
      final dynamicTurnServers =
          await TurnCredentialService(baseUrl: url).fetchIceServers();

      // The Worker hands back its own STUN entry, which overlaps the static
      // pool — `stun.cloudflare.com` is in both. A duplicate is not harmless
      // here: every extra STUN URL is another query inside the 6-second
      // gathering ceiling that a relay candidate is already competing for.
      final seen = stunUrlsIn(dynamicTurnServers);

      return {
        'iceServers': [
          for (final stunUrl in AppConstants.stunServers)
            if (!seen.contains(stunUrl)) {'urls': stunUrl},
          ...dynamicTurnServers,
        ],
        'iceTransportPolicy': 'all',
      };
    } catch (e) {
      AppLogger.warning(
          'Worker TURN credential fetch failed, falling back to static '
          'config: $e',
          tag: 'WEBRTC');
      return configuration();
    }
  }

  /// Every STUN URL already present in [servers], flattened: the `urls` field
  /// is a list in what the Worker returns but a bare string elsewhere, and
  /// both spellings are legal WebRTC.
  static Set<String> stunUrlsIn(List<Map<String, dynamic>> servers) {
    final urls = <String>{};
    for (final server in servers) {
      final raw = server['urls'];
      if (raw is String) {
        urls.add(raw);
      } else if (raw is List) {
        urls.addAll(raw.whereType<String>());
      }
    }
    return urls;
  }

  /// Expands one base TURN host into the transports worth trying, best first.
  ///
  /// `turn:host:3478` becomes TCP on 443, TLS on 443, TCP on 80, then plain
  /// UDP. A host that already carries a scheme, a port or a `transport=`
  /// parameter is taken as written — an operator who spelled it out means it.
  static List<String> expandTransports(String base) {
    final trimmed = base.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.contains('transport=') || trimmed.startsWith('turns:')) {
      return [trimmed];
    }

    final withoutScheme = trimmed.replaceFirst(RegExp(r'^turns?:'), '');
    final host = withoutScheme.split(':').first.split('?').first;
    if (host.isEmpty) return [trimmed];

    return [
      'turn:$host:443?transport=tcp',
      'turns:$host:443?transport=tcp',
      'turn:$host:80?transport=tcp',
      'turn:$host:3478',
    ];
  }
}

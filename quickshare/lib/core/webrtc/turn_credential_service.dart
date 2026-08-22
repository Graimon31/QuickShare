import 'package:dio/dio.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// Fetches short-lived TURN credentials from the DirectDrop Worker
/// (`POST /turn`, ТЗ v2.0 §3) instead of the build-time credentials baked in
/// via `--dart-define`.
///
/// Falling back to the static config when this fails is [IceServers]'s job,
/// not this class's — this only knows how to talk to the Worker and turn its
/// response into an `iceServers` list.
class TurnCredentialService {
  final String baseUrl;
  final Dio _dio;

  TurnCredentialService({required String baseUrl, Dio? dio})
      : baseUrl = _stripTrailingSlash(baseUrl),
        _dio = dio ?? Dio();

  static String _stripTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  /// Returns the merged Cloudflare + Metered `iceServers` entries. Either
  /// provider missing from the response (the Worker omits a provider that
  /// failed rather than failing the whole request) is fine as long as at
  /// least one came back.
  Future<List<Map<String, dynamic>>> fetchIceServers() async {
    final result = await fetchIceServersWithExpiry();
    return result.servers;
  }

  /// Like [fetchIceServers] but also returns the credential expiry time so
  /// callers can schedule a proactive refresh (ТЗ v2.0 §9).
  ///
  /// Returns `null` for `expiresAt` when the worker response carries no
  /// `expiresAt` field or it cannot be parsed — the caller should treat that
  /// as "credentials last 30 min" and fall back to a fixed timer.
  Future<({List<Map<String, dynamic>> servers, DateTime? expiresAt})>
      fetchIceServersWithExpiry() async {
    final response = await _dio.post<Map<String, dynamic>>('$baseUrl/turn');
    final data = response.data;
    if (data == null) {
      throw StateError('empty response from $baseUrl/turn');
    }

    final servers = <Map<String, dynamic>>[];
    final cloudflare = data['cloudflare'] as Map<String, dynamic>?;
    final metered = data['metered'] as Map<String, dynamic>?;
    if (cloudflare != null) {
      servers.addAll(
          (cloudflare['iceServers'] as List).cast<Map<String, dynamic>>());
    }
    if (metered != null) {
      servers.addAll(
          (metered['iceServers'] as List).cast<Map<String, dynamic>>());
    }
    if (servers.isEmpty) {
      throw StateError(
          'worker returned neither cloudflare nor metered TURN credentials');
    }

    final expiresAtStr = data['expiresAt'] as String?;
    DateTime? expiresAt;
    if (expiresAtStr != null) {
      AppLogger.info('Worker TURN credentials valid until $expiresAtStr',
          tag: 'WEBRTC');
      try {
        expiresAt = DateTime.parse(expiresAtStr).toUtc();
      } catch (_) {
        AppLogger.warning(
            'Could not parse expiresAt "$expiresAtStr", will use fixed TTL',
            tag: 'WEBRTC');
      }
    }
    return (servers: servers, expiresAt: expiresAt);
  }
}

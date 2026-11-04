import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/retry_after.dart';
import 'package:quickshare/core/webrtc/relay_availability.dart';

/// What `POST /turn` yields: the merged `iceServers` entries, and when the
/// credentials stop working (null if the Worker did not say).
typedef TurnCredentials = ({
  List<Map<String, dynamic>> servers,
  DateTime? expiresAt,
});

/// Fetches short-lived TURN credentials from the DirectDrop Worker
/// (`POST /turn`, ТЗ v2.0 §3) instead of the build-time credentials baked in
/// via `--dart-define`.
///
/// The endpoint is public. It used to demand an HMAC from the client, but a
/// secret compiled into a binary that anyone can download protects nothing;
/// the Worker limits the route on its own side instead, and says so:
///
///   200  credentials
///   429  `rate_limited`, with `Retry-After`
///   503  `limiter_unavailable` (with `Retry-After`), `relay_disabled`,
///        `relay_unconfigured`
///   502  `provider_error`
///
/// Every way this can fail leaves as a [RelayUnavailable] carrying one of
/// those reasons (or `unreachable` / `timeout` / `malformedResponse` for the
/// ones the Worker cannot report about itself), because what to do next —
/// wait a minute, stop trying, tell the person — depends on which it was.
///
/// Falling back to the static config when this fails is [IceServers]'s job,
/// not this class's — this only knows how to talk to the Worker and turn its
/// response into an `iceServers` list.
class TurnCredentialService {
  final String baseUrl;
  final Dio _dio;

  TurnCredentialService({
    required String baseUrl,
    Dio? dio,
  })  : baseUrl = _stripTrailingSlash(baseUrl.trim()),
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 4),
                receiveTimeout: const Duration(seconds: 4),
              ),
            );

  @visibleForTesting
  Dio get dio => _dio;

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
  ///
  /// Throws [RelayUnavailable], and nothing else, for every way it can fail.
  Future<TurnCredentials> fetchIceServersWithExpiry() async {
    if (baseUrl.isEmpty) {
      throw const RelayUnavailable(RelayUnavailableReason.noWorkerUrl);
    }

    final Response<Object?> response;
    try {
      response = await _dio.post<Object?>(
        '$baseUrl/turn',
        options: Options(
          // Every status is an answer to read, not an exception to catch: the
          // contract is in the status and the body together.
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      );
    } on DioException catch (e) {
      throw _transportFailure(e);
    } on TimeoutException catch (e) {
      throw RelayUnavailable(RelayUnavailableReason.timeout,
          detail: e.message);
    } catch (e) {
      throw RelayUnavailable(RelayUnavailableReason.unreachable,
          detail: '$e');
    }

    final status = response.statusCode ?? 0;
    if (status == 200) return _credentialsFrom(response.data);
    throw _refusal(status, response);
  }

  RelayUnavailable _transportFailure(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return RelayUnavailable(RelayUnavailableReason.timeout,
            detail: e.message);
      default:
        return RelayUnavailable(RelayUnavailableReason.unreachable,
            detail: e.message ?? e.error?.toString());
    }
  }

  /// A non-200 answer, read against the Worker's contract.
  RelayUnavailable _refusal(int status, Response<Object?> response) {
    final retryAfter = parseRetryAfter(response.headers.value('retry-after'));
    final data = response.data;
    final error = data is Map ? data['error'] : null;

    RelayUnavailable failure(RelayUnavailableReason reason) => RelayUnavailable(
          reason,
          retryAfter: retryAfter,
          statusCode: status,
          detail: error is String ? error : null,
        );

    if (status == 429) return failure(RelayUnavailableReason.rateLimited);
    if (status == 502) return failure(RelayUnavailableReason.providerError);
    if (status == 503) {
      return switch (error) {
        'relay_disabled' => failure(RelayUnavailableReason.relayDisabled),
        'relay_unconfigured' =>
          failure(RelayUnavailableReason.relayUnconfigured),
        'limiter_unavailable' =>
          failure(RelayUnavailableReason.limiterUnavailable),
        // A 503 from something in front of the Worker, or from a build of it
        // that says nothing: it is unavailable, and the Worker did not call
        // it a configuration problem.
        _ => failure(RelayUnavailableReason.unreachable),
      };
    }
    // 404 from a wrong URL, an error page from a captive portal, anything else
    // that is not the Worker speaking.
    return failure(RelayUnavailableReason.unreachable);
  }

  /// A relay: an entry with a `turn:` or `turns:` URL and the username and
  /// credential that make it usable.
  static bool _isRelay(Map<String, dynamic> server) {
    final username = server['username'];
    final credential = server['credential'];
    if (username is! String || username.isEmpty) return false;
    if (credential is! String || credential.isEmpty) return false;
    bool isTurn(Object? url) =>
        url is String && (url.startsWith('turn:') || url.startsWith('turns:'));
    final urls = server['urls'];
    return urls is List ? urls.any(isTurn) : isTurn(urls);
  }

  TurnCredentials _credentialsFrom(Object? data) {
    if (data is! Map) {
      throw const RelayUnavailable(RelayUnavailableReason.malformedResponse,
          statusCode: 200, detail: 'the answer is not a JSON object');
    }

    final servers = <Map<String, dynamic>>[];
    try {
      for (final provider in const ['cloudflare', 'metered']) {
        final entry = data[provider];
        if (entry is! Map) continue;
        servers.addAll(
            (entry['iceServers'] as List).cast<Map<String, dynamic>>());
      }
    } catch (e) {
      throw RelayUnavailable(RelayUnavailableReason.malformedResponse,
          statusCode: 200, detail: 'unreadable iceServers: $e');
    }
    if (servers.isEmpty) {
      throw const RelayUnavailable(RelayUnavailableReason.malformedResponse,
          statusCode: 200,
          detail: 'neither cloudflare nor metered TURN credentials');
    }
    // Something came back; whether it is a relay is another question. An
    // answer that holds STUN alone, or a TURN URL nobody gave a login to, is
    // not credentials, and reporting the relay as available on the strength
    // of it tells the person one was offered when none was.
    if (!servers.any(_isRelay)) {
      throw const RelayUnavailable(RelayUnavailableReason.malformedResponse,
          statusCode: 200,
          detail: 'the answer holds no TURN URL with a username and '
              'credential');
    }

    final expiresAtStr = data['expiresAt'];
    DateTime? expiresAt;
    if (expiresAtStr is String) {
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

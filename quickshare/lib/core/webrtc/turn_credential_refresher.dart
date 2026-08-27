import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/turn_credential_service.dart';

/// Keeps TURN credentials alive for the duration of a peer connection session
/// by calling [RTCPeerConnection.setConfiguration] before they expire.
///
/// WebRTC allows updating the ICE server list on a live connection without
/// tearing it down — the stack simply uses the new credentials for any
/// subsequent TURN allocations. This is exactly what we want: a long transfer
/// that started with 30-minute credentials can keep going after the first
/// expiry without the user having to re-scan a QR code.
///
/// Usage:
/// ```dart
/// final refresher = TurnCredentialRefresher(
///   peerConnection: pc,
///   workerBaseUrl: AppConstants.workerBaseUrl,
///   expiresAt: fetchedExpiresAt,        // null → uses default 30-min TTL
/// );
/// refresher.start();
/// // …later, when the session ends:
/// refresher.cancel();
/// ```
class TurnCredentialRefresher {
  final RTCPeerConnection peerConnection;
  final String workerBaseUrl;
  final DateTime? expiresAt;

  /// How far ahead of the expiry to start the refresh.
  static const _refreshLeadTime = Duration(minutes: 5);

  /// Fallback refresh interval when `expiresAt` is unknown.
  static const _fallbackInterval = Duration(minutes: 25);

  /// Maximum number of consecutive fetch failures before giving up.
  static const _maxRetries = 3;

  Timer? _timer;
  bool _cancelled = false;

  TurnCredentialRefresher({
    required this.peerConnection,
    required this.workerBaseUrl,
    this.expiresAt,
  });

  /// Schedules the first refresh. Safe to call multiple times — only the first
  /// call has any effect.
  void start() {
    if (_timer != null || _cancelled) return;
    _scheduleNext(firstCall: true);
  }

  /// Cancels any pending timer. After this the refresher is permanently idle.
  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleNext({bool firstCall = false}) {
    if (_cancelled) return;

    Duration delay;
    if (expiresAt != null) {
      final remaining = expiresAt!.difference(DateTime.now().toUtc());
      delay = remaining - _refreshLeadTime;
      if (delay.isNegative) {
        // Already past (or within the lead window): refresh immediately.
        delay = Duration.zero;
      }
    } else {
      // No expiry from the server — refresh on a fixed 25-minute cycle so the
      // credentials are always replaced well before the Worker's 30-min TTL.
      delay = firstCall ? _fallbackInterval : _fallbackInterval;
    }

    AppLogger.info(
        'TurnCredentialRefresher: next refresh in '
        '${delay.inSeconds}s (expiresAt=$expiresAt)',
        tag: 'WEBRTC');

    _timer = Timer(delay, () => _refresh(retryCount: 0));
  }

  Future<void> _refresh({required int retryCount}) async {
    if (_cancelled) return;

    try {
      final service = TurnCredentialService(baseUrl: workerBaseUrl);
      final result = await service.fetchIceServersWithExpiry();

      final newConfig =
          IceServers.configurationWithTurnServers(result.servers);

      await peerConnection.setConfiguration(newConfig);
      AppLogger.info(
          'TurnCredentialRefresher: setConfiguration applied, '
          '${result.servers.length} TURN server(s), '
          'next expiry=${result.expiresAt}',
          tag: 'WEBRTC');

      // Schedule the next refresh based on the new expiry.
      if (!_cancelled) {
        _timer?.cancel();
        _timer = null;
        // Construct a new refresher-like schedule using the updated expiry.
        final nextExpiry = result.expiresAt;
        if (nextExpiry != null) {
          final remaining = nextExpiry.difference(DateTime.now().toUtc());
          final delay = remaining - _refreshLeadTime;
          if (!_cancelled) {
            _timer = Timer(
              delay.isNegative ? Duration.zero : delay,
              () => _refresh(retryCount: 0),
            );
          }
        } else {
          _timer = Timer(_fallbackInterval, () => _refresh(retryCount: 0));
        }
      }
    } catch (e) {
      AppLogger.warning(
          'TurnCredentialRefresher: fetch attempt ${retryCount + 1} failed: $e',
          tag: 'WEBRTC');

      if (retryCount < _maxRetries - 1 && !_cancelled) {
        const retryDelay = Duration(minutes: 1);
        AppLogger.info(
            'TurnCredentialRefresher: retry in ${retryDelay.inSeconds}s',
            tag: 'WEBRTC');
        _timer = Timer(
          retryDelay,
          () => _refresh(retryCount: retryCount + 1),
        );
      } else {
        AppLogger.warning(
            'TurnCredentialRefresher: giving up after $_maxRetries attempts',
            tag: 'WEBRTC');
      }
    }
  }
}

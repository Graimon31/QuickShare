import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/relay_availability.dart';
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
///
/// How it fails follows what the Worker says (see [TurnCredentialService]):
///
///  * no Worker URL: it never starts;
///  * 429 / limiter down: it waits the `Retry-After` the Worker asked for (a
///    minute if none) and does not count the wait as a failed attempt — being
///    told to come back later is not the Worker being broken;
///  * `relay_disabled` / `relay_unconfigured`: terminal, it stops;
///  * anything else: up to [_maxRetries] attempts a minute apart.
class TurnCredentialRefresher {
  final RTCPeerConnection peerConnection;
  final String workerBaseUrl;
  final DateTime? expiresAt;

  /// Where credentials come from. The Worker, unless a test supplies one.
  final Future<TurnCredentials> Function() _fetch;

  /// How far ahead of the expiry to start the refresh.
  static const _refreshLeadTime = Duration(minutes: 5);

  /// Fallback refresh interval when `expiresAt` is unknown.
  static const _fallbackInterval = Duration(minutes: 25);

  /// Maximum number of consecutive fetch failures before giving up.
  static const _maxRetries = 3;

  /// How long to wait after a throttled answer that named no `Retry-After`.
  static const _defaultThrottleWait = Duration(minutes: 1);

  /// How many throttled answers in a row are waited out before giving up. Not
  /// the same budget as [_maxRetries]: the Worker asking for time is not the
  /// Worker failing. Ten waits is about ten minutes, well past any limiter
  /// window and still finite.
  static const _maxThrottledWaits = 10;

  Timer? _timer;
  bool _started = false;
  bool _cancelled = false;

  /// Gave up, or was told there is nothing to wait for. Permanent.
  bool _stopped = false;
  bool _refreshing = false;

  TurnCredentialRefresher({
    required this.peerConnection,
    required this.workerBaseUrl,
    this.expiresAt,
    Future<TurnCredentials> Function()? fetch,
  }) : _fetch = fetch ??
            (() => TurnCredentialService(baseUrl: workerBaseUrl)
                .fetchIceServersWithExpiry());

  /// True while a refresh is scheduled or in flight; false before [start],
  /// after [cancel], and once it has stopped for good.
  bool get isRunning =>
      !_cancelled && !_stopped && (_timer != null || _refreshing);

  /// Schedules the first refresh. Safe to call multiple times — only the first
  /// call has any effect. Does nothing at all without a Worker URL: there is
  /// nowhere to refresh from.
  void start() {
    if (_started || _cancelled) return;
    _started = true;
    if (workerBaseUrl.trim().isEmpty) {
      AppLogger.info(
          'TurnCredentialRefresher: no Worker URL, not starting',
          tag: 'WEBRTC');
      _stopped = true;
      return;
    }
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

  Future<void> _refresh({required int retryCount, int throttled = 0}) async {
    if (_cancelled) return;
    _timer = null;
    _refreshing = true;

    try {
      final result = await _fetch();
      // Cancelled while the request was out: the connection this was for may
      // be closed by now, and the answer is of no use to anyone.
      if (_cancelled) return;

      final newConfig =
          IceServers.configurationWithTurnServers(result.servers);

      await peerConnection.setConfiguration(newConfig);
      if (_cancelled) return;
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
    } on RelayUnavailable catch (e) {
      _onRelayUnavailable(e, retryCount: retryCount, throttled: throttled);
    } catch (e) {
      _retryOrGiveUp(e, retryCount: retryCount, throttled: throttled);
    } finally {
      _refreshing = false;
    }
  }

  void _onRelayUnavailable(RelayUnavailable e,
      {required int retryCount, required int throttled}) {
    if (_cancelled) return;

    if (e.reason.isTerminal) {
      // Switched off, or never configured, will still be so in a minute.
      AppLogger.warning(
          'TurnCredentialRefresher: stopping, the relay is not coming back '
          'this session ($e)',
          tag: 'WEBRTC');
      _stopped = true;
      return;
    }

    if (e.reason.isThrottle) {
      if (throttled >= _maxThrottledWaits) {
        AppLogger.warning(
            'TurnCredentialRefresher: still throttled after '
            '$_maxThrottledWaits waits, giving up ($e)',
            tag: 'WEBRTC');
        _stopped = true;
        return;
      }
      final wait = e.retryAfter ?? _defaultThrottleWait;
      AppLogger.info(
          'TurnCredentialRefresher: throttled ($e), waiting ${wait.inSeconds}s '
          'as asked',
          tag: 'WEBRTC');
      _timer = Timer(
        wait,
        () => _refresh(retryCount: retryCount, throttled: throttled + 1),
      );
      return;
    }

    _retryOrGiveUp(e, retryCount: retryCount, throttled: throttled);
  }

  void _retryOrGiveUp(Object e,
      {required int retryCount, required int throttled}) {
    if (_cancelled) return;
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
        () => _refresh(retryCount: retryCount + 1, throttled: throttled),
      );
    } else {
      AppLogger.warning(
          'TurnCredentialRefresher: giving up after $_maxRetries attempts',
          tag: 'WEBRTC');
      _stopped = true;
    }
  }
}

import 'package:equatable/equatable.dart';

import 'package:quickshare/core/errors/failures.dart';

/// Why the app has no relay for this session.
///
/// A relay (TURN) is not a nicety here: the owner's machine sits behind a
/// permanent VPN that makes NAT behave as symmetric, so relayed traffic is the
/// ordinary path. When the relay is missing the connection is usually doomed,
/// and the useful thing to say afterwards is *which* way it is missing — "try
/// again in a minute" and "this build has no relay" are different advice.
enum RelayUnavailableReason {
  /// The build has no Worker address at all (`QUICKSHARE_WORKER_URL` blank).
  noWorkerUrl,

  /// `429 rate_limited`: the Worker is throttling this client. Back off.
  rateLimited,

  /// `503 relay_disabled`: the operator switched the relay off.
  relayDisabled,

  /// `503 relay_unconfigured`: the Worker has no TURN provider configured.
  relayUnconfigured,

  /// `502 provider_error`: the TURN provider behind the Worker failed.
  providerError,

  /// `503 limiter_unavailable`: the Worker's own rate limiter is down. Try
  /// again shortly.
  limiterUnavailable,

  /// The Worker could not be reached, or answered with something that is not
  /// the Worker (a captive portal, a wrong URL, a plain error page).
  unreachable,

  /// The Worker did not answer within the limit.
  timeout,

  /// It answered 200 with something that holds no usable credentials.
  malformedResponse;

  /// Waiting will not change it within a session: retrying is noise.
  bool get isTerminal =>
      this == noWorkerUrl || this == relayDisabled || this == relayUnconfigured;

  /// The Worker is busy rather than broken, and says when to come back.
  bool get isThrottle => this == rateLimited || this == limiterUnavailable;
}

/// A relay could not be had, and why. Thrown by the credential fetch and
/// carried, as a value, by everything downstream that wants to explain it.
class RelayUnavailable implements Exception {
  const RelayUnavailable(
    this.reason, {
    this.retryAfter,
    this.statusCode,
    this.detail,
  });

  final RelayUnavailableReason reason;

  /// What the Worker's `Retry-After` asked for; null if it did not say.
  final Duration? retryAfter;

  /// The HTTP status behind it, when there was an answer at all.
  final int? statusCode;

  /// Anything else worth a log line: the exception text of a socket error.
  final String? detail;

  @override
  String toString() {
    final extras = [
      if (statusCode != null) 'HTTP $statusCode',
      if (retryAfter != null) 'retry after ${retryAfter!.inSeconds}s',
      if (detail != null && detail!.isNotEmpty) detail!,
    ];
    return 'relay unavailable: ${reason.name}'
        '${extras.isEmpty ? '' : ' (${extras.join(', ')})'}';
  }
}

/// What is known when ICE gives up: whether the relay was in play, what was
/// gathered, and which candidate pair — if any — got chosen.
///
/// Built by the transport at the moment of failure and carried unchanged to the
/// screen, the journal and the log, so all three tell the same story.
class NoPathDiagnosis extends Equatable {
  const NoPathDiagnosis({
    this.relayUnavailable,
    this.candidates = '',
    this.selectedPair,
  });

  /// Why there was no relay; null when a relay *was* offered and the
  /// connection failed anyway — a different cause that must not blame it.
  final RelayUnavailable? relayUnavailable;

  /// `IceGatheringTracker.describe()`: how many candidates, of which kinds.
  final String candidates;

  /// Candidate types on each end of the chosen pair, or `none`. Null if it
  /// could not be read.
  final String? selectedPair;

  /// The sentence the screens show, as a [FailureCode] they translate.
  String get failureCode {
    final unavailable = relayUnavailable;
    if (unavailable == null) return FailureCode.noPathRelayWasAvailable;
    return switch (unavailable.reason) {
      RelayUnavailableReason.rateLimited ||
      RelayUnavailableReason.limiterUnavailable =>
        FailureCode.noPathRelayLimited,
      RelayUnavailableReason.relayDisabled ||
      RelayUnavailableReason.relayUnconfigured ||
      RelayUnavailableReason.noWorkerUrl =>
        FailureCode.noPathRelayOff,
      RelayUnavailableReason.unreachable ||
      RelayUnavailableReason.timeout ||
      RelayUnavailableReason.providerError ||
      RelayUnavailableReason.malformedResponse =>
        FailureCode.noPathRelayUnreachable,
    };
  }

  /// English, for the log and the diagnostics a person copies when asking for
  /// help. The screen shows [failureCode] translated instead.
  String get summary {
    final relay = relayUnavailable == null
        ? 'relay: offered'
        : 'relay: ${relayUnavailable!.reason.name}'
            '${_detail(relayUnavailable!)}';
    return 'No usable path between the devices (ICE gave up). $relay; '
        '${candidates.isEmpty ? 'candidates: unknown' : candidates}; '
        'selected pair: ${selectedPair ?? 'unknown'}';
  }

  static String _detail(RelayUnavailable relay) {
    final parts = [
      if (relay.statusCode != null) 'HTTP ${relay.statusCode}',
      if (relay.retryAfter != null) 'retry after ${relay.retryAfter!.inSeconds}s',
    ];
    return parts.isEmpty ? '' : ' (${parts.join(', ')})';
  }

  @override
  List<Object?> get props =>
      [relayUnavailable?.reason, candidates, selectedPair];

  @override
  String toString() => summary;
}

/// The receiver's way of saying a negotiation ended without a connection.
/// Typed so the bloc can pick the right sentence without parsing text.
class IceNegotiationFailed implements Exception {
  const IceNegotiationFailed(this.diagnosis);

  final NoPathDiagnosis diagnosis;

  @override
  String toString() => diagnosis.summary;
}

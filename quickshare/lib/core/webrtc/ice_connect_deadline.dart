import 'dart:async';

import 'package:quickshare/core/utils/app_logger.dart';

/// A deadline on the ICE negotiation itself: from the moment both descriptions
/// are in place until a connection is up.
///
/// libwebrtc usually reports `failed` on its own once every candidate pair has
/// been tried — and that is what the transports react to. But an app that
/// relies on that alone has no end of its own: a negotiation that sits in
/// `checking` (a peer that never answers, a path that drops every probe
/// without an ICMP error, a stack that never makes the call) leaves the person
/// on "connecting" with nothing to wait for. Without a relay that is the
/// expected outcome on the target setup, not a rarity, so the wait is bounded
/// here and the transports treat expiry exactly like a `failed` state.
///
/// Deliberately separate from the disconnect grace period each transport
/// already has: that one guards a connection that was up and dropped, this one
/// guards one that never came up.
class IceConnectDeadline {
  /// Long enough for a TURN allocation over TLS, the answer's trip through a
  /// rendezvous channel (a Worker poll every two seconds, a Nostr relay), and
  /// a few rounds of connectivity checks on a slow path; short enough that a
  /// doomed session does not look alive.
  static const Duration defaultBudget = Duration(seconds: 60);

  IceConnectDeadline({
    this.budget = defaultBudget,
    required this.onExpired,
    this.tag = 'WEBRTC',
  });

  final Duration budget;
  final void Function() onExpired;
  final String tag;

  Timer? _timer;

  /// Set once [connected] has been called, and never cleared.
  bool _connected = false;

  bool get isArmed => _timer != null;

  /// Starts the clock. A second call while it runs changes nothing — the
  /// budget counts from the first.
  ///
  /// Does nothing once the connection is up. The callers arm after awaiting
  /// something that can outlast the negotiation itself — the receiver's
  /// `publish` returns when the relay acknowledges the answer, by which time
  /// the sender has usually seen it and ICE has connected — and a deadline
  /// started then would run out in the middle of a healthy transfer.
  void arm() {
    if (_timer != null || _connected) return;
    _timer = Timer(budget, () {
      _timer = null;
      AppLogger.warning(
          'ICE did not connect within ${budget.inSeconds}s — giving up on '
          'this session',
          tag: tag);
      onExpired();
    });
  }

  /// The connection came up: nothing to expire, now or if [arm] is called
  /// late.
  void connected() {
    _connected = true;
    cancel();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

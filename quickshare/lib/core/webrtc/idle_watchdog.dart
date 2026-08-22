import 'dart:async';

/// Fires [onTimeout] unless [kick] is called again within [timeout].
///
/// Pulled out as its own class for the same reason [SendBuffer] was: the
/// failure it detects — bytes stop arriving and nothing else notices — only
/// shows up with a peer that goes silent mid-transfer, which needs a real
/// clock to test rather than a mocked one.
class IdleWatchdog {
  final Duration timeout;
  final void Function() onTimeout;

  Timer? _timer;

  IdleWatchdog({required this.timeout, required this.onTimeout});

  /// Restarts the countdown. Call this on every sign of life — a received
  /// chunk, a recovered ICE state — not just once at setup.
  void kick() {
    _timer?.cancel();
    _timer = Timer(timeout, onTimeout);
  }

  /// Stops the countdown for good, e.g. once the transfer completes.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

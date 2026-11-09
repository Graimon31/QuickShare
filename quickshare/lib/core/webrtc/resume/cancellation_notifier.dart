import 'dart:async';

/// Delivers an intentional stop before its authenticated data channel closes.
/// Older peers may close without acknowledging; waiting is always bounded.
abstract interface class CancellationNotifier {
  Future<void> notifyCancellation({
    Duration timeout = const Duration(seconds: 8),
  });
}

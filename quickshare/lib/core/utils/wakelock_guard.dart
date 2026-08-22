import 'package:quickshare/core/utils/app_logger.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Reference-counted wakelock.
///
/// Multiple callers (HTTP server, WebRTC transport, BLE peripheral) can each
/// call [acquire] independently and the screen/CPU will not power down until
/// every caller has called [release].  A raw `WakelockPlus.enable()` /
/// `WakelockPlus.disable()` pair is dangerous when several subsystems overlap:
/// the first one to call `disable()` would release the lock on everyone,
/// including callers that are still mid-transfer.
///
/// Usage:
/// ```dart
/// final guard = WakelockGuard();
/// await guard.acquire();
/// try {
///   // …long-running work…
/// } finally {
///   await guard.release();
/// }
/// ```
///
/// The class is intentionally not a singleton so each call site can choose
/// whether to share an instance or own a private one. Typically a transport
/// class holds one private instance and acquires / releases around its own
/// lifetime.
class WakelockGuard {
  int _refs = 0;

  /// Increments the reference count and enables the wakelock on the first
  /// acquisition. Safe to call from any isolate.
  Future<void> acquire() async {
    _refs++;
    if (_refs == 1) {
      try {
        await WakelockPlus.enable();
        AppLogger.info('WakelockGuard: wakelock enabled (refs=$_refs)',
            tag: 'WAKELOCK');
      } catch (e) {
        // Platform may not support wakelock (e.g. macOS desktop). Log and
        // continue — the transfer should not fail because of this.
        AppLogger.warning('WakelockGuard: enable() threw: $e', tag: 'WAKELOCK');
      }
    }
  }

  /// Decrements the reference count and disables the wakelock once the count
  /// reaches zero. Extra [release] calls beyond the matching [acquire]s are
  /// no-ops so they cannot take the count negative.
  Future<void> release() async {
    if (_refs <= 0) return;
    _refs--;
    if (_refs == 0) {
      try {
        await WakelockPlus.disable();
        AppLogger.info('WakelockGuard: wakelock released (refs=$_refs)',
            tag: 'WAKELOCK');
      } catch (e) {
        AppLogger.warning('WakelockGuard: disable() threw: $e',
            tag: 'WAKELOCK');
      }
    }
  }

  /// Current number of active acquisitions. Useful for debugging.
  int get refCount => _refs;
}

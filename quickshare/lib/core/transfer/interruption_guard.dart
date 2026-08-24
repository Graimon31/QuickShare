import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// What became of a transfer that was interrupted by the app leaving the
/// foreground.
enum ResumeVerdict {
  /// The user came back in time. Pick up where it stopped.
  resume,

  /// They did not. Say so plainly and let them start again.
  giveUp,
}

/// Holds a transfer's place while the user is looking at something else.
///
/// Backgrounding an app mid-transfer is not a mistake and not rare: a message
/// arrives, a password needs copying, the screen locks itself. iOS suspends
/// the process outright and whatever socket was open dies with it, so the
/// transfer reports a failure that has nothing to do with the network and
/// everything to do with where the user was looking.
///
/// QHTP can already resume — partial files stay on disk and Range requests
/// pick up from the byte they stopped at. What was missing is the judgement of
/// whether resuming is still wanted. That is a question about the person, not
/// the protocol: come back within [grace] and the transfer continues; leave it
/// longer and it is cleared away with an honest message rather than left
/// half-finished forever.
///
/// Modelled on [HotspotLifecycleGuard], which draws the same line for the same
/// reason: `paused` is not a decision, it is a glance.
class TransferInterruptionGuard with WidgetsBindingObserver {
  /// How long a transfer waits for the user to come back.
  final Duration grace;

  Timer? _graceTimer;
  DateTime? _leftAt;
  Completer<ResumeVerdict>? _waiting;

  TransferInterruptionGuard({this.grace = const Duration(minutes: 1)});

  bool _attached = false;

  /// Starts watching the app's lifecycle, if there is one to watch.
  ///
  /// Safe to call repeatedly, and safe where no widget binding exists — a
  /// headless context has no foreground to leave, so there is nothing to
  /// guard and nothing to fail over.
  void attach() {
    if (_attached) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _attached = true;
    } on FlutterError {
      AppLogger.info('No app lifecycle to watch; transfers will not be held '
          'open across a backgrounding', tag: 'TRANSFER');
    }
  }

  void detach() {
    _graceTimer?.cancel();
    _graceTimer = null;
    _settle(ResumeVerdict.giveUp);
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// Whether the app has left the foreground since the transfer began.
  ///
  /// A failure that arrives while this is true is almost certainly the
  /// suspension rather than the link, and is worth waiting out instead of
  /// reporting.
  bool get wasInterrupted => _leftAt != null;

  /// Waits for the user to come back, or for [grace] to run out.
  ///
  /// Returns immediately when the app is already in the foreground: they left
  /// and returned before the failure even surfaced, which is the common case
  /// on a fast transfer.
  Future<ResumeVerdict> awaitVerdict() {
    if (!wasInterrupted) return Future.value(ResumeVerdict.resume);
    if (_graceTimer?.isActive != true) {
      // Either they are already back, or the window closed while nobody was
      // asking.
      return Future.value(
          _leftAt == null ? ResumeVerdict.resume : ResumeVerdict.giveUp);
    }
    return (_waiting ??= Completer<ResumeVerdict>()).future;
  }

  /// Forgets any interruption, for a transfer that is starting over.
  void reset() {
    _graceTimer?.cancel();
    _graceTimer = null;
    _leftAt = null;
    _settle(ResumeVerdict.giveUp);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_graceTimer?.isActive ?? false) {
          AppLogger.info('Back within the minute — the transfer continues',
              tag: 'TRANSFER');
        }
        _graceTimer?.cancel();
        _graceTimer = null;
        _leftAt = null;
        _settle(ResumeVerdict.resume);

      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _leftAt = DateTime.now();
        _graceTimer?.cancel();
        _graceTimer = Timer(grace, () {
          AppLogger.info(
              'Away for ${grace.inSeconds}s — the transfer will not be resumed',
              tag: 'TRANSFER');
          _settle(ResumeVerdict.giveUp);
        });

      case AppLifecycleState.detached:
        _graceTimer?.cancel();
        _graceTimer = null;
        _settle(ResumeVerdict.giveUp);

      case AppLifecycleState.inactive:
        // A banner, a call, the app switcher. Transient, and acting on it
        // would abandon a transfer every time the user glances at a
        // notification.
        break;
    }
  }

  void _settle(ResumeVerdict verdict) {
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete(verdict);
  }

  @visibleForTesting
  bool get isWaitingForReturn => _graceTimer?.isActive ?? false;
}

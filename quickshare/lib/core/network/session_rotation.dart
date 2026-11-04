import 'dart:async';

/// Decides when an offer's code and QR are replaced, and when that must wait.
///
/// One deadline at a time. It fires [onDue] once when the deadline arrives —
/// from a timer, so it is exact while the app runs, and from [check], so it is
/// still prompt after the machine slept through it: a timer measures time the
/// process was running, the wall clock measures time that passed, and only the
/// second is what "the code lasts five minutes" means.
///
/// Rotation is never allowed to break something in progress. Whoever knows of
/// such a thing [hold]s the schedule with a reason of its own — a person is
/// being asked, a transfer has begun, an answer arrived — and the deadline
/// does not fire until every reason has been [release]d. If it passed in the
/// meantime it fires at once.
///
/// Pure scheduling: it knows nothing about codes, tokens or screens, which is
/// what makes the rule testable with a fake clock and nothing else.
class RotationSchedule {
  RotationSchedule({
    required void Function() onDue,
    DateTime Function()? now,
  })  : _onDue = onDue,
        _now = now ?? DateTime.now;

  final void Function() _onDue;
  final DateTime Function() _now;

  DateTime? _expiresAt;
  Timer? _timer;
  final Set<Object> _holds = {};

  /// The deadline [onDue] has already fired for, so that a second [check]
  /// while a rotation is still in flight does not start a second one.
  DateTime? _firedFor;

  /// When the current code lapses, or null when nothing is scheduled.
  DateTime? get expiresAt => _expiresAt;

  bool get isHeld => _holds.isNotEmpty;

  /// Whether a deadline is set, held or not.
  bool get isArmed => _expiresAt != null;

  /// How long is left. Zero once the deadline has passed, never negative.
  Duration get remaining {
    final at = _expiresAt;
    if (at == null) return Duration.zero;
    final left = at.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Sets the deadline. Arming the instant already set changes nothing, which
  /// is what lets a state that is re-emitted unchanged be armed again freely.
  void arm(DateTime expiresAt) {
    if (_expiresAt == expiresAt) return;
    _timer?.cancel();
    _timer = null;
    _expiresAt = expiresAt;
    _firedFor = null;
    _schedule();
  }

  /// Stops the deadline passing into a rotation for [reason], until released.
  void hold(Object reason) {
    _holds.add(reason);
    _timer?.cancel();
    _timer = null;
  }

  /// Lets [reason] go. When it was the last one, the deadline resumes — and if
  /// it has passed meanwhile, fires now.
  void release(Object reason) {
    if (!_holds.remove(reason)) return;
    if (_holds.isEmpty) _schedule();
  }

  /// Fires now if the deadline has passed. For the moment an app is brought
  /// back to the foreground.
  void check() {
    if (_expiresAt == null || isHeld) return;
    _schedule();
  }

  /// Forgets the deadline and every hold. The next session starts clean.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _expiresAt = null;
    _firedFor = null;
    _holds.clear();
  }

  void _schedule() {
    final at = _expiresAt;
    if (at == null || isHeld) return;
    _timer?.cancel();
    _timer = null;
    final left = at.difference(_now());
    if (left <= Duration.zero) {
      _fire(at);
      return;
    }
    _timer = Timer(left, () {
      _timer = null;
      if (isHeld || _expiresAt != at) return;
      _fire(at);
    });
  }

  void _fire(DateTime at) {
    if (_firedFor == at) return;
    _firedFor = at;
    _onDue();
  }
}

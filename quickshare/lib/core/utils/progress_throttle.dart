/// Caps how often a transfer reports progress.
///
/// Chunks arrive far faster than a progress bar can show, and each report
/// crosses into a BLoC state and a rebuild. Unthrottled that is hundreds of
/// times a second on the isolate that is also writing the file. Ten times a
/// second is the cadence QHTP already uses; [force] is for 100% / completed,
/// which must not sit behind the interval.
class ProgressThrottle {
  ProgressThrottle({this.interval = const Duration(milliseconds: 100)});

  final Duration interval;
  DateTime? _last;

  bool allow({DateTime? now, bool force = false}) {
    final t = now ?? DateTime.now();
    if (!force && _last != null && t.difference(_last!) < interval) {
      return false;
    }
    _last = t;
    return true;
  }
}

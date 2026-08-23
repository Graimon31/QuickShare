/// Turns a stream of "bytes received so far" readings into a speed a person
/// can read.
///
/// A transfer reports progress once per chunk — every 16 KB — which on a fast
/// link is hundreds of events per second. Dividing the byte delta by the
/// wall-clock gap between two such events produces nonsense: the gap is often
/// well under a millisecond, so the result swings between zero and tens of
/// megabytes per second depending on which side of a scheduler tick the
/// samples landed. That is what the UI was showing.
///
/// Two things fix it. A sample is only taken once [window] has actually
/// elapsed, so the divisor is never vanishingly small; and the result is put
/// through an exponential moving average, so a burst or a brief pause moves
/// the number without whipsawing it.
class TransferSpeed {
  /// Shortest interval that may be used as a measurement. Long enough that a
  /// scheduler hiccup cannot dominate the division.
  final Duration window;

  /// How strongly a new sample pulls the reported value, 0..1. Lower is
  /// steadier but slower to react to a genuine change in rate.
  final double smoothing;

  DateTime? _lastSampleAt;
  int _lastSampleBytes = 0;
  double _smoothed = 0;
  bool _hasSample = false;

  TransferSpeed({
    this.window = const Duration(milliseconds: 500),
    this.smoothing = 0.35,
  });

  /// Current speed in bytes per second, or null before the first full window
  /// has elapsed — the caller should show nothing rather than a made-up zero.
  double? get bytesPerSecond => _hasSample ? _smoothed : null;

  /// Feeds a cumulative byte count. Returns the current speed, or null while
  /// still measuring.
  double? update(int totalBytesReceived, {DateTime? now}) {
    final at = now ?? DateTime.now();

    if (_lastSampleAt == null) {
      _lastSampleAt = at;
      _lastSampleBytes = totalBytesReceived;
      return null;
    }

    final elapsed = at.difference(_lastSampleAt!);
    if (elapsed < window) return bytesPerSecond;

    final delta = totalBytesReceived - _lastSampleBytes;
    _lastSampleAt = at;
    _lastSampleBytes = totalBytesReceived;

    // A cumulative counter cannot go backwards; if it appears to, the reading
    // is from a different session and starting over beats reporting a
    // negative rate.
    if (delta < 0) {
      reset();
      return null;
    }

    final instant = delta / (elapsed.inMicroseconds / 1000000);
    _smoothed =
        _hasSample ? _smoothed + smoothing * (instant - _smoothed) : instant;
    _hasSample = true;
    return _smoothed;
  }

  void reset() {
    _lastSampleAt = null;
    _lastSampleBytes = 0;
    _smoothed = 0;
    _hasSample = false;
  }

  /// Human-readable form, matching what the progress screen shows.
  static String format(double? bytesPerSecond) {
    if (bytesPerSecond == null) return '—';
    if (bytesPerSecond < 1024) return '${bytesPerSecond.round()} B/s';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
}

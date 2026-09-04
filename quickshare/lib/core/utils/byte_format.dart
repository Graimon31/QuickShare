/// Sizes and rates, in the units the rest of the machine uses.
///
/// A thousand, not 1024. Every Apple interface a person can compare this
/// against — Finder's size column, the iOS storage screen, the App Store —
/// has counted a megabyte as 1,000,000 bytes since Snow Leopard, and Windows
/// Explorer is the only mainstream file manager that still does otherwise.
/// Dividing by 1024 and then writing "MB" is not a different convention, it is
/// the wrong label on the right number: the same 600,000,000-byte selection
/// reads 600 MB in Finder and 572.2 in units of 1024, and someone comparing
/// the two concludes that files went missing on the way in.
///
/// One place, because there were eight copies of this function and they had
/// already drifted apart in their rounding and their unit lists.
class ByteFormat {
  static const int _step = 1000;
  static const List<String> _units = ['KB', 'MB', 'GB', 'TB', 'PB'];

  /// A size, e.g. `572 B`, `1.4 KB`, `600.0 MB`.
  ///
  /// One decimal place below ten, none above: `9.7 MB` is worth the digit and
  /// `572.2 MB` is not, and a column of sizes that changes width as it counts
  /// up is harder to read than one that does not.
  static String size(int bytes) {
    if (bytes < _step) return '$bytes B';

    var value = bytes / _step;
    var unit = 0;
    while (value >= _step && unit < _units.length - 1) {
      value /= _step;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${_units[unit]}';
  }

  /// A transfer rate, e.g. `12.4 MB/s`.
  ///
  /// Decimal for the same reason, and additionally because every figure a
  /// network is ever quoted in — the megabits on a router's box, the speed a
  /// provider sells — is decimal already.
  static String rate(num bytesPerSecond) =>
      '${size(bytesPerSecond.round())}/s';
}

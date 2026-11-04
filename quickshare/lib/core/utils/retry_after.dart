import 'dart:io';

/// Reads an HTTP `Retry-After` header: the Worker's way of saying "not now,
/// but soon" on a 429 or a 503.
///
/// Both spellings the header may take are understood — whole seconds (all the
/// Worker sends) and an HTTP date. A date already in the past is [Duration.zero]
/// rather than a negative wait.
///
/// Null when there is nothing usable, so the caller picks its own wait. [max]
/// caps the answer: this value comes off the network, and one absurd header
/// must not park a client for hours.
Duration? parseRetryAfter(
  String? value, {
  DateTime? now,
  Duration max = const Duration(minutes: 5),
}) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;

  Duration? wait;
  final seconds = int.tryParse(text);
  if (seconds != null) {
    if (seconds < 0) return null;
    wait = Duration(seconds: seconds);
  } else {
    try {
      final at = HttpDate.parse(text);
      final from = (now ?? DateTime.now()).toUtc();
      wait = at.isAfter(from) ? at.difference(from) : Duration.zero;
    } catch (_) {
      return null;
    }
  }
  return wait > max ? max : wait;
}

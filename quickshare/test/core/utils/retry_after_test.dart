// `Retry-After` is how the Worker says "not now, but soon": 60 seconds on
// every 429 and 503 it sends. Both the TURN credential fetch and the rendezvous
// mailbox honour it, so the parsing lives in one place and is pinned here.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/utils/retry_after.dart';

void main() {
  group('parseRetryAfter', () {
    test('reads delta-seconds, which is what the Worker sends', () {
      expect(parseRetryAfter('60'), equals(const Duration(seconds: 60)));
      expect(parseRetryAfter(' 5 '), equals(const Duration(seconds: 5)));
      expect(parseRetryAfter('0'), equals(Duration.zero));
    });

    test('reads an HTTP date relative to now', () {
      final now = DateTime.utc(2026, 11, 2, 12, 0, 0);
      expect(
        parseRetryAfter('Mon, 02 Nov 2026 12:01:30 GMT', now: now),
        equals(const Duration(seconds: 90)),
      );
      // A date already in the past is "now", not a negative wait.
      expect(
        parseRetryAfter('Mon, 02 Nov 2026 11:00:00 GMT', now: now),
        equals(Duration.zero),
      );
    });

    test('is null for a missing or unreadable header', () {
      expect(parseRetryAfter(null), isNull);
      expect(parseRetryAfter(''), isNull);
      expect(parseRetryAfter('soon'), isNull);
      expect(parseRetryAfter('-5'), isNull);
    });

    test('caps an absurd value so one bad header cannot park a client', () {
      expect(parseRetryAfter('999999999'), equals(const Duration(minutes: 5)));
      expect(
        parseRetryAfter('999999999', max: const Duration(seconds: 90)),
        equals(const Duration(seconds: 90)),
      );
    });
  });
}

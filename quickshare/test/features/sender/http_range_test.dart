import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/features/sender/data/server/http_range.dart';

void main() {
  const size = 2000;

  ByteRange? rangeOf(String? header, [int total = size]) =>
      parseRangeHeader(header, total).range;
  RangeOutcome outcomeOf(String? header, [int total = size]) =>
      parseRangeHeader(header, total).outcome;

  group('suffix ranges', () {
    test('bytes=-500 returns the LAST 500 bytes', () {
      // Regression: the old parser left start at 0 and set end to 500,
      // serving the first 501 bytes with Content-Range "bytes 0-500/2000".
      expect(rangeOf('bytes=-500'), equals(const ByteRange(1500, 1999)));
      expect(rangeOf('bytes=-500')!.length, equals(500));
    });

    test('a suffix longer than the file yields the whole file', () {
      expect(rangeOf('bytes=-99999'), equals(const ByteRange(0, 1999)));
    });

    test('bytes=-0 is unsatisfiable', () {
      expect(outcomeOf('bytes=-0'), equals(RangeOutcome.unsatisfiable));
    });
  });

  group('explicit ranges', () {
    test('clamps an end past the file size', () {
      // Regression: an unclamped end made Content-Length claim a gigabyte and
      // the server aborted the response mid-stream.
      expect(rangeOf('bytes=0-999999999'), equals(const ByteRange(0, 1999)));
      expect(rangeOf('bytes=0-999999999')!.length, equals(size));
    });

    test('honours a normal closed range', () {
      expect(rangeOf('bytes=100-199'), equals(const ByteRange(100, 199)));
      expect(rangeOf('bytes=100-199')!.length, equals(100));
    });

    test('honours an open-ended range, which is what the receiver sends', () {
      expect(rangeOf('bytes=1000-'), equals(const ByteRange(1000, 1999)));
    });

    test('a start at or past the end is unsatisfiable', () {
      expect(outcomeOf('bytes=2000-'), equals(RangeOutcome.unsatisfiable));
      expect(outcomeOf('bytes=5000-6000'), equals(RangeOutcome.unsatisfiable));
    });

    test('the last byte is reachable', () {
      expect(rangeOf('bytes=1999-'), equals(const ByteRange(1999, 1999)));
    });
  });

  group('headers that must be ignored rather than rejected', () {
    // RFC 9110 §14.2: an invalid Range header field must be ignored.
    for (final header in <String?>[
      null,
      '',
      'items=0-10',
      'bytes=',
      'bytes=abc-def',
      'bytes=100-50',
      'bytes=0-99,200-299',
      'bytes=--',
    ]) {
      test('"$header" falls back to the whole representation', () {
        expect(outcomeOf(header), equals(RangeOutcome.absent));
      });
    }

    test('the unit is matched case-insensitively', () {
      expect(rangeOf('BYTES=0-9'), equals(const ByteRange(0, 9)));
    });

    test('surrounding whitespace is tolerated', () {
      expect(rangeOf('  bytes = 0-9  '.replaceAll(' = ', '=')),
          equals(const ByteRange(0, 9)));
    });
  });

  group('empty representation', () {
    test('any range against a zero-length file is unsatisfiable', () {
      expect(outcomeOf('bytes=0-', 0), equals(RangeOutcome.unsatisfiable));
      expect(outcomeOf('bytes=-10', 0), equals(RangeOutcome.unsatisfiable));
    });

    test('no header against a zero-length file is still a plain 200', () {
      expect(outcomeOf(null, 0), equals(RangeOutcome.absent));
    });
  });
}

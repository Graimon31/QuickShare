// The number has to agree with Finder.
//
// Reported from a real selection: Finder said 600 MB, the app said 572.2 MB
// for the same files, and the natural conclusion is that something went
// missing on the way in. Nothing had. Finder counts a megabyte as 1,000,000
// bytes — as every Apple interface has since Snow Leopard — while the app
// divided by 1024 and wrote "MB" on the result. Same bytes, wrong label.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/utils/byte_format.dart';

void main() {
  test('the reported discrepancy is gone', () {
    // The exact selection from the report: what Finder calls 600 MB.
    expect(ByteFormat.size(600 * 1000 * 1000), '600 MB');
  });

  test('a megabyte is a million bytes, not 1048576', () {
    expect(ByteFormat.size(1000 * 1000), '1.0 MB');
    // What the old code would have called "1.0 MB".
    expect(ByteFormat.size(1048576), '1.0 MB',
        reason: '1048576 rounds to 1.0 MB decimal too — the gap only opens '
            'up as the numbers grow');
    expect(ByteFormat.size(1024 * 1024 * 1024), '1.1 GB',
        reason: 'a "gigabyte" of 1024s is 1.07 decimal GB, and Finder says so');
  });

  test('bytes below a kilobyte are shown as bytes', () {
    expect(ByteFormat.size(0), '0 B');
    expect(ByteFormat.size(999), '999 B');
    expect(ByteFormat.size(1000), '1.0 KB');
  });

  test('one decimal below ten, none above', () {
    // A column of sizes that changes width as it counts up is harder to read
    // than one that does not.
    expect(ByteFormat.size(9700000), '9.7 MB');
    expect(ByteFormat.size(97000000), '97 MB');
  });

  test('it climbs through the units rather than running out', () {
    expect(ByteFormat.size(2500000000), '2.5 GB');
    expect(ByteFormat.size(3000000000000), '3.0 TB');
    expect(ByteFormat.size(4000000000000000), '4.0 PB');
  });

  test('rates carry the same units, because networks are quoted that way', () {
    expect(ByteFormat.rate(12400000), '12 MB/s');
    expect(ByteFormat.rate(1500), '1.5 KB/s');
    expect(ByteFormat.rate(0), '0 B/s');
  });
}

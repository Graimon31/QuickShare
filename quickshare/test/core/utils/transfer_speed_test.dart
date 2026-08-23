// The bug this exists to prevent: the receive screen showed 2.6 MB/s, then
// 15.6 MB/s, then 0.0 B/s, then 96.4 KB/s, over a few seconds of a transfer
// that was running at a steady ~2 MB/s. Progress events arrive once per 16 KB
// chunk, and dividing by the sub-millisecond gap between two of them produces
// exactly that.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/utils/transfer_speed.dart';

void main() {
  final t0 = DateTime(2026, 8, 23, 15, 0, 0);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  group('sampling window', () {
    test('reports nothing until a full window has elapsed', () {
      final speed = TransferSpeed();
      expect(speed.update(0, now: at(0)), isNull);
      expect(speed.update(16384, now: at(1)), isNull,
          reason: 'one chunk 1 ms later must not produce a reading');
      expect(speed.bytesPerSecond, isNull);
    });

    test('a burst of chunks inside one window cannot move the number', () {
      // This is the actual failure: hundreds of events per second, each one
      // previously recomputing speed from its own microsecond-scale gap.
      final speed = TransferSpeed();
      speed.update(0, now: at(0));
      for (var i = 1; i <= 60; i++) {
        expect(speed.update(i * 16384, now: at(i)), isNull);
      }
      expect(speed.bytesPerSecond, isNull);
    });

    test('measures once the window passes', () {
      final speed = TransferSpeed();
      speed.update(0, now: at(0));
      final reading = speed.update(1000000, now: at(500));
      expect(reading, isNotNull);
      expect(reading!, closeTo(2000000, 1),
          reason: '1 MB in 0.5 s is 2 MB/s');
    });
  });

  group('smoothing', () {
    test('a steady rate settles on that rate', () {
      final speed = TransferSpeed();
      var total = 0;
      speed.update(total, now: at(0));
      // 1 MB every 500 ms == 2 MB/s, for 10 seconds.
      for (var i = 1; i <= 20; i++) {
        total += 1000000;
        speed.update(total, now: at(i * 500));
      }
      expect(speed.bytesPerSecond!, closeTo(2000000, 50000));
    });

    test('a single stalled window dips the number without zeroing it', () {
      // A brief pause is not a stop, and showing 0.0 B/s mid-transfer reads as
      // "it died" to a person watching.
      final speed = TransferSpeed();
      var total = 0;
      speed.update(total, now: at(0));
      for (var i = 1; i <= 10; i++) {
        total += 1000000;
        speed.update(total, now: at(i * 500));
      }
      final before = speed.bytesPerSecond!;

      speed.update(total, now: at(11 * 500)); // nothing arrived

      final after = speed.bytesPerSecond!;
      expect(after, lessThan(before));
      expect(after, greaterThan(0),
          reason: 'one empty window must not read as a dead transfer');
    });

    test('a sustained stop does converge to zero', () {
      final speed = TransferSpeed();
      var total = 0;
      speed.update(total, now: at(0));
      for (var i = 1; i <= 10; i++) {
        total += 1000000;
        speed.update(total, now: at(i * 500));
      }
      for (var i = 11; i <= 40; i++) {
        speed.update(total, now: at(i * 500));
      }
      expect(speed.bytesPerSecond!, lessThan(50000));
    });

    test('a genuine speed change is followed, not ignored', () {
      final speed = TransferSpeed();
      var total = 0;
      speed.update(total, now: at(0));
      for (var i = 1; i <= 10; i++) {
        total += 500000; // 1 MB/s
        speed.update(total, now: at(i * 500));
      }
      for (var i = 11; i <= 30; i++) {
        total += 2500000; // 5 MB/s
        speed.update(total, now: at(i * 500));
      }
      expect(speed.bytesPerSecond!, closeTo(5000000, 300000));
    });
  });

  group('robustness', () {
    test('a counter that goes backwards restarts instead of going negative',
        () {
      // Only happens if readings from two sessions reach the same meter, but
      // a negative speed on screen would be worse than a brief blank.
      final speed = TransferSpeed();
      speed.update(0, now: at(0));
      speed.update(5000000, now: at(500));
      expect(speed.bytesPerSecond, isNotNull);

      expect(speed.update(1000, now: at(1000)), isNull);
      expect(speed.bytesPerSecond, isNull);
    });

    test('reset clears the meter for a new transfer', () {
      final speed = TransferSpeed();
      speed.update(0, now: at(0));
      speed.update(1000000, now: at(500));
      expect(speed.bytesPerSecond, isNotNull);

      speed.reset();
      expect(speed.bytesPerSecond, isNull);
    });
  });

  group('format', () {
    test('shows a dash before there is anything to report', () {
      expect(TransferSpeed.format(null), equals('—'));
    });

    test('picks a unit that keeps the number readable', () {
      expect(TransferSpeed.format(512), equals('512 B/s'));
      expect(TransferSpeed.format(1536), equals('1.5 KB/s'));
      expect(TransferSpeed.format(2.5 * 1024 * 1024), equals('2.5 MB/s'));
    });
  });
}

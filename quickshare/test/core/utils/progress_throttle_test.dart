import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/utils/progress_throttle.dart';

void main() {
  // DD-24: a 64 KB WebRTC chunk at line rate is hundreds of events a
  // second. Ten times a second is what the bar can show; 100% must still
  // land immediately so the screen does not sit on 98%.
  test('lets the first event through, then holds the rest for 100 ms', () {
    final throttle = ProgressThrottle(
      interval: const Duration(milliseconds: 100),
    );
    final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

    expect(throttle.allow(now: t0), isTrue);
    expect(throttle.allow(now: t0.add(const Duration(milliseconds: 50))),
        isFalse);
    expect(throttle.allow(now: t0.add(const Duration(milliseconds: 100))),
        isTrue);
  });

  test('force skips the wait so completion is not queued behind the interval',
      () {
    final throttle = ProgressThrottle(
      interval: const Duration(milliseconds: 100),
    );
    final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

    expect(throttle.allow(now: t0), isTrue);
    expect(
      throttle.allow(now: t0.add(const Duration(milliseconds: 10)), force: true),
      isTrue,
    );
  });
}

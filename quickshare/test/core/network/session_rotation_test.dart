// When an offer's code and QR are replaced, and when they must not be.
//
// The owner's rule is one number: whatever is on the screen changes every five
// minutes. Everything else here is about not breaking a real transfer while
// that happens — a pending approval, a started transfer — and about not being
// late: a laptop that slept through the deadline must rotate the moment it is
// opened, not whenever its timers next get a turn.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/network/session_rotation.dart';

void main() {
  final epoch = DateTime.utc(2026, 11, 4, 12);

  test('the lifetime is five minutes, in one place', () {
    expect(AppConstants.sessionCodeLifetime, const Duration(minutes: 5));
  });

  /// A schedule on a clock that moves with `fakeAsync` plus [skew] — time the
  /// machine spent asleep, during which no timer fired.
  ({RotationSchedule schedule, List<DateTime> due, void Function(Duration) sleep})
      build(FakeAsync async) {
    var skew = Duration.zero;
    DateTime now() => epoch.add(async.elapsed + skew);
    final due = <DateTime>[];
    final schedule = RotationSchedule(onDue: () => due.add(now()), now: now);
    return (
      schedule: schedule,
      due: due,
      sleep: (Duration d) => skew += d,
    );
  }

  group('the deadline', () {
    test('fires at exactly the lifetime, not a moment before', () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));

        async.elapse(AppConstants.sessionCodeLifetime -
            const Duration(milliseconds: 1));
        expect(t.due, isEmpty);

        async.elapse(const Duration(milliseconds: 1));
        expect(t.due, [epoch.add(AppConstants.sessionCodeLifetime)]);
      });
    });

    test('says how long is left, and never a negative amount', () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));
        expect(t.schedule.remaining, AppConstants.sessionCodeLifetime);

        async.elapse(const Duration(minutes: 3, seconds: 20));
        expect(t.schedule.remaining, const Duration(minutes: 1, seconds: 40));

        async.elapse(const Duration(minutes: 3));
        expect(t.schedule.remaining, Duration.zero);
      });
    });

    test('fires once per deadline, however often it is asked', () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));
        async.elapse(AppConstants.sessionCodeLifetime);
        t.schedule.check();
        t.schedule.check();
        async.elapse(const Duration(minutes: 1));

        expect(t.due, hasLength(1),
            reason: 'a rotation still in flight must not be started twice');
      });
    });

    test('a new deadline starts a new countdown', () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));
        async.elapse(AppConstants.sessionCodeLifetime);

        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime * 2));
        async.elapse(AppConstants.sessionCodeLifetime);

        expect(t.due, hasLength(2));
      });
    });
  });

  group('after the machine slept', () {
    test('rotates the moment it is checked on return, not when a timer next '
        'fires', () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));
        async.elapse(const Duration(minutes: 1));

        // The lid closes for twenty minutes: the wall clock moves, no timer
        // does.
        t.sleep(const Duration(minutes: 20));
        expect(t.due, isEmpty, reason: 'asleep, nothing could have fired');

        t.schedule.check();

        expect(t.due, hasLength(1));
      });
    });

    test('a check before the deadline does nothing', () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));
        async.elapse(const Duration(minutes: 4));
        t.schedule.check();
        expect(t.due, isEmpty);
      });
    });
  });

  group('holding', () {
    test('a held schedule does not rotate, and does the moment it is released',
        () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));
        t.schedule.hold('approval');

        async.elapse(AppConstants.sessionCodeLifetime * 2);
        expect(t.due, isEmpty);
        expect(t.schedule.isHeld, isTrue);

        t.schedule.release('approval');
        expect(t.due, hasLength(1),
            reason: 'the deadline passed while held: rotate after it resolves');
      });
    });

    test('released before the deadline, it still fires on time', () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));
        async.elapse(const Duration(minutes: 1));
        t.schedule.hold('approval');
        async.elapse(const Duration(minutes: 1));
        t.schedule.release('approval');

        async.elapse(const Duration(minutes: 3) -
            const Duration(milliseconds: 1));
        expect(t.due, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(t.due, hasLength(1));
      });
    });

    test('every reason has to let go before it moves again', () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));
        t.schedule.hold('approval');
        t.schedule.hold('transfer');
        async.elapse(AppConstants.sessionCodeLifetime);

        t.schedule.release('approval');
        expect(t.due, isEmpty, reason: 'the transfer still holds it');

        t.schedule.release('transfer');
        expect(t.due, hasLength(1));
      });
    });

    test('a check while held does not rotate', () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));
        t.schedule.hold('transfer');
        t.sleep(const Duration(minutes: 30));
        t.schedule.check();
        expect(t.due, isEmpty);
      });
    });
  });

  group('stopping', () {
    test('a stopped schedule never fires and forgets its holds', () {
      fakeAsync((async) {
        final t = build(async);
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime));
        t.schedule.hold('answer');
        t.schedule.stop();

        async.elapse(AppConstants.sessionCodeLifetime * 3);
        t.schedule.check();
        expect(t.due, isEmpty);
        expect(t.schedule.isHeld, isFalse);
        expect(t.schedule.expiresAt, isNull);

        // A session that starts afterwards is not born held.
        t.schedule.arm(epoch.add(AppConstants.sessionCodeLifetime * 4));
        async.elapse(AppConstants.sessionCodeLifetime);
        expect(t.due, hasLength(1));
      });
    });
  });
}

// The code that decides when a Wi-Fi network the app raised gets torn down.
//
// Both failure directions cost the user something real: tearing down too eagerly
// aborts a transfer in progress, and never tearing down leaves the radio in
// access-point mode draining the battery with nobody connected. Neither shows up
// in a crash report.
//
// Timing is driven by FakeAsync rather than real delays, so "two minutes later"
// is exact and the suite stays fast. Every test also asserts on the *number* of
// calls, not just that one happened — a leaked timer looks identical to a
// correct one until it fires twice.
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/hotspot_lifecycle_guard.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';

/// Counts teardowns. The real service short-circuits on anything that is not
/// Android, which would make every assertion below vacuously pass on the
/// machine running the tests.
class _CountingHotspot extends LocalHotspotService {
  int stopCalls = 0;

  _CountingHotspot()
      : super(channel: const MethodChannel('quickshare/hotspot.test'));

  @override
  bool get canHost => true;

  @override
  Future<void> stopHosting() async => stopCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grace = Duration(minutes: 2);

  /// Runs [body] with a guard wired to fake time.
  void withGuard(
      void Function(HotspotLifecycleGuard guard, _CountingHotspot hotspot,
              FakeAsync async)
          body) {
    fakeAsync((async) {
      final hotspot = _CountingHotspot();
      final guard = HotspotLifecycleGuard(hotspot: hotspot, grace: grace);
      try {
        body(guard, hotspot, async);
      } finally {
        guard.detach();
        async.flushTimers();
      }
    });
  }

  group('tearing down', () {
    test('detached stops immediately, without waiting out the grace period',
        () {
      // The process is going away: there is nothing left to be polite about.
      withGuard((guard, hotspot, async) {
        guard.didChangeAppLifecycleState(AppLifecycleState.detached);
        async.flushMicrotasks();

        expect(hotspot.stopCalls, equals(1));
        expect(guard.isGracePeriodRunning, isFalse);
      });
    });

    test('paused waits out the grace period first', () {
      withGuard((guard, hotspot, async) {
        guard.didChangeAppLifecycleState(AppLifecycleState.paused);

        async.elapse(grace - const Duration(seconds: 1));
        expect(hotspot.stopCalls, isZero,
            reason: 'a transfer must survive a glance at another app');

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(hotspot.stopCalls, equals(1));
      });
    });

    test('hidden behaves like paused', () {
      withGuard((guard, hotspot, async) {
        guard.didChangeAppLifecycleState(AppLifecycleState.hidden);
        expect(guard.isGracePeriodRunning, isTrue);

        async.elapse(grace + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(hotspot.stopCalls, equals(1));
      });
    });

    test('inactive is ignored entirely', () {
      // A notification shade, an incoming call, the app switcher. Reacting
      // would drop the network every time a banner appears.
      withGuard((guard, hotspot, async) {
        guard.didChangeAppLifecycleState(AppLifecycleState.inactive);

        expect(guard.isGracePeriodRunning, isFalse);
        async.elapse(const Duration(hours: 1));
        expect(hotspot.stopCalls, isZero);
      });
    });
  });

  group('coming back', () {
    test('resumed cancels a pending teardown', () {
      withGuard((guard, hotspot, async) {
        guard.didChangeAppLifecycleState(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 30));

        guard.didChangeAppLifecycleState(AppLifecycleState.resumed);
        expect(guard.isGracePeriodRunning, isFalse);

        async.elapse(const Duration(hours: 1));
        expect(hotspot.stopCalls, isZero,
            reason: 'the user came back — the network must still be there');
      });
    });

    test('a full grace period restarts after each return', () {
      withGuard((guard, hotspot, async) {
        for (var i = 0; i < 3; i++) {
          guard.didChangeAppLifecycleState(AppLifecycleState.paused);
          async.elapse(grace - const Duration(seconds: 5));
          guard.didChangeAppLifecycleState(AppLifecycleState.resumed);
        }
        // Nearly six minutes of background time in total, never two
        // uninterrupted.
        expect(hotspot.stopCalls, isZero);

        guard.didChangeAppLifecycleState(AppLifecycleState.paused);
        async.elapse(grace + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(hotspot.stopCalls, equals(1));
      });
    });
  });

  group('no timer leaks under fast switching', () {
    test('repeated paused events leave exactly one pending teardown', () {
      // Android emits paused more than once in some flows. Without cancelling
      // the previous timer each one would survive, and stopHosting would fire
      // once per event — the leak this asserts against.
      withGuard((guard, hotspot, async) {
        for (var i = 0; i < 10; i++) {
          guard.didChangeAppLifecycleState(AppLifecycleState.paused);
        }
        expect(guard.isGracePeriodRunning, isTrue);

        async.elapse(grace + const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(hotspot.stopCalls, equals(1),
            reason: 'ten pauses must not mean ten teardowns');
        expect(async.pendingTimers, isEmpty,
            reason: 'nothing may outlive the teardown');
      });
    });

    test('rapid paused/resumed churn schedules nothing in the end', () {
      withGuard((guard, hotspot, async) {
        for (var i = 0; i < 50; i++) {
          guard.didChangeAppLifecycleState(AppLifecycleState.paused);
          async.elapse(const Duration(milliseconds: 100));
          guard.didChangeAppLifecycleState(AppLifecycleState.resumed);
          async.elapse(const Duration(milliseconds: 100));
        }

        expect(guard.isGracePeriodRunning, isFalse);
        expect(async.pendingTimers, isEmpty,
            reason: 'a cancelled timer must not stay on the queue');
        async.elapse(const Duration(hours: 1));
        expect(hotspot.stopCalls, isZero);
      });
    });

    test('paused then detached stops once, not twice', () {
      withGuard((guard, hotspot, async) {
        guard.didChangeAppLifecycleState(AppLifecycleState.paused);
        guard.didChangeAppLifecycleState(AppLifecycleState.detached);
        async.flushMicrotasks();

        expect(hotspot.stopCalls, equals(1));

        async.elapse(grace + const Duration(seconds: 1));
        expect(hotspot.stopCalls, equals(1),
            reason: 'the pending timer must have been cancelled by detached');
      });
    });

    test('detach() cancels a pending teardown and stops observing', () {
      fakeAsync((async) {
        final hotspot = _CountingHotspot();
        final guard = HotspotLifecycleGuard(hotspot: hotspot, grace: grace);
        guard.attach();

        guard.didChangeAppLifecycleState(AppLifecycleState.paused);
        expect(guard.isGracePeriodRunning, isTrue);

        guard.detach();

        expect(guard.isGracePeriodRunning, isFalse);
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(hours: 1));
        expect(hotspot.stopCalls, isZero,
            reason: 'a detached guard must not act on the app any more');
      });
    });

    test('attach/detach cycles do not accumulate observers', () {
      fakeAsync((async) {
        final hotspot = _CountingHotspot();
        for (var i = 0; i < 5; i++) {
          final guard = HotspotLifecycleGuard(hotspot: hotspot, grace: grace);
          guard.attach();
          guard.detach();
        }
        // A guard left registered would still receive lifecycle callbacks and
        // tear down a network belonging to a later session.
        final live = HotspotLifecycleGuard(hotspot: hotspot, grace: grace)
          ..attach();
        WidgetsBinding.instance
            .handleAppLifecycleStateChanged(AppLifecycleState.detached);
        async.flushMicrotasks();

        expect(hotspot.stopCalls, equals(1),
            reason: 'only the one still attached may respond');
        live.detach();
      });
    });
  });
}

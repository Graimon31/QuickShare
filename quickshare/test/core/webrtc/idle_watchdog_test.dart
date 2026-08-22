// The receiver's serverless path used to have nothing at all watching for
// "the peer went silent" — only a flat 120-second cap on the entire transfer,
// counted from before the first byte. A file that took longer than that to
// arrive got killed even while healthy, and a connection that died at second
// 10 sat unreported until second 120. This is what replaced that.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/webrtc/idle_watchdog.dart';

void main() {
  test('does not fire while kicked more often than the timeout', () async {
    var fired = false;
    final watchdog = IdleWatchdog(
      timeout: const Duration(milliseconds: 30),
      onTimeout: () => fired = true,
    );

    for (var i = 0; i < 5; i++) {
      watchdog.kick();
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }

    expect(fired, isFalse);
    watchdog.cancel();
  });

  test('fires once nothing kicks it for the timeout duration', () async {
    var fired = false;
    final watchdog = IdleWatchdog(
      timeout: const Duration(milliseconds: 30),
      onTimeout: () => fired = true,
    );

    watchdog.kick();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(fired, isTrue);
  });

  test('cancel stops a pending timeout from firing', () async {
    var fired = false;
    final watchdog = IdleWatchdog(
      timeout: const Duration(milliseconds: 20),
      onTimeout: () => fired = true,
    );

    watchdog.kick();
    watchdog.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(fired, isFalse);
  });

  test('never kicked at all still fires — a session must arm it explicitly',
      () async {
    var fired = false;
    final watchdog = IdleWatchdog(
      timeout: const Duration(milliseconds: 20),
      onTimeout: () => fired = true,
    );
    watchdog.kick(); // arming is explicit; a watchdog nobody starts is inert
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fired, isTrue);
  });
}

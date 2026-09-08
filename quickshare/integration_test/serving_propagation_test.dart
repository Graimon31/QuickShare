// Does a device that opens a session get *seen* to open one?
//
//     flutter test integration_test/serving_propagation_test.dart -d macos
//
// A rig rather than an assertion. It announces on the real service type, sits
// idle long enough for every app on the network to list it, and only then
// starts serving — so the question it puts to the other devices is the one
// that matters: not "can you find me", which already worked, but "did you
// notice me change".
//
// It exists because that change is invisible to a browser. A TXT record can be
// replaced without producing any browse event at all, so a receiver that
// resolved a device once and cached the answer keeps showing it as idle
// forever. On one machine the difference never shows — unregister and register
// there produce an immediate lost/found pair, and every test passes — so this
// has to be watched from a second device, by reading its journal afterwards.
//
// Watch for, on the other device:
//     [DISCOVERY] Probe Sender is offering a session on :8000
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:quickshare/core/network/device_presence.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('announce, sit idle, then start serving', (tester) async {
    // The real type on purpose: the point is to be seen by the actual app
    // running on the actual phone, not by another copy of this test.
    final presence = DevicePresence();
    addTearDown(presence.dispose);

    expect(await presence.start(name: 'Probe Sender'), isTrue,
        reason: 'nothing can be observed if this device cannot announce');

    // Long enough that anything nearby has found and resolved this device
    // while it has nothing to offer. That cached "idle" answer is the thing
    // under test.
    print('idle as "Probe Sender" — let the other device list it');
    await Future<void>.delayed(const Duration(seconds: 20));

    print('now serving :8000 as PROBE001 — watch the other device notice');
    presence.nowServing(
      port: 8000,
      tlsFingerprint: 'probe-fingerprint',
      sessionPublicId: 'PROBE001',
    );

    // Held open so the change has time to travel and be picked up, and so the
    // journal on the other side has something to show.
    await Future<void>.delayed(const Duration(seconds: 45));
    print('done — pull the other device\'s journal now');
  }, timeout: const Timeout(Duration(seconds: 180)));
}

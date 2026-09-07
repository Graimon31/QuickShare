// The bug this reproduces: a sender sitting on its QR screen never sees a
// receiver that opens its own screen afterwards.
//
//     flutter test integration_test/late_join_test.dart -d macos
//
// Both orders have to work, and only one of them did. Starting the two ends
// together — which is what the existing device test does — hides it
// completely, because then everybody is already announcing by the time anybody
// browses. In real use the sender is nearly always first: you pick the files,
// then walk over and open the app on the other device.
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:quickshare/core/network/device_presence.dart';
import 'package:quickshare/core/network/lan_discovery.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  LanDiscoveryService isolated() =>
      LanDiscoveryService(serviceType: '_ddlate._tcp');

  /// Waits for [presence] to list a peer whose name starts with [name].
  Future<DiscoveredPeer?> waitFor(
    DevicePresence presence,
    String name, {
    Duration within = const Duration(seconds: 25),
  }) async {
    final deadline = DateTime.now().add(within);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final match =
          presence.current.where((p) => p.name.startsWith(name)).firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  testWidgets('a device that appears later is still found', (tester) async {
    // The sender, already browsing and waiting.
    final sender = DevicePresence(discovery: isolated());
    addTearDown(sender.dispose);
    if (!await sender.start(name: 'Late Sender')) {
      // The test binary is rebuilt on every run and is therefore not the app
      // the user granted Local Network access to, so on macOS 15 the browse
      // never starts here. Verified by hand against the real app instead.
      markTestSkipped('local discovery is unavailable to this binary');
      return;
    }

    // Long enough that the browse has certainly settled and gone quiet.
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(sender.current.where((p) => p.name.startsWith('Late Receiver')),
        isEmpty,
        reason: 'nothing should be there yet');

    // Only now does the receiver open its screen.
    final receiver = DevicePresence(discovery: isolated());
    addTearDown(receiver.dispose);
    if (!await receiver.start(
      name: 'Late Receiver',
      onInvitation: (_) async => true,
    )) {
      markTestSkipped('local discovery is unavailable to this binary');
      return;
    }

    final seen = await waitFor(sender, 'Late Receiver');
    print('sender sees: ${sender.current}');
    expect(seen, isNotNull,
        reason: 'a receiver that opens its screen after the sender is already '
            'waiting must still turn up in the list');
    expect(seen!.acceptsInvitations, isTrue);
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('the other order works too', (tester) async {
    // The case that already worked, kept so a fix for the one above cannot
    // quietly break it.
    final receiver = DevicePresence(discovery: isolated());
    addTearDown(receiver.dispose);
    if (!await receiver.start(
      name: 'Early Receiver',
      onInvitation: (_) async => true,
    )) {
      markTestSkipped('local discovery is unavailable to this binary');
      return;
    }

    await Future<void>.delayed(const Duration(seconds: 4));

    final sender = DevicePresence(discovery: isolated());
    addTearDown(sender.dispose);
    if (!await sender.start(name: 'Early Sender')) {
      markTestSkipped('local discovery is unavailable to this binary');
      return;
    }

    expect(await waitFor(sender, 'Early Receiver'), isNotNull);
  }, timeout: const Timeout(Duration(seconds: 120)));
}

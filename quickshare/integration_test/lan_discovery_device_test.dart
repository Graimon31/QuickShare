// Does discovery work on a real device, against the platform's own responder?
//
//     flutter test integration_test/lan_discovery_device_test.dart -d macos
//
// This is the check that could not be made anywhere else. `flutter test` runs
// headless with no native plugins registered, so every mDNS call there is a
// MissingPluginException — the suite in `test/` can only cover the parsing and
// the rules, never the part that talks to mDNSResponder.
//
// It exists because the previous discovery was written on exactly that gap: a
// multicast socket of our own passed every unit test and then failed on iOS
// with "No route to host", because since iOS 14 arbitrary multicast needs an
// entitlement Apple does not hand out to free accounts. Nothing short of
// running on a device would have caught it.
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:quickshare/core/network/device_presence.dart';
import 'package:quickshare/core/network/lan_discovery.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// A type of its own, so a neighbour running the real app does not turn up
  /// in the middle of a test.
  LanDiscoveryService isolated() =>
      LanDiscoveryService(serviceType: '_ddprobe._tcp');

  testWidgets('this platform can announce itself at all', (tester) async {
    // The single most important assertion in the suite: on iOS the previous
    // implementation could not, and said so only at runtime.
    final presence = DevicePresence(discovery: isolated());
    addTearDown(presence.dispose);

    final started = await presence.start(name: 'Probe A');

    expect(started, isTrue,
        reason: 'mDNS registration failed — on iOS this is the multicast '
            'entitlement, on a locked-down network it is the network');
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('two instances on this machine find each other', (tester) async {
    // Proves the browse half as well as the register half, over the real
    // responder rather than a loopback socket we control.
    final alice = DevicePresence(discovery: isolated());
    final bob = DevicePresence(discovery: isolated());
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    expect(await alice.start(name: 'Probe Alice'), isTrue);
    expect(
      await bob.start(
        name: 'Probe Bob',
        onInvitation: (_, __) async => true,
      ),
      isTrue,
    );

    // Registration and the first resolve take noticeably longer than a
    // datagram did — the responder has to publish, and the browser has to
    // resolve before a record carries its TXT payload and addresses.
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    DiscoveredPeer? seen;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      seen = alice.current
          .where((p) => p.name.startsWith('Probe Bob'))
          .firstOrNull;
      if (seen != null) break;
    }

    print('Alice sees: ${alice.current}');
    expect(seen, isNotNull, reason: 'Bob never appeared in Alice\'s list');

    // The parts a row is drawn from and a socket is opened with.
    expect(seen!.address.address, isNotEmpty);
    expect(seen.platform, isNotEmpty);
    expect(seen.acceptsInvitations, isTrue,
        reason: 'the invitation port has to survive the TXT round trip');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('a device never lists itself', (tester) async {
    // Our own registration comes back through our own browser. A screen that
    // means "devices near you" listing this device is nonsense.
    final presence = DevicePresence(discovery: isolated());
    addTearDown(presence.dispose);

    expect(await presence.start(name: 'Probe Solo'), isTrue);
    await Future<void>.delayed(const Duration(seconds: 8));

    expect(
      presence.current.where((p) => p.name.startsWith('Probe Solo')),
      isEmpty,
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}

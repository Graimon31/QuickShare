// Does discovery actually work over a real multicast group?
//
// Two services in one process on one machine, talking through the kernel's
// networking stack rather than through a stub. That covers the half the unit
// tests cannot reach: joining the group, pinning the outgoing interface, and
// the loop that turns datagrams into rows.
//
// It caught the bug that made discovery useless on the developer's own laptop:
// with an always-on VPN holding the default route, announcements left through
// the tunnel (`198.18.0.1`) instead of the Wi-Fi interface, so nothing on the
// actual network ever heard one. The symptom was an empty list — identical to
// a network that blocks multicast, and no unit test could tell them apart.
//
// Skips itself where multicast is unavailable (a CI container, a locked-down
// network) rather than failing: there is nothing to assert about a socket that
// cannot open.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/lan_discovery.dart';

void main() {
  late LanDiscoveryService alice;
  late LanDiscoveryService bob;

  setUp(() {
    alice = LanDiscoveryService();
    bob = LanDiscoveryService();
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  /// Long enough for one announcement interval plus slack for a dropped
  /// datagram, which is routine on Wi-Fi.
  const settle = Duration(seconds: 3);

  test('two devices on one network find each other, and not themselves',
      () async {
    final alsoStarted = await alice.start(const DiscoveryAnnouncement(
      id: 'alice',
      name: 'Alice Laptop',
      platform: 'macos',
    ));
    final bobStarted = await bob.start(const DiscoveryAnnouncement(
      id: 'bob',
      name: 'Bob Desktop',
      platform: 'windows',
      port: 8000,
      tlsFingerprint: 'fingerprint-of-bobs-cert',
    ));

    if (!alsoStarted || !bobStarted) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);

    expect(alice.current.map((p) => p.name), contains('Bob Desktop'));
    expect(bob.current.map((p) => p.name), contains('Alice Laptop'));

    expect(alice.current.any((p) => p.id == 'alice'), isFalse,
        reason: 'our own announcements come back on the group and must not '
            'appear on a screen that means "devices near you"');
    expect(bob.current.any((p) => p.id == 'bob'), isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a peer offering a session carries what it takes to dial it', () async {
    final ok = await alice.start(const DiscoveryAnnouncement(
        id: 'alice', name: 'Alice Laptop', platform: 'macos'));
    final bobOk = await bob.start(const DiscoveryAnnouncement(
      id: 'bob',
      name: 'Bob Desktop',
      platform: 'windows',
      port: 8000,
      tlsFingerprint: 'fingerprint-of-bobs-cert',
    ));
    if (!ok || !bobOk) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);

    final seen = alice.current.firstWhere((p) => p.id == 'bob');
    expect(seen.isServing, isTrue);
    expect(seen.port, equals(8000));
    expect(seen.tlsFingerprint, equals('fingerprint-of-bobs-cert'));
    expect(seen.address.address, isNot(equals('0.0.0.0')),
        reason: 'the address comes from the datagram, so it is dialable');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a device that opens a session is seen to have opened it', () async {
    // `update` exists for exactly this: a device announces itself as present,
    // then gains a port when the user picks files. The far side has to notice
    // without waiting for a new discovery cycle to invent one.
    final ok = await alice.start(const DiscoveryAnnouncement(
        id: 'alice', name: 'Alice Laptop', platform: 'macos'));
    final bobOk = await bob.start(const DiscoveryAnnouncement(
        id: 'bob', name: 'Bob Desktop', platform: 'windows'));
    if (!ok || !bobOk) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);
    expect(alice.current.firstWhere((p) => p.id == 'bob').isServing, isFalse);

    bob.update(const DiscoveryAnnouncement(
      id: 'bob',
      name: 'Bob Desktop',
      platform: 'windows',
      port: 9100,
      tlsFingerprint: 'now-serving',
    ));
    await Future<void>.delayed(const Duration(seconds: 1));

    final serving = alice.current.firstWhere((p) => p.id == 'bob');
    expect(serving.isServing, isTrue);
    expect(serving.port, equals(9100));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a device that leaves drops off the list', () async {
    final ok = await alice.start(const DiscoveryAnnouncement(
        id: 'alice', name: 'Alice Laptop', platform: 'macos'));
    final bobOk = await bob.start(const DiscoveryAnnouncement(
        id: 'bob', name: 'Bob Desktop', platform: 'windows'));
    if (!ok || !bobOk) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);
    expect(alice.current, isNotEmpty);

    await bob.stop();
    // Past the presence timeout, with a pruning tick to spare.
    await Future<void>.delayed(
        PeerRegistry.presenceTimeout + LanDiscoveryService.announceInterval);

    expect(alice.current.any((p) => p.id == 'bob'), isFalse);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('the announcement leaves through the LAN interface, not a tunnel',
      () async {
    // The regression this file exists for. A datagram that came from a
    // 198.18.0.0/15 address left through the VPN's synthetic interface
    // (RFC 2544 benchmarking space, which is what those clients use) and
    // never touched the real network.
    final ok = await alice.start(const DiscoveryAnnouncement(
        id: 'alice', name: 'Alice Laptop', platform: 'macos'));
    final bobOk = await bob.start(const DiscoveryAnnouncement(
        id: 'bob', name: 'Bob Desktop', platform: 'windows'));
    if (!ok || !bobOk) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);
    final heard = alice.current.where((p) => p.id == 'bob');
    if (heard.isEmpty) {
      markTestSkipped('nothing was heard on this host');
      return;
    }

    expect(heard.single.address.address, isNot(startsWith('198.18.')),
        reason: 'discovery sent into the VPN tunnel instead of the LAN');
  }, timeout: const Timeout(Duration(seconds: 30)));
}

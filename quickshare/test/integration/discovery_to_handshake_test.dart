// The whole path, over real sockets: one device finds another and asks it to
// accept a transfer.
//
// This is what "tap a name and send" is made of, and the two halves are only
// useful together — discovery says who is there but deliberately carries no
// token, and the handshake carries the token but needs an address to send it
// to. Testing them apart leaves the seam between them untested, and the seam
// is where the port number has to survive a round trip through a datagram.
//
// Skips itself where multicast is unavailable, as the discovery tests do.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/device_presence.dart';
import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/transfer/invitation_sender.dart';
import 'package:quickshare/core/transfer/transfer_invitation.dart';

void main() {
  late DevicePresence alice;
  late DevicePresence bob;

  // A service type of its own, so this file cannot hear the devices another
  // test file is announcing. `flutter test` runs files in parallel, and
  // sharing the real type means `firstWhere(name == 'Bob Desktop')` can find
  // somebody else's Bob — which is exactly what happened once already, and
  // looked like an invitation port that failed to survive the announcement.
  DevicePresence isolated() => DevicePresence(
        discovery: LanDiscoveryService(serviceType: '_ddhandshake._tcp'),
      );

  setUp(() {
    alice = isolated();
    bob = isolated();
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  const settle = Duration(seconds: 3);

  const offer = TransferInvitation(
    senderName: 'Alice Laptop',
    senderPlatform: 'macos',
    itemCount: 2,
    totalBytes: 5000000,
    port: 8000,
    sessionId: 'session-1',
    token: 'the-session-token',
    tlsFingerprint: 'alice-cert',
  );

  test('a device is found and then asked, and the answer comes back',
      () async {
    TransferInvitation? asked;

    final aliceUp = await alice.start(name: 'Alice Laptop');
    final bobUp = await bob.start(
      name: 'Bob Desktop',
      onInvitation: (invitation, _) async {
        asked = invitation;
        return true;
      },
    );
    if (!aliceUp || !bobUp) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);

    // Found, and found to be askable — a device that cannot be asked is a row
    // with nothing behind it.
    final peer = alice.current.firstWhere((p) => p.name == 'Bob Desktop');
    expect(peer.acceptsInvitations, isTrue,
        reason: 'the invitation port has to survive the announcement');

    final result = await InvitationSender().invite(
      address: peer.address,
      port: peer.invitePort,
      invitation: offer,
    );

    expect(result.accepted, isTrue);
    expect(asked, isNotNull);
    expect(asked!.token, equals('the-session-token'),
        reason: 'the token travels here, never in the announcement');
    expect(asked!.senderName, equals('Alice Laptop'));
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a device that cannot ask its user does not advertise that it can '
      'be sent to', () async {
    // Otherwise a sender picks it and waits out the whole answer window for a
    // prompt nobody was ever shown.
    final aliceUp = await alice.start(name: 'Alice Laptop');
    final bobUp = await bob.start(name: 'Bob Browsing'); // no prompt
    if (!aliceUp || !bobUp) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);

    final peer = alice.current.firstWhere((p) => p.name == 'Bob Browsing');
    expect(peer.acceptsInvitations, isFalse);
    expect(peer.invitePort, isZero);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('declining reaches the sender as a decline', () async {
    final aliceUp = await alice.start(name: 'Alice Laptop');
    final bobUp = await bob.start(
      name: 'Bob Desktop',
      onInvitation: (_, __) async => false,
    );
    if (!aliceUp || !bobUp) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);
    final peer = alice.current.firstWhere((p) => p.name == 'Bob Desktop');

    final result = await InvitationSender().invite(
      address: peer.address,
      port: peer.invitePort,
      invitation: offer,
    );

    expect(result.outcome, equals(InvitationOutcome.declined));
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a device that starts serving is seen to, without being asked again',
      () async {
    // The sender opens its session after the receiver has agreed, and the
    // receiver has to notice the port appear.
    final aliceUp = await alice.start(name: 'Alice Laptop');
    final bobUp = await bob.start(name: 'Bob Desktop');
    if (!aliceUp || !bobUp) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);
    expect(
      bob.current.firstWhere((p) => p.name == 'Alice Laptop').isServing,
      isFalse,
    );

    alice.nowServing(port: 8000, tlsFingerprint: 'alice-cert');
    await Future<void>.delayed(const Duration(seconds: 1));

    final serving = bob.current.firstWhere((p) => p.name == 'Alice Laptop');
    expect(serving.isServing, isTrue);
    expect(serving.port, equals(8000));
    expect(serving.tlsFingerprint, equals('alice-cert'));
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('an invitation port survives a repeated start from another screen',
      () async {
    // Every screen with a device list calls start on the shared presence, and
    // none of them passes a prompt — the shared one was started with it. A
    // repeat that rebuilt the announcement dropped the port from the network
    // while the listener kept listening, and tapping the device reported it
    // as unreachable.
    final aliceUp = await alice.start(name: 'Alice Laptop');
    final bobUp = await bob.start(
      name: 'Bob Desktop',
      onInvitation: (_, __) async => true,
    );
    if (!aliceUp || !bobUp) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);
    final before = alice.current.firstWhere((p) => p.name == 'Bob Desktop');
    expect(before.acceptsInvitations, isTrue);

    // What opening the code-entry screen does to the shared presence.
    expect(await bob.start(), isTrue);
    await Future<void>.delayed(settle);

    final after = alice.current.firstWhere((p) => p.name == 'Bob Desktop');
    expect(after.invitePort, equals(before.invitePort),
        reason: 'a repeated start must not touch the announcement');

    final result = await InvitationSender().invite(
      address: after.address,
      port: after.invitePort,
      invitation: offer,
    );
    expect(result.accepted, isTrue);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('an invitation port survives a device going quiet and coming back',
      () async {
    // Announcements repeat every couple of seconds; a field that is only in
    // the first one would vanish on the second.
    final aliceUp = await alice.start(name: 'Alice Laptop');
    final bobUp = await bob.start(
      name: 'Bob Desktop',
      onInvitation: (_, __) async => true,
    );
    if (!aliceUp || !bobUp) {
      markTestSkipped('multicast is unavailable on this host');
      return;
    }

    await Future<void>.delayed(settle);
    final first =
        alice.current.firstWhere((p) => p.name == 'Bob Desktop').invitePort;

    // Several more resolution rounds.
    await Future<void>.delayed(const Duration(seconds: 6));
    final later =
        alice.current.firstWhere((p) => p.name == 'Bob Desktop').invitePort;

    expect(later, equals(first));
    expect(later, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 40)));
}

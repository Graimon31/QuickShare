// A device is listed because it answers, not because it was announced once.
//
// The two are much further apart than they look. A DNS-SD record outlives the
// app that published it by the best part of an hour, and an app that is
// force-quit or suspended never gets to send a goodbye at all — so a phone
// whose app had been closed for minutes sat in the sender's list as "waiting",
// and because every launch announces a fresh identifier, the same phone could
// appear twice from two different launches. Measured on the real pair: the
// responder still held `ip=63845` from one launch and `ip=64663` from another,
// and nothing was listening on either.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/lan_discovery.dart';

void main() {
  /// One announcement, as it arrives from the responder.
  DiscoveredPeer peer({
    String id = 'peer-1',
    String name = 'iPhone',
    int invitePort = 5000,
    int port = 0,
  }) =>
      DiscoveredPeer(
        id: id,
        name: name,
        platform: 'ios',
        address: InternetAddress('192.168.3.51'),
        port: port,
        invitePort: invitePort,
      );

  /// Drives [LanDiscoveryService]'s liveness rule without a network: the real
  /// probe opens a socket, this one answers whatever the test says.
  Future<bool> Function(InternetAddress, int) answering(bool answer) =>
      (_, __) async => answer;

  group('a device that answers', () {
    test('is kept, and its earlier misses are forgotten', () async {
      var answers = false;
      final service = LanDiscoveryService(
        serviceType: '_ddliveness._tcp',
        answersOn: (_, __) async => answers,
      );
      addTearDown(service.dispose);

      // One miss is survivable on its own.
      expect(await service.stillThere(peer()), isTrue);

      answers = true;
      expect(await service.stillThere(peer()), isTrue);

      // The strike is gone, so the next miss starts counting from scratch
      // rather than being the one that removes a device that is plainly there.
      answers = false;
      expect(await service.stillThere(peer()), isTrue);
    });
  });

  group('a device that has stopped answering', () {
    test('survives one missed answer, because Wi-Fi drops packets', () async {
      final service = LanDiscoveryService(
        serviceType: '_ddliveness._tcp',
        answersOn: answering(false),
      );
      addTearDown(service.dispose);

      expect(await service.stillThere(peer()), isTrue,
          reason: 'blinking out of the list on one lost packet is worse');
    });

    test('is dropped once it has missed enough of them', () async {
      final service = LanDiscoveryService(
        serviceType: '_ddliveness._tcp',
        answersOn: answering(false),
      );
      addTearDown(service.dispose);

      for (var i = 1; i < LanDiscoveryService.strikesBeforeGone; i++) {
        expect(await service.stillThere(peer()), isTrue);
      }
      expect(await service.stillThere(peer()), isFalse);
    });

    test('does not take another device down with it', () async {
      // Strikes are counted per device: two launches of one phone arrive as
      // two identifiers, and the dead one must not evict the live one.
      final service = LanDiscoveryService(
        serviceType: '_ddliveness._tcp',
        answersOn: (_, port) async => port == 6000,
      );
      addTearDown(service.dispose);

      for (var i = 0; i < LanDiscoveryService.strikesBeforeGone; i++) {
        await service.stillThere(peer(id: 'old', invitePort: 5000));
      }

      expect(
        await service.stillThere(peer(id: 'old', invitePort: 5000)),
        isFalse,
      );
      expect(
        await service.stillThere(peer(id: 'new', invitePort: 6000)),
        isTrue,
      );
    });
  });

  group('a device with no port to be asked on', () {
    test('is taken at its word rather than dropped', () async {
      // An older build, or one that is only browsing. There is nothing to
      // probe, and refusing to list it would remove a device that is there.
      final service = LanDiscoveryService(
        serviceType: '_ddliveness._tcp',
        answersOn: answering(false),
      );
      addTearDown(service.dispose);

      expect(
        await service.stillThere(peer(invitePort: 0)),
        isTrue,
      );
    });

    test('is probed on its session port when it is serving one', () async {
      // A sender with no invitation port still has a server worth checking.
      var asked = 0;
      final service = LanDiscoveryService(
        serviceType: '_ddliveness._tcp',
        answersOn: (_, port) async {
          asked = port;
          return true;
        },
      );
      addTearDown(service.dispose);

      await service.stillThere(peer(invitePort: 0, port: 8000));
      expect(asked, equals(8000));
    });
  });
}

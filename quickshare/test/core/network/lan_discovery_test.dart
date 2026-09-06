import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/lan_discovery.dart';

void main() {
  final here = InternetAddress('192.168.1.50');
  final there = InternetAddress('192.168.1.77');

  DiscoveryAnnouncement announcement({
    String id = 'peer-1',
    String name = 'Pixel',
    String platform = 'android',
    int port = 0,
    String fingerprint = '',
  }) =>
      DiscoveryAnnouncement(
        id: id,
        name: name,
        platform: platform,
        port: port,
        tlsFingerprint: fingerprint,
      );

  group('DiscoveryAnnouncement', () {
    test('survives a round trip', () {
      final original = announcement(port: 8000, fingerprint: 'abc123');
      final decoded = DiscoveryAnnouncement.decode(original.encode());

      expect(decoded, isNotNull);
      expect(decoded!.id, equals(original.id));
      expect(decoded.name, equals(original.name));
      expect(decoded.platform, equals(original.platform));
      expect(decoded.port, equals(8000));
      expect(decoded.tlsFingerprint, equals('abc123'));
    });

    test('an idle device carries neither a port nor a fingerprint', () {
      // Both are session facts. A device that is merely present has no server
      // and therefore no certificate, and every byte here goes out several
      // times a second to everyone in the room.
      final json = jsonDecode(utf8.decode(announcement().encode()))
          as Map<String, dynamic>;

      expect(json.containsKey('p'), isFalse);
      expect(json.containsKey('tf'), isFalse);
    });

    test('anything that is not ours decodes to null rather than throwing', () {
      // This runs on every packet arriving on a shared multicast group, so a
      // neighbour's unrelated traffic is an ordinary event.
      expect(DiscoveryAnnouncement.decode(utf8.encode('not json')), isNull);
      expect(DiscoveryAnnouncement.decode(utf8.encode('{}')), isNull);
      expect(DiscoveryAnnouncement.decode(utf8.encode('[1,2,3]')), isNull);
      expect(DiscoveryAnnouncement.decode(const [0xff, 0xfe, 0x00]), isNull);
    });

    test('a future protocol version is ignored, not guessed at', () {
      final future = jsonEncode({'v': 99, 'id': 'x', 'n': 'X', 'os': 'linux'});
      expect(DiscoveryAnnouncement.decode(utf8.encode(future)), isNull);
    });

    test('an announcement missing a required field is refused', () {
      final noName = jsonEncode({'v': 1, 'id': 'x', 'os': 'linux'});
      final noId = jsonEncode({'v': 1, 'n': 'X', 'os': 'linux'});
      expect(DiscoveryAnnouncement.decode(utf8.encode(noName)), isNull);
      expect(DiscoveryAnnouncement.decode(utf8.encode(noId)), isNull);
    });

    test('a nonsense port reads as "not serving" rather than as a port', () {
      final bad = jsonEncode(
          {'v': 1, 'id': 'x', 'n': 'X', 'os': 'linux', 'p': 999999});
      expect(DiscoveryAnnouncement.decode(utf8.encode(bad))!.port, equals(0));
    });

    test('the query packet is recognised and is not an announcement', () {
      expect(DiscoveryAnnouncement.isQuery(DiscoveryAnnouncement.encodeQuery()),
          isTrue);
      expect(DiscoveryAnnouncement.isQuery(announcement().encode()), isFalse);
      expect(DiscoveryAnnouncement.decode(DiscoveryAnnouncement.encodeQuery()),
          isNull);
    });
  });

  group('PeerRegistry', () {
    test('a peer heard twice is one row, not two', () {
      final registry = PeerRegistry();
      final now = DateTime(2026, 9, 6, 12);

      registry.record(announcement(), there, now);
      registry.record(announcement(), there, now.add(const Duration(seconds: 1)));

      expect(registry.visible(now.add(const Duration(seconds: 1))), hasLength(1));
    });

    test('a repeat that says nothing new reports no change', () {
      // The list on screen redraws on every change this returns, and a
      // heartbeat arrives every two seconds from every device in the room.
      final registry = PeerRegistry();
      final now = DateTime(2026, 9, 6, 12);

      expect(registry.record(announcement(), there, now), isTrue);
      expect(
        registry.record(announcement(), there,
            now.add(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('a peer that starts serving is a change worth redrawing for', () {
      final registry = PeerRegistry();
      final now = DateTime(2026, 9, 6, 12);

      registry.record(announcement(), there, now);
      final changed = registry.record(
        announcement(port: 8000, fingerprint: 'abc'),
        there,
        now.add(const Duration(seconds: 1)),
      );

      expect(changed, isTrue);
      expect(registry.visible(now).single.isServing, isTrue);
    });

    test('a peer that moved to another address is followed, not duplicated',
        () {
      final registry = PeerRegistry();
      final now = DateTime(2026, 9, 6, 12);

      registry.record(announcement(), there, now);
      registry.record(announcement(), InternetAddress('192.168.1.99'), now);

      final visible = registry.visible(now);
      expect(visible, hasLength(1));
      expect(visible.single.address.address, equals('192.168.1.99'));
    });

    test('our own announcement never appears in the list', () {
      // It comes straight back to us on the group, and a screen that means
      // "devices near you" listing this device is nonsense.
      final registry = PeerRegistry();
      final now = DateTime(2026, 9, 6, 12);

      final changed = registry.record(
        announcement(id: 'me'),
        here,
        now,
        ignoreId: 'me',
      );

      expect(changed, isFalse);
      expect(registry.visible(now), isEmpty);
    });

    test('a peer nobody has heard from disappears', () {
      final registry = PeerRegistry();
      final now = DateTime(2026, 9, 6, 12);

      registry.record(announcement(), there, now);
      final later = now.add(PeerRegistry.presenceTimeout * 2);

      expect(registry.visible(later), isEmpty);
      expect(registry.prune(later), isTrue);
    });

    test('one lost packet does not blink a device out of the list', () {
      // Wi-Fi drops individual multicast datagrams routinely. The timeout is
      // several announcement intervals for exactly this reason.
      final registry = PeerRegistry();
      final now = DateTime(2026, 9, 6, 12);

      registry.record(announcement(), there, now);
      final oneMissed = now.add(LanDiscoveryService.announceInterval * 2);

      expect(registry.visible(oneMissed), hasLength(1));
    });

    test('two devices are two rows, newest first', () {
      final registry = PeerRegistry();
      final now = DateTime(2026, 9, 6, 12);

      registry.record(announcement(id: 'a', name: 'Older'), there, now);
      registry.record(
        announcement(id: 'b', name: 'Newer'),
        InternetAddress('192.168.1.88'),
        now.add(const Duration(seconds: 1)),
      );

      final visible = registry.visible(now.add(const Duration(seconds: 1)));
      expect(visible.map((p) => p.name), equals(['Newer', 'Older']));
    });

    test('pruning nothing reports nothing', () {
      final registry = PeerRegistry();
      final now = DateTime(2026, 9, 6, 12);

      registry.record(announcement(), there, now);
      expect(registry.prune(now), isFalse);
    });
  });

  group('LanDiscoveryService', () {
    test('the group is link-local, so it cannot leave the subnet', () {
      // 224.0.0.0/24 is not forwarded by routers, which is exactly the reach
      // "devices near you" should have.
      expect(LanDiscoveryService.multicastGroup.address, startsWith('224.0.0.'));
    });

    test('a service that never started stops without complaint', () async {
      final service = LanDiscoveryService();
      await service.stop();
      expect(service.isRunning, isFalse);
      await service.dispose();
    });
  });
}

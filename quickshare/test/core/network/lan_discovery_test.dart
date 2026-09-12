import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsd/nsd.dart' as nsd;

import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/network_info_service.dart';

void main() {
  const announcement = DiscoveryAnnouncement(
    id: 'peer-1',
    name: 'Bob Desktop',
    platform: 'windows',
  );

  Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));

  /// A resolved service as the platform would hand one back.
  nsd.Service service({
    Map<String, Uint8List?>? txt,
    List<InternetAddress>? addresses,
    int port = 1,
  }) =>
      nsd.Service(
        name: 'Bob Desktop',
        type: LanDiscoveryService.serviceType,
        port: port,
        addresses: addresses ?? [InternetAddress('192.168.1.42')],
        txt: txt ?? announcement.toTxt(),
      );

  group('what this device publishes', () {
    test('carries what it takes to draw a row and open a socket', () {
      const serving = DiscoveryAnnouncement(
        id: 'peer-1',
        name: 'Bob Desktop',
        platform: 'windows',
        port: 8000,
        tlsFingerprint: 'the-fingerprint',
        invitePort: 62810,
      );

      final peer = DiscoveryAnnouncement.peerFrom(service(txt: serving.toTxt()));

      expect(peer, isNotNull);
      expect(peer!.id, equals('peer-1'));
      expect(peer.name, equals('Bob Desktop'));
      expect(peer.platform, equals('windows'));
      expect(peer.port, equals(8000));
      expect(peer.tlsFingerprint, equals('the-fingerprint'));
      expect(peer.invitePort, equals(62810));
      expect(peer.isServing, isTrue);
      expect(peer.acceptsInvitations, isTrue);
    });

    test('an idle device advertises neither a port nor a fingerprint', () {
      // Both are session facts. A device that is merely present has no server
      // and therefore no certificate, and a TXT record has a few hundred bytes
      // to spend before it starts costing.
      final txt = announcement.toTxt();

      expect(txt.containsKey('p'), isFalse);
      expect(txt.containsKey('tf'), isFalse);
      expect(txt.containsKey('ip'), isFalse);
    });

    test('a device that only receives says so, and is not "serving"', () {
      const receiving = DiscoveryAnnouncement(
        id: 'peer-1',
        name: 'Bob Desktop',
        platform: 'windows',
        invitePort: 62810,
      );

      final peer =
          DiscoveryAnnouncement.peerFrom(service(txt: receiving.toTxt()));

      expect(peer!.acceptsInvitations, isTrue);
      expect(peer.isServing, isFalse,
          reason: 'ready to be sent to is not the same as offering something');
    });
  });

  group('reading somebody else', () {
    test('a record from another version is ignored, not guessed at', () {
      final txt = announcement.toTxt()..['v'] = bytes('99');
      expect(DiscoveryAnnouncement.peerFrom(service(txt: txt)), isNull);
    });

    test('a record missing what a row needs is refused', () {
      for (final key in ['id', 'n', 'os']) {
        final txt = announcement.toTxt()..remove(key);
        expect(DiscoveryAnnouncement.peerFrom(service(txt: txt)), isNull,
            reason: 'without "$key" there is nothing to draw');
      }
    });

    test('a service with no address is refused', () {
      // However well-formed the rest is, there is nothing to connect to.
      expect(
        DiscoveryAnnouncement.peerFrom(service(addresses: const [])),
        isNull,
      );
    });

    test('an address in TXT "a" record is used when service.addresses is empty', () {
      final txt = announcement.toTxt()..['a'] = bytes('192.168.3.100');
      final peer = DiscoveryAnnouncement.peerFrom(
        service(txt: txt, addresses: const []),
      );
      expect(peer, isNotNull);
      expect(peer!.address.address, equals('192.168.3.100'));
    });

    test('a loopback address in TXT "a" is rejected in favor of service.addresses', () {
      final txt = announcement.toTxt()..['a'] = bytes('127.0.0.1');
      final peer = DiscoveryAnnouncement.peerFrom(
        service(txt: txt, addresses: [InternetAddress('192.168.3.200')]),
      );
      expect(peer, isNotNull);
      expect(peer!.address.address, equals('192.168.3.200'));
    });

    test('real address in service.addresses is preferred over conflicting TXT "a" record', () {
      final txt = announcement.toTxt()..['a'] = bytes('10.99.99.99');
      final peer = DiscoveryAnnouncement.peerFrom(
        service(txt: txt, addresses: [InternetAddress('192.168.3.200')]),
      );
      expect(peer, isNotNull);
      expect(peer!.address.address, equals('192.168.3.200'));
    });

    test('IPv4 is preferred when a device answers on both', () {
      final peer = DiscoveryAnnouncement.peerFrom(service(addresses: [
        InternetAddress('fe80::1'),
        InternetAddress('192.168.1.42'),
      ]));

      expect(peer!.address.address, equals('192.168.1.42'));
    });

    test('a nonsense port reads as "not serving" rather than as a port', () {
      final txt = announcement.toTxt()..['p'] = bytes('999999');
      expect(DiscoveryAnnouncement.peerFrom(service(txt: txt))!.port, isZero);
    });

    test('bytes that are not text do not take the whole record down', () {
      // TXT values are opaque binary on Apple platforms, so anything can turn
      // up in one.
      final txt = announcement.toTxt()
        ..['tf'] = Uint8List.fromList([0xff, 0xfe, 0x00]);

      final peer = DiscoveryAnnouncement.peerFrom(service(txt: txt));
      expect(peer, isNotNull);
      expect(peer!.tlsFingerprint, isEmpty);
    });

    test('an empty TXT map is refused rather than crashing', () {
      expect(DiscoveryAnnouncement.peerFrom(service(txt: {})), isNull);
    });
  });

  group('LanDiscoveryService', () {
    test('advertises the service type both Apple platforms declare', () {
      // iOS refuses to browse a type that is not in NSBonjourServices, so this
      // string existing in both Info.plists is load-bearing.
      expect(LanDiscoveryService.serviceType, equals('_directdrop._tcp'));
    });

    test('a service that never started stops without complaint', () async {
      final service = LanDiscoveryService();
      await service.stop();
      expect(service.isRunning, isFalse);
      await service.dispose();
    });

    test('local IP change during reconcile triggers announcement update with new IP in TXT', () async {
      final fakeNet = _FakeNetworkInfoService();
      DiscoveryAnnouncement? synced;
      final service = LanDiscoveryService(
        networkInfo: fakeNet,
        onSelfUpdated: (a) => synced = a,
      );

      const initialAnnouncement = DiscoveryAnnouncement(
        id: 'self-1',
        name: 'My Mac',
        platform: 'macos',
        ipAddress: '192.168.1.50',
      );
      await service.update(initialAnnouncement);
      expect(service.selfAnnouncement?.ipAddress, equals('192.168.1.50'));

      // Simulate network change
      fakeNet.ip = '192.168.1.99';

      final fakeDiscovery = nsd.Discovery('d-1');
      await service.reconcilePassForTest(fakeDiscovery);

      expect(service.selfAnnouncement?.ipAddress, equals('192.168.1.99'));
      expect(synced?.ipAddress, equals('192.168.1.99'));
      final txt = service.selfAnnouncement!.toTxt();
      expect(utf8.decode(txt['a']!), equals('192.168.1.99'));

      await service.dispose();
    });
  });
}

class _FakeNetworkInfoService extends Fake implements NetworkInfoService {
  String? ip = '192.168.1.50';
  @override
  Future<String?> getLocalIpAddress() async => ip;
}

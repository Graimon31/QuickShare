import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';

void main() {
  group('IceServers.expandTransports', () {
    test('offers TCP/TLS on 443 before plain UDP', () {
      // Under the split-tunnel VPN on the target setup, UDP to 3478 is
      // unreliable while TCP/TLS to 443 is what the tunnel carries all day.
      final urls = IceServers.expandTransports('turn:relay.example.com:3478');
      expect(urls.first, equals('turn:relay.example.com:443?transport=tcp'));
      expect(urls[1], equals('turns:relay.example.com:443?transport=tcp'));
      expect(urls.last, equals('turn:relay.example.com:3478'));
    });

    test('keeps an explicitly spelled-out URL untouched', () {
      const explicit = 'turn:relay.example.com:5349?transport=tcp';
      expect(IceServers.expandTransports(explicit), equals([explicit]));
      expect(IceServers.expandTransports('turns:a.example.com:443'),
          equals(['turns:a.example.com:443']));
    });

    test('ignores blank entries', () {
      expect(IceServers.expandTransports(''), isEmpty);
      expect(IceServers.expandTransports('   '), isEmpty);
    });
  });

  group('IceServers.build', () {
    test('STUN entries never carry credentials', () {
      final servers = IceServers.build(
        stunUrls: ['stun:stun.example.com:3478'],
        turnUrls: const [],
      );
      expect(servers.single.containsKey('username'), isFalse);
      expect(servers.single.containsKey('credential'), isFalse);
    });

    test('TURN entries carry the supplied credentials', () {
      final servers = IceServers.build(
        stunUrls: const [],
        turnUrls: ['turn:relay.example.com:443?transport=tcp'],
        username: 'u',
        credential: 'c',
      );
      expect(servers.single['username'], equals('u'));
      expect(servers.single['credential'], equals('c'));
    });

    test('omits credentials when none were configured', () {
      final servers = IceServers.build(
        stunUrls: const [],
        turnUrls: ['turn:relay.example.com:443?transport=tcp'],
        username: '',
        credential: '',
      );
      expect(servers.single.containsKey('username'), isFalse);
    });

    test('keeps a direct path available rather than forcing relay', () {
      expect(IceServers.configuration()['iceTransportPolicy'], equals('all'));
    });
  });
}

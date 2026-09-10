import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/constants/app_constants.dart';
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

    test('drops a TURN entry entirely when it has no credentials', () {
      // DD-05. A TURN URL that cannot authenticate is not a fallback:
      // libwebrtc dials it, fails the 401, and spends a native slot and a
      // gathering query doing it. Without credentials there is simply no
      // relay, and a session that needs one reaches the fallback screen.
      final servers = IceServers.build(
        stunUrls: const ['stun:stun.example.com:3478'],
        turnUrls: ['turn:relay.example.com:443?transport=tcp'],
        username: '',
        credential: '',
      );
      expect(servers, hasLength(1));
      expect(servers.single['urls'], equals('stun:stun.example.com:3478'));
    });

    test('the release default carries no baked-in relay', () {
      // No public TURN username or password ships in the binary, and the
      // default URL is empty, so an unconfigured build gathers STUN only.
      expect(AppConstants.turnUsername, isEmpty);
      expect(AppConstants.turnCredential, isEmpty);
      final servers = IceServers.build();
      expect(servers.every((srv) => !srv.containsKey('credential')), isTrue);
    });

    test('keeps a direct path available rather than forcing relay', () {
      expect(IceServers.configuration()['iceTransportPolicy'], equals('all'));
    });

    test('never hands libwebrtc more ICE servers than its C array holds', () {
      // flutter_webrtc writes ice_servers[i] with no bounds check.
      // kMaxIceServerSize is 8; a ninth entry is a native overflow that
      // kills the Windows process inside createPeerConnection.
      final overflowing = IceServers.build(
        stunUrls: const ['s1', 's2', 's3', 's4', 's5'],
        turnUrls: List.generate(
            6, (i) => 'turn:relay$i.example.com:443?transport=tcp'),
        username: 'u',
        credential: 'c',
      );
      expect(overflowing.length, lessThanOrEqualTo(IceServers.maxIceServers));
      expect(
        (IceServers.configuration()['iceServers'] as List).length,
        lessThanOrEqualTo(IceServers.maxIceServers),
      );
    });

    test('drops extra STUN rather than a TURN transport when the list overflows',
        () {
      final servers = IceServers.build(
        stunUrls: const [
          'stun:a',
          'stun:b',
          'stun:c',
          'stun:d',
          'stun:e',
        ],
        turnUrls: const [
          'turn:x:443?transport=tcp',
          'turns:x:443?transport=tcp',
          'turn:x:80?transport=tcp',
          'turn:x:3478',
        ],
        username: 'u',
        credential: 'c',
      );
      expect(servers, hasLength(IceServers.maxIceServers));
      final urls = servers.map((s) => s['urls']).toList();
      expect(urls, contains('turn:x:443?transport=tcp'));
      expect(urls, contains('turns:x:443?transport=tcp'));
      expect(urls, contains('turn:x:80?transport=tcp'));
      expect(urls, contains('turn:x:3478'));
      expect(urls, isNot(contains('stun:e')));
    });

    test('configurationWithTurnServers also stays within the libwebrtc cap', () {
      final turn = [
        for (var i = 0; i < 10; i++)
          <String, dynamic>{
            'urls': 'turn:relay$i.example.com:443?transport=tcp',
            'username': 'u',
            'credential': 'c',
          },
      ];
      final config = IceServers.configurationWithTurnServers(turn);
      expect(
        (config['iceServers'] as List).length,
        lessThanOrEqualTo(IceServers.maxIceServers),
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';

void main() {
  const stun = {'urls': 'stun:stun.example.org:3478'};
  const urls = [
    'turn:relay.example.org:3478?transport=udp',
    'turn:relay.example.org:443?transport=tcp',
    'turns:relay.example.org:443?transport=tcp',
  ];
  final servers = <Map<String, dynamic>>[
    stun,
    {'urls': urls, 'username': 'test-user', 'credential': 'test-password'},
  ];

  for (final mode in ['udp', 'tcp', 'tls']) {
    test('the $mode probe retains STUN and the matching relay credentials', () {
      final restricted =
          IceServers.restrictTurnTransport(servers, only: mode, debug: true);
      expect(restricted.first, stun);
      expect(restricted.last['urls'], [
        urls[['udp', 'tcp', 'tls'].indexOf(mode)]
      ]);
      expect(restricted.last['username'], 'test-user');
      expect(restricted.last['credential'], 'test-password');
      expect(servers.last['urls'], urls, reason: 'do not mutate shared setup');
    });
  }

  test('release builds ignore the probe and keep every relay path', () {
    expect(IceServers.restrictTurnTransport(servers, only: 'tls', debug: false),
        servers);
  });

  test('an unrecognized probe cannot remove working relay routes', () {
    expect(
        IceServers.restrictTurnTransport(servers, only: 'https', debug: true),
        servers);
  });
}

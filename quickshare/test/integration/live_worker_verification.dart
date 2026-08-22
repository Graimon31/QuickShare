// A hand-run diagnostic against the DEPLOYED Worker, not a unit test: it needs
// the network and a live Cloudflare account, so it is deliberately not named
// `*_test.dart` and never runs in CI.
//
//     flutter test test/integration/live_worker_verification.dart
//
// It answers the one question the stubbed tests cannot: does the shape the
// real Worker returns survive TurnCredentialService and come out as something
// RTCPeerConnection would accept.
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/turn_credential_service.dart';

const workerUrl = 'https://directdrop-worker.directdrop-worker.workers.dev';

void main() {
  test('the live Worker feeds TurnCredentialService a usable ICE config',
      () async {
    final servers =
        await TurnCredentialService(baseUrl: workerUrl).fetchIceServers();

    print('=== iceServers from the live Worker ===');
    for (final s in servers) {
      final urls = s['urls'];
      final hasCreds = s['username'] != null && s['credential'] != null;
      print('  ${urls is List ? urls.join(', ') : urls}'
          '${hasCreds ? '   [credentials present]' : ''}');
      // The Dart side hands these straight to RTCPeerConnection, which wants a
      // list here.
      expect(urls, isA<List>(), reason: 'urls must be a list, got $urls');
    }

    final relays = servers.where((s) => s['username'] != null).toList();
    expect(relays, isNotEmpty, reason: 'no relay carried credentials');

    final firstRelayUrl = (relays.first['urls'] as List).first as String;
    expect(firstRelayUrl, startsWith('turns:'),
        reason: 'TLS on 443 must be offered before plain UDP — it is the only '
            'transport the always-on VPN reliably carries');
    expect(firstRelayUrl, contains('443'));

    print('\n=== merged configuration handed to createPeerConnection ===');
    final config = await IceServers.configurationDynamic(workerBaseUrl: workerUrl);
    final merged = config['iceServers'] as List;
    print('  ${merged.length} entries, policy=${config['iceTransportPolicy']}');

    // The static STUN pool and the Worker both list stun.cloudflare.com;
    // gathering it twice wastes part of a 6-second ceiling.
    final allUrls = merged
        .expand((s) {
          final raw = (s as Map)['urls'];
          return raw is List ? raw.cast<String>() : <String>[raw as String];
        })
        .toList();
    for (final url in allUrls.toSet()) {
      final n = allUrls.where((u) => u == url).length;
      expect(n, equals(1), reason: '$url appears $n times');
    }
    print('  no duplicate URLs');
    print('  ${allUrls.where((u) => u.startsWith('turns:')).length} TLS relay, '
        '${allUrls.where((u) => u.startsWith('turn:')).length} plain relay, '
        '${allUrls.where((u) => u.startsWith('stun:')).length} STUN');
  }, timeout: const Timeout(Duration(seconds: 60)));
}

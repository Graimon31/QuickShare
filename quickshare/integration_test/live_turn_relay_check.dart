// Does a TURN relay actually work from this machine, right now?
//
// The automated equivalent of pasting credentials into the trickle-ICE page:
// live credentials from the deployed Worker, a real RTCPeerConnection, and
// `iceTransportPolicy: 'relay'` so that ONLY relay candidates may be gathered.
// One relay candidate appearing proves the whole chain — Worker, credentials,
// TURN allocation over TLS/443, and the VPN carrying it.
//
//     flutter test integration_test/live_turn_relay_check.dart -d macos
//
// NET-02-B, the app's own configuration forced to relay-only, needs the debug
// switch as well:
//
//     flutter test integration_test/live_turn_relay_check.dart -d macos \
//         --dart-define=QUICKSHARE_FORCE_RELAY=true
//
// `POST /turn` is public, so there is no secret to pass to either run.
//
// Needs the network and the deployed Worker, so it lives here rather than in
// `test/`, and is never part of a CI run.
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/turn_credential_service.dart';

const workerUrl = 'https://directdrop-worker.directdrop-worker.workers.dev';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Offers exactly one TURN URL and reports whether an allocation happened.
  ///
  /// Per transport rather than all at once: with the whole list offered, ICE
  /// returns as soon as any one of them works, and the fastest is UDP — which
  /// says nothing about whether TLS/443 would have worked. Under the VPN it is
  /// TLS/443 that has to, so it gets measured on its own.
  Future<({int count, int? firstMs})> probe(
      String url, Map<String, dynamic> credentials) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {
          'urls': [url],
          'username': credentials['username'],
          'credential': credentials['credential'],
        }
      ],
      // Relay-only: a host or srflx candidate cannot be gathered at all, so
      // anything appearing here came through TURN.
      'iceTransportPolicy': IceServers.transportPolicy(forceRelay: true),
    });

    var count = 0;
    int? firstMs;
    final first = Completer<void>();
    final started = DateTime.now();

    pc.onIceCandidate = (candidate) {
      final c = candidate.candidate;
      if (c == null || !c.contains(' typ relay')) return;
      count++;
      firstMs ??= DateTime.now().difference(started).inMilliseconds;
      if (!first.isCompleted) first.complete();
    };

    // Without an m-section ICE gathers nothing at all, which looks exactly
    // like a blocked relay.
    await pc.createDataChannel('probe', RTCDataChannelInit());
    await pc.setLocalDescription(await pc.createOffer({}));

    try {
      await first.future.timeout(const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(seconds: 2));
    } on TimeoutException {
      // Leaves count at 0, which is the result.
    }

    await pc.close();
    return (count: count, firstMs: firstMs);
  }

  testWidgets('TURN relays are reachable from this network, per transport',
      (tester) async {
    final servers =
        await TurnCredentialService(baseUrl: workerUrl).fetchIceServers();
    final withCreds = servers.firstWhere((s) => s['username'] != null);

    final urls = servers
        .where((s) => s['username'] != null)
        .expand((s) => (s['urls'] as List).cast<String>())
        .toList();

    print('\n=== TURN allocation, one transport at a time ===');
    final results = <String, ({int count, int? firstMs})>{};
    for (final url in urls) {
      final r = await probe(url, withCreds);
      results[url] = r;
      print(r.count > 0
          ? '  OK    $url  — ${r.count} candidate(s), first in ${r.firstMs}ms'
          : '  FAIL  $url  — no allocation in 20s');
    }

    final tls = results.entries
        .where((e) => e.key.startsWith('turns:') && e.key.contains('443'));
    expect(tls, isNotEmpty, reason: 'the Worker offered no TLS/443 relay');
    expect(
      tls.first.value.count,
      greaterThan(0),
      reason: 'TLS on 443 produced no relay candidate. This is the transport '
          'the always-on VPN is expected to carry, and ТЗ criterion #1 '
          'depends on it.',
    );
  }, timeout: const Timeout(Duration(seconds: 180)));

  // NET-02-B. The test above builds its own configuration, one transport at a
  // time. This one takes the configuration the app itself would hand to
  // `createPeerConnection` — the Worker fetch, the merge, the STUN trimming —
  // with the debug switch on, and checks the two things a forced-relay
  // session depends on: the policy really is `relay`, and a relay candidate is
  // gathered while nothing else is.
  testWidgets(
    'NET-02-B: the app\'s own configuration, forced to relay, gathers only relay',
    (tester) async {
      final setup = await IceServers.configurationDynamic(workerBaseUrl: workerUrl);
      expect(setup.relayAvailable, isTrue,
          reason: 'no relay in the app\'s configuration: ${setup.relayUnavailable}');
      expect(setup.configuration['iceTransportPolicy'], equals('relay'));

      final pc = await createPeerConnection(setup.configuration);
      final kinds = <String>{};
      final relay = Completer<void>();
      pc.onIceCandidate = (candidate) {
        final c = candidate.candidate;
        if (c == null || c.isEmpty) return;
        final kind = RegExp(r' typ (\w+)').firstMatch(c)?.group(1) ?? 'unknown';
        kinds.add(kind);
        if (kind == 'relay' && !relay.isCompleted) relay.complete();
      };
      await pc.createDataChannel('probe', RTCDataChannelInit());
      await pc.setLocalDescription(await pc.createOffer({}));

      try {
        await relay.future.timeout(const Duration(seconds: 20));
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        await pc.close();
      }

      print('\n=== candidate kinds gathered under relay-only: $kinds ===');
      expect(kinds, contains('relay'));
      expect(kinds.difference({'relay'}), isEmpty,
          reason: 'a non-relay candidate means the policy was not applied');
    },
    // Only meaningful with the debug switch on; without it the configuration
    // is `all` by design and there is nothing to check.
    skip: !AppConstants.forceRelay,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

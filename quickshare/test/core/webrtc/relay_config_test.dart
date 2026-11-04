// NET-02-D at the configuration level — a build made with no `--dart-define`
// at all has a route to TURN.
//
// The relay is not optional on the target setup: a permanent VPN makes NAT act
// as symmetric, so relayed traffic is the ordinary path there. `POST /turn` is
// public now, so nothing has to be baked into a build for the app to get
// credentials — except the Worker's address, and that has a default. The old
// client refused to call the Worker unless `QUICKSHARE_TURN_SECRET` was set,
// which a CI build never has; the symptom was a release that quietly ran
// without a relay.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';

String? _find(String relative) {
  for (final base in ['.', 'quickshare', '..']) {
    final candidate = '$base/$relative';
    if (FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound) {
      return candidate;
    }
  }
  return null;
}

void main() {
  group('a build with no --dart-define', () {
    test('knows where the Worker is', () {
      const url = AppConstants.workerBaseUrl;

      expect(url.trim(), isNotEmpty);
      final uri = Uri.parse(url);
      expect(uri.scheme, equals('https'));
      expect(uri.host, isNotEmpty);
    });

    test('has the Worker rendezvous channel enabled as well', () {
      expect(AppConstants.workerRendezvousEnabled, isTrue);
    });

    test('is not forced into relay-only', () {
      // QUICKSHARE_FORCE_RELAY exists for one hand-run check and must be off
      // unless somebody turns it on.
      expect(AppConstants.forceRelay, isFalse);
      expect(IceServers.transportPolicy(), equals('all'));
    });
  });

  group('the relay-only switch', () {
    test('relay-only is spelled the way libwebrtc spells it', () {
      expect(IceServers.transportPolicy(forceRelay: true), equals('relay'));
      expect(IceServers.transportPolicy(forceRelay: false), equals('all'));
    });

    test('shapes the configuration, nothing else', () {
      final relayOnly = IceServers.configurationWithTurnServers(const [
        {
          'urls': ['turns:turn.example.com:443?transport=tcp'],
          'username': 'u',
          'credential': 'c',
        }
      ], forceRelay: true);
      final normal = IceServers.configurationWithTurnServers(const [
        {
          'urls': ['turns:turn.example.com:443?transport=tcp'],
          'username': 'u',
          'credential': 'c',
        }
      ]);

      expect(relayOnly['iceTransportPolicy'], equals('relay'));
      expect(normal['iceTransportPolicy'], equals('all'));
      expect(relayOnly['iceServers'], equals(normal['iceServers']));
    });
  });

  group('the client carries no TURN secret', () {
    // Read from the files rather than listed by hand: the thing being guarded
    // is a reference creeping back into a place nobody thought to list.
    const forbidden = [
      'QUICKSHARE_TURN_SECRET',
      'turnClientSecret',
      'signedHeaders',
      'X-DD-',
    ];
    const roots = [
      'lib',
      'integration_test',
      'test/integration',
      'tools',
      'scripts',
      '../.github/workflows',
    ];

    test('nothing in the app, its hand-run checks, tools or CI mentions it',
        () {
      final hits = <String>[];
      var scanned = 0;
      for (final root in roots) {
        final path = _find(root);
        if (path == null) continue;
        for (final entity in Directory(path).listSync(recursive: true)) {
          if (entity is! File) continue;
          final name = entity.path;
          if (name.contains('/.dart_tool/') || name.contains('/build/')) continue;
          if (!RegExp(r'\.(dart|sh|bat|py|ya?ml|json|toml|md)$').hasMatch(name)) {
            continue;
          }
          scanned++;
          final text = entity.readAsStringSync();
          for (final needle in forbidden) {
            if (text.contains(needle)) hits.add('$name mentions $needle');
          }
        }
      }
      expect(scanned, greaterThan(50), reason: 'the scan found nothing to read');
      expect(hits, isEmpty);
    });

    test('the live hand-run checks call the Worker without any secret', () {
      for (final path in [
        'test/integration/live_worker_verification.dart',
        'integration_test/live_turn_relay_check.dart',
      ]) {
        final file = _find(path);
        expect(file, isNotNull, reason: path);
        final text = File(file!).readAsStringSync();
        expect(text, contains('TurnCredentialService(baseUrl:'));
        expect(text, isNot(contains('clientSecret')));
      }
    });
  });
}

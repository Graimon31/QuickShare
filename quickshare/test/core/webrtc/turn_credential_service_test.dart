// Exercises TurnCredentialService and IceServers.configurationDynamic against
// a tiny local HTTP server standing in for the DirectDrop Worker's `/turn`
// endpoint (the real Worker runs on Cloudflare's runtime, not under
// `flutter test`).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/turn_credential_service.dart';

void main() {
  group('TurnCredentialService', () {
    late HttpServer server;
    late String baseUrl;

    tearDown(() async {
      await server.close(force: true);
    });

    test('merges cloudflare and metered iceServers from the /turn response',
        () async {
      server = await shelf_io.serve(
        (request) => Response.ok(
          jsonEncode({
            'cloudflare': {
              'iceServers': [
                {
                  'urls': ['turns:turn.cloudflare.com:443?transport=tcp'],
                  'username': 'cf-user',
                  'credential': 'cf-cred',
                }
              ]
            },
            'metered': {
              'iceServers': [
                {
                  'urls': ['turns:standard.relay.metered.ca:443?transport=tcp'],
                  'username': 'metered-user',
                  'credential': 'metered-cred',
                }
              ]
            },
            'expiresAt': DateTime.now().toIso8601String(),
          }),
          headers: {'Content-Type': 'application/json'},
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      baseUrl = 'http://127.0.0.1:${server.port}';

      final servers =
          await TurnCredentialService(baseUrl: baseUrl, clientSecret: 's3cret').fetchIceServers();

      expect(servers, hasLength(2));
      expect(servers[0]['username'], equals('cf-user'));
      expect(servers[1]['username'], equals('metered-user'));
    });

    test('succeeds when only one provider comes back', () async {
      server = await shelf_io.serve(
        (request) => Response.ok(
          jsonEncode({
            'metered': {
              'iceServers': [
                {
                  'urls': ['turns:standard.relay.metered.ca:443?transport=tcp'],
                  'username': 'metered-user',
                  'credential': 'metered-cred',
                }
              ]
            },
            'expiresAt': DateTime.now().toIso8601String(),
          }),
          headers: {'Content-Type': 'application/json'},
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      baseUrl = 'http://127.0.0.1:${server.port}';

      final servers =
          await TurnCredentialService(baseUrl: baseUrl, clientSecret: 's3cret').fetchIceServers();
      expect(servers, hasLength(1));
    });

    test('throws when the Worker reports no provider available', () async {
      server = await shelf_io.serve(
        (request) => Response.internalServerError(
          body: jsonEncode({'error': 'no TURN provider available'}),
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      baseUrl = 'http://127.0.0.1:${server.port}';

      expect(
        () => TurnCredentialService(baseUrl: baseUrl, clientSecret: 's3cret').fetchIceServers(),
        throwsA(anything),
      );
    });

    test('does not call /turn when no client secret is configured', () async {
      var called = false;
      server = await shelf_io.serve(
        (request) {
          called = true;
          return Response.ok('{}');
        },
        InternetAddress.loopbackIPv4,
        0,
      );
      baseUrl = 'http://127.0.0.1:${server.port}';

      expect(
        () => TurnCredentialService(baseUrl: baseUrl, clientSecret: '')
            .fetchIceServers(),
        throwsA(isA<StateError>()),
      );
      expect(called, isFalse);
    });

    test('signs POST /turn so the Worker can refuse a bare curl', () async {
      String? ts;
      String? mac;
      server = await shelf_io.serve(
        (request) {
          ts = request.headers['x-dd-ts'];
          mac = request.headers['x-dd-mac'];
          return Response.ok(
            jsonEncode({
              'cloudflare': {
                'iceServers': [
                  {
                    'urls': ['turns:turn.cloudflare.com:443?transport=tcp'],
                    'username': 'u',
                    'credential': 'c',
                  }
                ]
              },
            }),
            headers: {'Content-Type': 'application/json'},
          );
        },
        InternetAddress.loopbackIPv4,
        0,
      );
      await TurnCredentialService(baseUrl: 'http://127.0.0.1:${server.port}',
              clientSecret: 's3cret')
          .fetchIceServers();
      expect(ts, isNotNull);
      expect(mac, isNotNull);
      expect(mac, hasLength(64));
    });
  });

  group('IceServers.configurationDynamic', () {
    test('falls back to the static configuration when no Worker is set',
        () async {
      final config = await IceServers.configurationDynamic(workerBaseUrl: '');
      expect(config['iceTransportPolicy'], equals('all'));
      expect(config['iceServers'], isNotEmpty);
    });

    test('a STUN server the Worker also returns is not gathered twice', () async {
      // stun.cloudflare.com is in both the static pool and what the Worker
      // sends back; a duplicate costs part of the 6-second gathering ceiling.
      final server = await shelf_io.serve(
        (request) => Response.ok(
          jsonEncode({
            'cloudflare': {
              'iceServers': [
                {
                  'urls': ['stun:stun.cloudflare.com:3478']
                },
                {
                  'urls': ['turns:turn.cloudflare.com:443?transport=tcp'],
                  'username': 'u',
                  'credential': 'c',
                },
              ]
            },
            'expiresAt': DateTime.now().toIso8601String(),
          }),
          headers: {'Content-Type': 'application/json'},
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));

      final config = await IceServers.configurationDynamic(
        workerBaseUrl: 'http://127.0.0.1:${server.port}',
        turnClientSecret: 's3cret',
      );

      final urls = (config['iceServers'] as List)
          .expand((s) {
            final raw = (s as Map)['urls'];
            return raw is List ? raw.cast<String>() : [raw as String];
          })
          .toList();

      expect(
        urls.where((u) => u == 'stun:stun.cloudflare.com:3478').length,
        equals(1),
      );
      // The rest of the static pool survives.
      expect(urls, contains('stun:stun.sipnet.ru:3478'));
      expect(urls, contains('turns:turn.cloudflare.com:443?transport=tcp'));
    });

    test('falls back to the static configuration when the Worker is unreachable',
        () async {
      final config = await IceServers.configurationDynamic(
        workerBaseUrl: 'http://127.0.0.1:1',
      );
      expect(config['iceTransportPolicy'], equals('all'));
      expect(config['iceServers'], isNotEmpty);
    });

    test('default Dio instance configures 4s connect and receive timeouts', () {
      final service = TurnCredentialService(
        baseUrl: 'http://127.0.0.1:8080',
        clientSecret: 's3cret',
      );
      expect(service.dio.options.connectTimeout, equals(const Duration(seconds: 4)));
      expect(service.dio.options.receiveTimeout, equals(const Duration(seconds: 4)));
    });
  });
}

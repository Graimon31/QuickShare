// Exercises TurnCredentialService and IceServers.configurationDynamic against
// a tiny local HTTP server standing in for the DirectDrop Worker's `/turn`
// endpoint (the real Worker runs on Cloudflare's runtime, not under
// `flutter test`).
//
// `POST /turn` is public: no secret, no signature, nothing for the client to
// prove. The Worker limits it on its own side and says so with a small, fixed
// set of answers, and every one of them has to come out the other end as a
// reason the app can act on and tell the person about:
//
//   200 credentials
//   429 rate_limited          (+ Retry-After)
//   503 limiter_unavailable   (+ Retry-After), relay_disabled, relay_unconfigured
//   502 provider_error
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' hide Response;
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/relay_availability.dart';
import 'package:quickshare/core/webrtc/turn_credential_service.dart';

Map<String, Object?> _credentials({bool cloudflare = true, bool metered = true}) =>
    {
      if (cloudflare)
        'cloudflare': {
          'iceServers': [
            {
              'urls': ['turns:turn.cloudflare.com:443?transport=tcp'],
              'username': 'cf-user',
              'credential': 'cf-cred',
            }
          ]
        },
      if (metered)
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
    };

Response _json(int status, Object? body, {Map<String, String>? headers}) =>
    Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json', ...?headers},
    );

/// One answer the Worker can give, and the reason the client must read from it.
class _Case {
  final String name;
  final Response Function() answer;
  final RelayUnavailableReason reason;
  final Duration? retryAfter;
  const _Case(this.name, this.answer, this.reason, {this.retryAfter});
}

final _contract = <_Case>[
  _Case(
    '429 rate_limited',
    () => _json(429, {'error': 'rate_limited', 'scope': 'turn_ip'},
        headers: {'Retry-After': '60'}),
    RelayUnavailableReason.rateLimited,
    retryAfter: const Duration(seconds: 60),
  ),
  _Case(
    '503 limiter_unavailable',
    () => _json(503, {'error': 'limiter_unavailable'},
        headers: {'Retry-After': '60'}),
    RelayUnavailableReason.limiterUnavailable,
    retryAfter: const Duration(seconds: 60),
  ),
  _Case(
    '503 relay_disabled',
    () => _json(503, {'error': 'relay_disabled'}),
    RelayUnavailableReason.relayDisabled,
  ),
  _Case(
    '503 relay_unconfigured',
    () => _json(503, {'error': 'relay_unconfigured'}),
    RelayUnavailableReason.relayUnconfigured,
  ),
  _Case(
    '502 provider_error',
    () => _json(502, {'error': 'provider_error'}),
    RelayUnavailableReason.providerError,
  ),
  _Case(
    '200 with neither provider in it',
    () => _json(200, {'expiresAt': DateTime.now().toIso8601String()}),
    RelayUnavailableReason.malformedResponse,
  ),
  _Case(
    '200 that is not JSON',
    () => Response.ok('<html>captive portal</html>',
        headers: {'Content-Type': 'text/html'}),
    RelayUnavailableReason.malformedResponse,
  ),
  _Case(
    '200 whose iceServers is not a list',
    () => _json(200, {
      'cloudflare': {'iceServers': 'nope'}
    }),
    RelayUnavailableReason.malformedResponse,
  ),
  // Something is in the answer, but nothing in it is a relay. Reading that as
  // "relay available" tells the person one was offered when none was.
  _Case(
    '200 holding only STUN',
    () => _json(200, {
      'cloudflare': {
        'iceServers': [
          {
            'urls': ['stun:stun.cloudflare.com:3478']
          }
        ]
      }
    }),
    RelayUnavailableReason.malformedResponse,
  ),
  _Case(
    '200 with a TURN URL and no credentials',
    () => _json(200, {
      'cloudflare': {
        'iceServers': [
          {
            'urls': ['turns:turn.cloudflare.com:443?transport=tcp']
          }
        ]
      }
    }),
    RelayUnavailableReason.malformedResponse,
  ),
  _Case(
    '200 with a TURN URL and empty credentials',
    () => _json(200, {
      'metered': {
        'iceServers': [
          {
            'urls': ['turn:standard.relay.metered.ca:443'],
            'username': '',
            'credential': ''
          }
        ]
      }
    }),
    RelayUnavailableReason.malformedResponse,
  ),
  _Case(
    '200 with credentials on a STUN URL',
    () => _json(200, {
      'cloudflare': {
        'iceServers': [
          {
            'urls': ['stun:stun.cloudflare.com:3478'],
            'username': 'cf-user',
            'credential': 'cf-cred'
          }
        ]
      }
    }),
    RelayUnavailableReason.malformedResponse,
  ),
];

void main() {
  late HttpServer server;
  late String baseUrl;

  Future<void> serve(FutureOr<Response> Function(Request) handler) async {
    server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
  }

  Future<RelayUnavailable> failureOf(Future<Object?> Function() call) async {
    try {
      await call();
    } on RelayUnavailable catch (e) {
      return e;
    }
    fail('expected a RelayUnavailable, but the call succeeded');
  }

  group('TurnCredentialService', () {
    tearDown(() async {
      await server.close(force: true);
    });

    test('merges cloudflare and metered iceServers from the /turn response',
        () async {
      await serve((request) => _json(200, _credentials()));

      final servers =
          await TurnCredentialService(baseUrl: baseUrl).fetchIceServers();

      expect(servers, hasLength(2));
      expect(servers[0]['username'], equals('cf-user'));
      expect(servers[1]['username'], equals('metered-user'));
    });

    test('a relay is a TURN URL with credentials, wherever in the answer it is',
        () async {
      // STUN from one provider, the relay from the other, and the TURN URL
      // given as a bare string rather than a list: all legal.
      await serve((request) => _json(200, {
            'cloudflare': {
              'iceServers': [
                {
                  'urls': ['stun:stun.cloudflare.com:3478']
                }
              ]
            },
            'metered': {
              'iceServers': [
                {
                  'urls': 'turn:standard.relay.metered.ca:80',
                  'username': 'u',
                  'credential': 'c'
                }
              ]
            },
          }));

      final servers =
          await TurnCredentialService(baseUrl: baseUrl).fetchIceServers();

      expect(servers, hasLength(2));
    });

    test('succeeds when only one provider comes back', () async {
      await serve((request) => _json(200, _credentials(cloudflare: false)));

      final servers =
          await TurnCredentialService(baseUrl: baseUrl).fetchIceServers();
      expect(servers, hasLength(1));
    });

    test('needs no secret, and sends no signature or credential of any kind',
        () async {
      Request? seen;
      await serve((request) {
        seen = request;
        return _json(200, _credentials());
      });

      // The constructor has no secret to give, and the request carries none:
      // a key compiled into a public binary protects nothing.
      await TurnCredentialService(baseUrl: baseUrl).fetchIceServers();

      expect(seen, isNotNull);
      expect(seen!.method, equals('POST'));
      expect(seen!.url.path, equals('turn'));
      final names = seen!.headers.keys.map((k) => k.toLowerCase()).toList();
      expect(names.where((n) => n.startsWith('x-dd-')), isEmpty,
          reason: 'no X-DD-Ts / X-DD-Mac: the HMAC is gone');
      expect(names, isNot(contains('authorization')));
      expect(await seen!.readAsString(), isEmpty,
          reason: 'POST /turn takes no body');
    });

    test('calls the Worker even though no secret is configured anywhere',
        () async {
      // The old client refused to make the call at all without a secret, so a
      // build with no --dart-define silently ran without a relay.
      var called = false;
      await serve((request) {
        called = true;
        return _json(200, _credentials());
      });

      await TurnCredentialService(baseUrl: baseUrl).fetchIceServers();
      expect(called, isTrue);
    });

    for (final c in _contract) {
      test('${c.name} becomes ${c.reason.name}', () async {
        await serve((request) => c.answer());

        final failure = await failureOf(
            () => TurnCredentialService(baseUrl: baseUrl).fetchIceServers());

        expect(failure.reason, equals(c.reason));
        expect(failure.retryAfter, equals(c.retryAfter));
      });
    }

    test('a 429 reports the status and the Retry-After it carried', () async {
      await serve((request) => _json(
          429, {'error': 'rate_limited', 'scope': 'turn_global'},
          headers: {'Retry-After': '90'}));

      final failure = await failureOf(
          () => TurnCredentialService(baseUrl: baseUrl).fetchIceServers());

      expect(failure.reason, equals(RelayUnavailableReason.rateLimited));
      expect(failure.statusCode, equals(429));
      expect(failure.retryAfter, equals(const Duration(seconds: 90)));
      expect(failure.toString(), contains('rateLimited'));
    });

    test('a 429 without a Retry-After leaves the wait for the caller to pick',
        () async {
      await serve((request) => _json(429, {'error': 'rate_limited'}));

      final failure = await failureOf(
          () => TurnCredentialService(baseUrl: baseUrl).fetchIceServers());

      expect(failure.reason, equals(RelayUnavailableReason.rateLimited));
      expect(failure.retryAfter, isNull);
    });

    test('an answer from something that is not the Worker is unreachable',
        () async {
      await serve((request) => Response.notFound('nothing here'));

      final failure = await failureOf(
          () => TurnCredentialService(baseUrl: baseUrl).fetchIceServers());

      expect(failure.reason, equals(RelayUnavailableReason.unreachable));
      expect(failure.statusCode, equals(404));
    });

    test('a Worker that does not answer in time is a timeout', () async {
      await serve((request) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return _json(200, _credentials());
      });
      final impatient = Dio(BaseOptions(
        connectTimeout: const Duration(milliseconds: 200),
        receiveTimeout: const Duration(milliseconds: 200),
      ));

      final failure = await failureOf(() =>
          TurnCredentialService(baseUrl: baseUrl, dio: impatient)
              .fetchIceServers());

      expect(failure.reason, equals(RelayUnavailableReason.timeout));
    });

    test('a Worker nobody is listening for is unreachable', () async {
      await serve((request) => _json(200, _credentials()));
      final dead = TurnCredentialService(baseUrl: 'http://127.0.0.1:1');

      final failure = await failureOf(dead.fetchIceServers);

      expect(failure.reason, equals(RelayUnavailableReason.unreachable));
    });

    test('with no Worker URL it says so without touching the network',
        () async {
      var called = false;
      await serve((request) {
        called = true;
        return _json(200, _credentials());
      });

      final failure = await failureOf(
          () => TurnCredentialService(baseUrl: '  ').fetchIceServers());

      expect(failure.reason, equals(RelayUnavailableReason.noWorkerUrl));
      expect(called, isFalse);
    });
  });

  group('IceServers.configurationDynamic', () {
    tearDown(() async {
      await server.close(force: true);
    });

    test('returns the Worker\'s TURN servers, and says the relay is there',
        () async {
      await serve((request) => _json(200, _credentials()));

      final setup = await IceServers.configurationDynamic(workerBaseUrl: baseUrl);

      expect(setup.relayAvailable, isTrue);
      expect(setup.relayUnavailable, isNull);
      expect(IceServers.containsTurn(setup.configuration), isTrue);
      expect(setup.configuration['iceTransportPolicy'], equals('all'));
      final urls = IceServers.stunUrlsIn([
        for (final s in setup.configuration['iceServers'] as List)
          Map<String, dynamic>.from(s as Map),
      ]);
      expect(urls, contains('turns:turn.cloudflare.com:443?transport=tcp'));
      expect(urls, contains('turns:standard.relay.metered.ca:443?transport=tcp'));
    });

    for (final c in _contract) {
      test('${c.name}: STUN only, and the reason is ${c.reason.name}', () async {
        await serve((request) => c.answer());

        final setup =
            await IceServers.configurationDynamic(workerBaseUrl: baseUrl);

        expect(setup.relayAvailable, isFalse);
        expect(setup.relayUnavailable?.reason, equals(c.reason));
        expect(setup.relayUnavailable?.retryAfter, equals(c.retryAfter));
        expect(IceServers.containsTurn(setup.configuration), isFalse);
        expect(setup.configuration['iceServers'], isNotEmpty,
            reason: 'STUN is still worth gathering');
      });
    }

    group('a relay compiled into the build', () {
      // The Worker failing does not take away a relay the build was given its
      // own credentials for: it is a fallback, and a connection that later
      // fails must not be blamed on a relay that was in the configuration.
      const turnUrls = ['turns:turn.example.com:443?transport=tcp'];

      test('is still a relay when the Worker cannot be reached', () async {
        final setup = await IceServers.configurationDynamic(
          workerBaseUrl: 'http://127.0.0.1:1',
          staticTurnUrls: turnUrls,
          staticUsername: 'build-user',
          staticCredential: 'build-secret',
        );

        expect(setup.relayAvailable, isTrue);
        expect(setup.relayUnavailable, isNull);
        expect(IceServers.containsTurn(setup.configuration), isTrue);
      });

      test('is still a relay when the Worker refuses', () async {
        await serve((request) => _json(429, {'error': 'rate_limited'},
            headers: {'Retry-After': '60'}));

        final setup = await IceServers.configurationDynamic(
          workerBaseUrl: baseUrl,
          staticTurnUrls: turnUrls,
          staticUsername: 'build-user',
          staticCredential: 'build-secret',
        );

        expect(setup.relayAvailable, isTrue);
        expect(setup.relayUnavailable, isNull);
      });

      test('without credentials it is not one, and the reason is kept',
          () async {
        final setup = await IceServers.configurationDynamic(
          workerBaseUrl: 'http://127.0.0.1:1',
          staticTurnUrls: turnUrls,
          staticUsername: '',
          staticCredential: '',
        );

        expect(setup.relayAvailable, isFalse);
        expect(setup.relayUnavailable?.reason,
            equals(RelayUnavailableReason.unreachable));
      });
    });

    test('an unreachable Worker is STUN only, with the reason kept', () async {
      final setup = await IceServers.configurationDynamic(
        workerBaseUrl: 'http://127.0.0.1:1',
      );

      expect(setup.relayAvailable, isFalse);
      expect(setup.relayUnavailable?.reason,
          equals(RelayUnavailableReason.unreachable));
      expect(IceServers.containsTurn(setup.configuration), isFalse);
      expect(setup.configuration['iceTransportPolicy'], equals('all'));
      expect(setup.configuration['iceServers'], isNotEmpty);
    });

    test('no Worker URL is STUN only, with the reason kept', () async {
      final setup = await IceServers.configurationDynamic(workerBaseUrl: '');

      expect(setup.relayAvailable, isFalse);
      expect(setup.relayUnavailable?.reason,
          equals(RelayUnavailableReason.noWorkerUrl));
      expect(setup.configuration['iceServers'], isNotEmpty);
    });

    test('a Worker slower than the limit is a timeout, not a hang', () async {
      await serve((request) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return _json(200, _credentials());
      });

      final started = DateTime.now();
      final setup = await IceServers.configurationDynamic(
        workerBaseUrl: baseUrl,
        timeout: const Duration(milliseconds: 250),
      );

      expect(setup.relayUnavailable?.reason,
          equals(RelayUnavailableReason.timeout));
      expect(DateTime.now().difference(started),
          lessThan(const Duration(seconds: 1)));
    });

    test('the limit is five seconds, as a named constant', () {
      // 2 s was too tight behind the always-on VPN, and without a relay the
      // connection is doomed anyway, so waiting a little longer is the cheap
      // side of the trade.
      expect(IceServers.turnFetchTimeout, equals(const Duration(seconds: 5)));
    });

    test('a Worker that answers after more than two seconds is still waited for',
        () async {
      await serve((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 2400));
        return _json(200, _credentials());
      });

      final setup = await IceServers.configurationDynamic(workerBaseUrl: baseUrl);

      expect(setup.relayAvailable, isTrue,
          reason: 'the old 2 s limit gave up on this one');
    });

    test('a STUN server the Worker also returns is not gathered twice', () async {
      // stun.cloudflare.com is in both the static pool and what the Worker
      // sends back; a duplicate costs part of the 6-second gathering ceiling.
      await serve((request) => _json(200, {
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
          }));

      final setup = await IceServers.configurationDynamic(workerBaseUrl: baseUrl);

      final urls = (setup.configuration['iceServers'] as List).expand((s) {
        final raw = (s as Map)['urls'];
        return raw is List ? raw.cast<String>() : [raw as String];
      }).toList();

      expect(
        urls.where((u) => u == 'stun:stun.cloudflare.com:3478').length,
        equals(1),
      );
      // The rest of the static pool survives.
      expect(urls, contains('stun:stun.sipnet.ru:3478'));
      expect(urls, contains('turns:turn.cloudflare.com:443?transport=tcp'));
    });

    test('default Dio instance configures 4s connect and receive timeouts', () {
      final service = TurnCredentialService(baseUrl: 'http://127.0.0.1:8080');
      expect(service.dio.options.connectTimeout,
          equals(const Duration(seconds: 4)));
      expect(service.dio.options.receiveTimeout,
          equals(const Duration(seconds: 4)));
    });
  });
}

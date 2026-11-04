// The refresher keeps a long transfer's TURN credentials alive. Its failure
// handling has to follow what the Worker actually says:
//
//  * with no Worker URL there is nothing to refresh from, so it never starts;
//  * a 429 carries a Retry-After, and waiting that long is the whole answer —
//    it must not spend one of the three attempts, or a busy minute ends the
//    refresh for good;
//  * `relay_disabled` and `relay_unconfigured` will not change within a
//    session, so retrying them is noise.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:quickshare/core/webrtc/relay_availability.dart';
import 'package:quickshare/core/webrtc/turn_credential_refresher.dart';
import 'package:quickshare/core/webrtc/turn_credential_service.dart';

class _FakePeerConnection extends Fake implements RTCPeerConnection {
  final List<Map<String, dynamic>> configurations = [];

  /// When set, `setConfiguration` is still in flight until this completes.
  Completer<void>? gate;

  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {
    configurations.add(configuration);
    await gate?.future;
  }
}

TurnCredentials _fresh({DateTime? expiresAt}) => (
      servers: <Map<String, dynamic>>[
        {
          'urls': ['turns:turn.example.com:443?transport=tcp'],
          'username': 'u',
          'credential': 'c',
        }
      ],
      expiresAt: expiresAt,
    );

/// Credentials the way the Worker issues them: good for 30 minutes from now.
///
/// `fakeAsync` moves timers and not `DateTime.now()`, so the expiry is read off
/// the real clock at the moment of the fetch, which a test spends microseconds
/// between. Every timing assertion below leaves seconds of room for that.
TurnCredentials _thirtyMinutes() =>
    _fresh(expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 30)));

/// A fetcher that fails with each of [script]'s entries in turn, then
/// succeeds, and remembers when it was asked.
class _ScriptedFetcher {
  _ScriptedFetcher(this.script, this.elapsed);

  final List<Object> script;
  final Duration Function() elapsed;
  final List<Duration> askedAt = [];

  Future<TurnCredentials> call() async {
    askedAt.add(elapsed());
    final index = askedAt.length - 1;
    if (index < script.length) throw script[index];
    return _fresh();
  }
}

void main() {
  const firstRefresh = Duration(minutes: 25);

  group('TurnCredentialRefresher', () {
    test('does not start without a Worker URL', () {
      fakeAsync((async) {
        final fetcher = _ScriptedFetcher(const [], () => async.elapsed);
        final refresher = TurnCredentialRefresher(
          peerConnection: _FakePeerConnection(),
          workerBaseUrl: '   ',
          fetch: fetcher.call,
        )..start();

        async.elapse(const Duration(hours: 3));

        expect(refresher.isRunning, isFalse);
        expect(fetcher.askedAt, isEmpty);
      });
    });

    test('a refresh that works applies the new credentials', () {
      fakeAsync((async) {
        final pc = _FakePeerConnection();
        final fetcher = _ScriptedFetcher(const [], () => async.elapsed);
        TurnCredentialRefresher(
          peerConnection: pc,
          workerBaseUrl: 'https://worker.example',
          fetch: fetcher.call,
        ).start();

        async.elapse(firstRefresh + const Duration(seconds: 1));

        expect(fetcher.askedAt, hasLength(1));
        expect(pc.configurations, hasLength(1));
      });
    });

    test('a 429 waits for Retry-After instead of burning attempts', () {
      fakeAsync((async) {
        final pc = _FakePeerConnection();
        // Five throttled answers: more than the three attempts a generic
        // failure is allowed. Burning an attempt on each would give up here.
        final fetcher = _ScriptedFetcher([
          for (var i = 0; i < 5; i++)
            const RelayUnavailable(RelayUnavailableReason.rateLimited,
                retryAfter: Duration(seconds: 90), statusCode: 429),
        ], () => async.elapsed);
        TurnCredentialRefresher(
          peerConnection: pc,
          workerBaseUrl: 'https://worker.example',
          fetch: fetcher.call,
        ).start();

        async.elapse(firstRefresh);
        expect(fetcher.askedAt, hasLength(1));

        // Not a second earlier than the Worker asked.
        async.elapse(const Duration(seconds: 89));
        expect(fetcher.askedAt, hasLength(1), reason: 'Retry-After is 90s');
        async.elapse(const Duration(seconds: 1));
        expect(fetcher.askedAt, hasLength(2));

        async.elapse(const Duration(seconds: 90 * 4));

        expect(fetcher.askedAt, hasLength(6));
        expect(pc.configurations, hasLength(1),
            reason: 'the sixth ask succeeded; five 429s did not end it');
        for (var i = 1; i < 6; i++) {
          expect(fetcher.askedAt[i] - fetcher.askedAt[i - 1],
              equals(const Duration(seconds: 90)));
        }
      });
    });

    test('a 429 with no Retry-After waits a minute', () {
      fakeAsync((async) {
        final fetcher = _ScriptedFetcher(const [
          RelayUnavailable(RelayUnavailableReason.rateLimited, statusCode: 429),
        ], () => async.elapsed);
        TurnCredentialRefresher(
          peerConnection: _FakePeerConnection(),
          workerBaseUrl: 'https://worker.example',
          fetch: fetcher.call,
        ).start();

        async.elapse(firstRefresh + const Duration(seconds: 59));
        expect(fetcher.askedAt, hasLength(1));
        async.elapse(const Duration(seconds: 1));
        expect(fetcher.askedAt, hasLength(2));
      });
    });

    for (final reason in [
      RelayUnavailableReason.rateLimited,
      RelayUnavailableReason.limiterUnavailable,
    ]) {
      test('${reason.name} is waited out, never counted as a failed attempt',
          () {
        fakeAsync((async) {
          final pc = _FakePeerConnection();
          // More answers than the three attempts an ordinary failure gets.
          final fetcher = _ScriptedFetcher([
            for (var i = 0; i < 5; i++)
              RelayUnavailable(reason,
                  retryAfter: const Duration(seconds: 60), statusCode: 503),
          ], () => async.elapsed);
          final refresher = TurnCredentialRefresher(
            peerConnection: pc,
            workerBaseUrl: 'https://worker.example',
            fetch: fetcher.call,
          )..start();

          async.elapse(firstRefresh + const Duration(minutes: 6));

          expect(fetcher.askedAt, hasLength(6));
          expect(pc.configurations, hasLength(1),
              reason: 'the sixth ask succeeded; five refusals did not end it');
          expect(refresher.isRunning, isTrue);
        });
      });

      test('${reason.name} forever: it waits ten times and then stops', () {
        fakeAsync((async) {
          final pc = _FakePeerConnection();
          final fetcher = _ScriptedFetcher([
            for (var i = 0; i < 100; i++)
              RelayUnavailable(reason,
                  retryAfter: const Duration(seconds: 60), statusCode: 503),
          ], () => async.elapsed);
          final refresher = TurnCredentialRefresher(
            peerConnection: pc,
            workerBaseUrl: 'https://worker.example',
            fetch: fetcher.call,
          )..start();

          async.elapse(const Duration(hours: 6));

          expect(fetcher.askedAt, hasLength(11),
              reason: 'the first ask and ten waits, not an endless loop');
          expect(refresher.isRunning, isFalse);
          expect(pc.configurations, isEmpty);
        });
      });
    }

    for (final reason in [
      RelayUnavailableReason.relayDisabled,
      RelayUnavailableReason.relayUnconfigured,
    ]) {
      test('${reason.name} is terminal: one ask, then it stops for good', () {
        fakeAsync((async) {
          final pc = _FakePeerConnection();
          final fetcher = _ScriptedFetcher([
            RelayUnavailable(reason, statusCode: 503),
            RelayUnavailable(reason, statusCode: 503),
          ], () => async.elapsed);
          final refresher = TurnCredentialRefresher(
            peerConnection: pc,
            workerBaseUrl: 'https://worker.example',
            fetch: fetcher.call,
          )..start();

          async.elapse(const Duration(hours: 4));

          expect(fetcher.askedAt, hasLength(1));
          expect(refresher.isRunning, isFalse);
          expect(pc.configurations, isEmpty);
        });
      });
    }

    test('an ordinary failure is retried a minute later, up to three times',
        () {
      fakeAsync((async) {
        final fetcher = _ScriptedFetcher([
          for (var i = 0; i < 6; i++)
            const RelayUnavailable(RelayUnavailableReason.unreachable),
        ], () => async.elapsed);
        final refresher = TurnCredentialRefresher(
          peerConnection: _FakePeerConnection(),
          workerBaseUrl: 'https://worker.example',
          fetch: fetcher.call,
        )..start();

        async.elapse(const Duration(hours: 2));

        expect(fetcher.askedAt, hasLength(3),
            reason: 'three attempts, one minute apart, then it gives up');
        expect(fetcher.askedAt[1] - fetcher.askedAt[0],
            equals(const Duration(minutes: 1)));
        expect(refresher.isRunning, isFalse);
      });
    });

    test('cancel() stops a refresher that is waiting out a 429', () {
      fakeAsync((async) {
        final fetcher = _ScriptedFetcher([
          for (var i = 0; i < 5; i++)
            const RelayUnavailable(RelayUnavailableReason.rateLimited,
                retryAfter: Duration(seconds: 60)),
        ], () => async.elapsed);
        final refresher = TurnCredentialRefresher(
          peerConnection: _FakePeerConnection(),
          workerBaseUrl: 'https://worker.example',
          fetch: fetcher.call,
        )..start();

        async.elapse(firstRefresh);
        expect(fetcher.askedAt, hasLength(1));
        refresher.cancel();
        async.elapse(const Duration(hours: 1));

        expect(fetcher.askedAt, hasLength(1));
        expect(refresher.isRunning, isFalse);
      });
    });

    group('when the credentials expire', () {
      test('the first refresh comes five minutes before the expiry given',
          () {
        fakeAsync((async) {
          final fetcher = _ScriptedFetcher(const [], () => async.elapsed);
          TurnCredentialRefresher(
            peerConnection: _FakePeerConnection(),
            workerBaseUrl: 'https://worker.example',
            expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 40)),
            fetch: fetcher.call,
          ).start();

          async.elapse(const Duration(minutes: 34, seconds: 50));
          expect(fetcher.askedAt, isEmpty, reason: 'not before the lead time');
          async.elapse(const Duration(seconds: 20));
          expect(fetcher.askedAt, hasLength(1),
              reason: 'at the expiry would be five minutes too late');
        });
      });

      test('an expiry already inside the lead time refreshes at once', () {
        fakeAsync((async) {
          final fetcher = _ScriptedFetcher(const [], () => async.elapsed);
          TurnCredentialRefresher(
            peerConnection: _FakePeerConnection(),
            workerBaseUrl: 'https://worker.example',
            expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
            fetch: fetcher.call,
          ).start();

          async.elapse(const Duration(seconds: 1));

          expect(fetcher.askedAt, hasLength(1));
        });
      });

      test('each refresh is followed by the next, five minutes ahead of the '
          'expiry it brought', () {
        fakeAsync((async) {
          final pc = _FakePeerConnection();
          final fetcher = _ScriptedFetcher(const [], () => async.elapsed);
          TurnCredentialRefresher(
            peerConnection: pc,
            workerBaseUrl: 'https://worker.example',
            fetch: () async {
              fetcher.askedAt.add(async.elapsed);
              return _thirtyMinutes();
            },
          ).start();

          // The first comes on the fixed cycle, there being no expiry to go by.
          async.elapse(firstRefresh + const Duration(seconds: 10));
          expect(fetcher.askedAt, hasLength(1));

          // Credentials good for 30 minutes: the next one is due after 25.
          async.elapse(const Duration(minutes: 24, seconds: 30));
          expect(fetcher.askedAt, hasLength(1),
              reason: 'not before five minutes ahead of the expiry');
          async.elapse(const Duration(seconds: 40));
          expect(fetcher.askedAt, hasLength(2),
              reason: 'at the expiry would be five minutes too late');

          // And a transfer that outlasts the second expiry keeps its relay.
          async.elapse(const Duration(minutes: 25));
          expect(fetcher.askedAt, hasLength(3));
          expect(pc.configurations, hasLength(3));
        });
      });

      test('a refresh that brought no expiry falls back to the fixed cycle',
          () {
        fakeAsync((async) {
          final fetcher = _ScriptedFetcher(const [], () => async.elapsed);
          TurnCredentialRefresher(
            peerConnection: _FakePeerConnection(),
            workerBaseUrl: 'https://worker.example',
            fetch: () async {
              fetcher.askedAt.add(async.elapsed);
              return _fresh();
            },
          ).start();

          async.elapse(const Duration(hours: 2));

          // 25, 50, 75, 100 minutes.
          expect(fetcher.askedAt, hasLength(4));
        });
      });
    });

    group('cancelled while a request is in flight', () {
      final fresh = _fresh();

      test('during the fetch: the answer is dropped and the connection is '
          'left alone', () {
        fakeAsync((async) {
          final pc = _FakePeerConnection();
          final answer = Completer<TurnCredentials>();
          final refresher = TurnCredentialRefresher(
            peerConnection: pc,
            workerBaseUrl: 'https://worker.example',
            fetch: () => answer.future,
          )..start();
          async.elapse(firstRefresh);
          expect(refresher.isRunning, isTrue, reason: 'setup: the fetch is out');

          refresher.cancel();
          answer.complete(fresh);
          async.elapse(const Duration(hours: 2));

          expect(pc.configurations, isEmpty,
              reason: 'setConfiguration on a connection that was closed');
          expect(refresher.isRunning, isFalse);
        });
      });

      test('during the fetch, which then fails: nothing is retried', () {
        fakeAsync((async) {
          final pc = _FakePeerConnection();
          final answer = Completer<TurnCredentials>();
          var asked = 0;
          final refresher = TurnCredentialRefresher(
            peerConnection: pc,
            workerBaseUrl: 'https://worker.example',
            fetch: () {
              asked++;
              return answer.future;
            },
          )..start();
          async.elapse(firstRefresh);

          refresher.cancel();
          answer.completeError(
              const RelayUnavailable(RelayUnavailableReason.unreachable));
          async.elapse(const Duration(hours: 2));

          expect(asked, 1);
          expect(pc.configurations, isEmpty);
        });
      });

      test('during setConfiguration: no further refresh is scheduled', () {
        fakeAsync((async) {
          final pc = _FakePeerConnection()..gate = Completer<void>();
          var asked = 0;
          final refresher = TurnCredentialRefresher(
            peerConnection: pc,
            workerBaseUrl: 'https://worker.example',
            fetch: () async {
              asked++;
              return _thirtyMinutes();
            },
          )..start();
          async.elapse(firstRefresh);
          expect(pc.configurations, hasLength(1), reason: 'setup: it is in flight');

          refresher.cancel();
          pc.gate!.complete();
          async.elapse(const Duration(hours: 3));

          expect(asked, 1);
          expect(refresher.isRunning, isFalse);
        });
      });
    });
  });
}

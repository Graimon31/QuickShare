// Exercises WorkerAnswerChannel against a tiny local HTTP server that mimics
// the DirectDrop Worker's `/r/:roomId` contract (POST stores raw bytes, GET
// returns them or 404) — the actual Worker runs on Cloudflare's runtime and
// can't be driven by `flutter test`, so this stands in for it.
//
// The second half scripts the Worker's answers one by one under a fake clock,
// because what it pins down is timing: how long the channel waits after a 429,
// that it never gives up on a mailbox that is merely busy, and that a garbage
// payload does not end the wait for the real one. The Worker's contract for
// `/r/:roomId`: GET 200 or 404, POST 201, and on overload 429 rate_limited or
// 503 storage_unavailable, both with `Retry-After: 60`.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' hide Response;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:quickshare/core/signaling/worker_answer_channel.dart';

void main() {
  late HttpServer server;
  late String baseUrl;
  final rooms = <String, List<int>>{};

  Response handler(Request request) {
    final segments = request.url.pathSegments;
    if (segments.length != 2 || segments[0] != 'r') {
      return Response.notFound('not found');
    }
    final roomId = segments[1];

    if (request.method == 'POST') {
      return Response(201);
    }
    if (request.method == 'GET') {
      final blob = rooms[roomId];
      if (blob == null) return Response.notFound('not found');
      return Response.ok(blob);
    }
    return Response(405);
  }

  setUp(() async {
    rooms.clear();
    server = await shelf_io.serve(
      (request) async {
        // Buffer the POST body into the room map before delegating, so the
        // handler above can stay a plain sync function.
        if (request.method == 'POST') {
          final segments = request.url.pathSegments;
          if (segments.length == 2 && segments[0] == 'r') {
            final bytes = await request.read().expand((c) => c).toList();
            rooms[segments[1]] = bytes;
          }
        }
        return handler(request);
      },
      InternetAddress.loopbackIPv4,
      0,
    );
    baseUrl = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('publish then subscribe delivers the same bytes back', () async {
    final publisher = WorkerAnswerChannel(baseUrl: baseUrl);
    final subscriber = WorkerAnswerChannel(
      baseUrl: baseUrl,
      pollInterval: const Duration(milliseconds: 50),
    );

    final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
    await publisher.publish('room-one', payload);

    await subscriber.subscribe('room-one');
    final received = await subscriber.answers.first
        .timeout(const Duration(seconds: 2));

    expect(received, equals(payload));

    await publisher.close();
    await subscriber.close();
  });

  test('subscribe delivers once a later publish lands, via polling', () async {
    final subscriber = WorkerAnswerChannel(
      baseUrl: baseUrl,
      pollInterval: const Duration(milliseconds: 30),
    );
    final publisher = WorkerAnswerChannel(baseUrl: baseUrl);

    final answerFuture = subscriber.answers.first;
    await subscriber.subscribe('room-two');

    // Room is empty at subscribe time; the timer must pick up a publish that
    // happens afterwards.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final payload = Uint8List.fromList([9, 8, 7]);
    await publisher.publish('room-two', payload);

    final received = await answerFuture.timeout(const Duration(seconds: 2));
    expect(received, equals(payload));

    await subscriber.close();
    await publisher.close();
  });

  test('subscribe throws when the Worker is unreachable', () async {
    final channel = WorkerAnswerChannel(baseUrl: 'http://127.0.0.1:1');
    await expectLater(channel.subscribe('room-three'), throwsA(anything));
    await channel.close();
  });

  group('against a scripted Worker', () {
    const base = 'https://worker.example';
    final payload = Uint8List.fromList(List<int>.generate(48, (i) => i + 1));

    _Reply notYet() => _Reply(404);
    _Reply answer([List<int>? bytes]) => _Reply(200, body: bytes ?? payload);
    _Reply busy429([String? retryAfter = '60']) =>
        _Reply(429, retryAfter: retryAfter);
    _Reply busy503([String? retryAfter = '60']) =>
        _Reply(503, retryAfter: retryAfter);

    /// Runs [body] under a fake clock with a channel wired to [script].
    void scripted(
      List<Object> script,
      void Function(FakeAsync async, WorkerAnswerChannel channel,
              _ScriptedAdapter adapter, List<Uint8List> delivered)
          body, {
      Future<bool> Function(Uint8List payload)? acceptPayload,
    }) {
      fakeAsync((async) {
        final adapter = _ScriptedAdapter(script, () => async.elapsed);
        final channel = WorkerAnswerChannel(
          baseUrl: base,
          dio: Dio()..httpClientAdapter = adapter,
          acceptPayload: acceptPayload,
        );
        final delivered = <Uint8List>[];
        channel.answers.listen(delivered.add);
        body(async, channel, adapter, delivered);
        unawaited(channel.close());
        async.elapse(Duration.zero);
      });
    }

    /// Seconds since the start at which each request was made.
    List<int> times(_ScriptedAdapter adapter) =>
        [for (final c in adapter.calls) c.at.inSeconds];

    group('a busy Worker never disables the channel', () {
      test('a 429 at the probe is transient: subscribe succeeds', () {
        scripted([busy429(), notYet(), answer()],
            (async, channel, adapter, delivered) {
          final subscribed = _track(channel.subscribe('room'));
          async.elapse(Duration.zero);

          expect(subscribed.error, isNull,
              reason: 'a 429 proves the Worker is there');
          expect(subscribed.done, isTrue);

          // Waits as long as the Worker asked, not the usual two seconds.
          async.elapse(const Duration(seconds: 59));
          expect(adapter.calls, hasLength(1));
          async.elapse(const Duration(seconds: 2));
          expect(adapter.calls, hasLength(2));

          async.elapse(const Duration(seconds: 2));
          expect(delivered, [payload]);
          expect(times(adapter), [0, 60, 62]);
        });
      });

      test('a 503 at the probe is transient too', () {
        scripted([busy503('30'), answer()],
            (async, channel, adapter, delivered) {
          final subscribed = _track(channel.subscribe('room'));
          async.elapse(Duration.zero);
          expect(subscribed.error, isNull);
          expect(subscribed.done, isTrue);

          async.elapse(const Duration(seconds: 31));
          expect(delivered, [payload]);
          expect(times(adapter), [0, 30]);
        });
      });

      test('a 429 on a poll waits out Retry-After, then returns to two seconds',
          () {
        scripted([
          notYet(), // probe
          busy429('45'), // poll at 2 s
          notYet(), // poll at 47 s
          notYet(), // 49 s: back on the normal cadence
          notYet(), // 51 s
          answer(), // 53 s
        ], (async, channel, adapter, delivered) {
          channel.subscribe('room');
          async.elapse(Duration.zero);
          async.elapse(const Duration(seconds: 60));

          expect(times(adapter), [0, 2, 47, 49, 51, 53]);
          expect(delivered, [payload]);
        });
      });

      test('without Retry-After it backs off exponentially, capped at a minute',
          () {
        scripted([
          notYet(), // probe at 0
          busy503(null), // 2
          busy503(null), // 6   (+4)
          busy503(null), // 14  (+8)
          busy503(null), // 30  (+16)
          busy503(null), // 62  (+32)
          busy503(null), // 122 (+60, the cap rather than 64)
          busy503(null), // 182 (+60)
          notYet(), // 242
          notYet(), // 244: recovered, two seconds again
        ], (async, channel, adapter, delivered) {
          channel.subscribe('room');
          async.elapse(Duration.zero);
          async.elapse(const Duration(seconds: 244));

          expect(times(adapter), [0, 2, 6, 14, 30, 62, 122, 182, 242, 244]);
        });
      });

      test('a network error on a poll backs off the same way, then recovers',
          () {
        scripted([
          notYet(), // probe
          _Reply.networkError(), // 2
          _Reply.networkError(), // 6
          notYet(), // 14
          notYet(), // 16: recovered
          answer(), // 18
        ], (async, channel, adapter, delivered) {
          channel.subscribe('room');
          async.elapse(Duration.zero);
          async.elapse(const Duration(seconds: 30));

          expect(times(adapter), [0, 2, 6, 14, 16, 18]);
          expect(delivered, [payload]);
        });
      });

      test('one good answer wipes the backoff: the next failure starts again '
          'at four seconds', () {
        scripted([
          notYet(), // probe at 0
          busy503(null), // 2: first failure, waits 4 s
          notYet(), // 6: recovered
          busy503(null), // 8: a first failure again, not a second one
          notYet(), // 12: four seconds, where a second would have been eight
          answer(), // 14
        ], (async, channel, adapter, delivered) {
          channel.subscribe('room');
          async.elapse(Duration.zero);
          async.elapse(const Duration(seconds: 20));

          expect(times(adapter), [0, 2, 6, 8, 12, 14]);
          expect(delivered, [payload]);
        });
      });

      test('a network error at the probe still fails the subscription', () {
        // The reachability check is what lets the race tell "no channel works"
        // from "one is slow", and an unreachable Worker is the former.
        scripted([_Reply.networkError()], (async, channel, adapter, delivered) {
          final subscribed = _track(channel.subscribe('room'));
          async.elapse(Duration.zero);
          expect(subscribed.error, isNotNull);
        });
      });
    });

    group('a garbage 200 does not end the wait', () {
      Future<bool> opens(Uint8List bytes) async => bytes.length == 48;

      test('a payload that does not open is ignored; the real one still lands',
          () {
        final garbage = Uint8List.fromList([1, 2, 3]);
        scripted([
          notYet(), // probe
          answer(garbage), // 2: rejected
          answer(garbage), // 4: the same junk, still rejected
          answer(), // 6: the real answer overwrote it
        ], (async, channel, adapter, delivered) {
          channel.subscribe('room');
          async.elapse(Duration.zero);
          async.elapse(const Duration(seconds: 10));

          expect(delivered, [payload],
              reason: 'the junk was never passed on, and did not stop polling');
          expect(times(adapter), [0, 2, 4, 6]);
        }, acceptPayload: opens);
      });

      test('a payload is passed on once and polling then stops', () {
        scripted([notYet(), answer(), answer()],
            (async, channel, adapter, delivered) {
          channel.subscribe('room');
          async.elapse(Duration.zero);
          async.elapse(const Duration(seconds: 30));

          expect(delivered, hasLength(1));
          expect(adapter.calls, hasLength(2),
              reason: 'delivered; nothing left to ask for');
        }, acceptPayload: opens);
      });

      test('a verifier that throws counts as a rejection, not a crash', () {
        scripted([notYet(), answer(), answer()],
            (async, channel, adapter, delivered) {
          channel.subscribe('room');
          async.elapse(Duration.zero);
          async.elapse(const Duration(seconds: 10));

          expect(delivered, isEmpty);
          expect(adapter.calls.length, greaterThan(2),
              reason: 'still polling after the verifier blew up');
        }, acceptPayload: (_) async => throw StateError('bad envelope'));
      });

      test('an empty 200 is not a payload', () {
        scripted([notYet(), _Reply(200, body: const []), answer()],
            (async, channel, adapter, delivered) {
          channel.subscribe('room');
          async.elapse(Duration.zero);
          async.elapse(const Duration(seconds: 10));

          expect(delivered, [payload]);
        });
      });
    });

    group('publishing', () {
      test('retries a 429 and a 503, honouring Retry-After, then succeeds', () {
        scripted([busy429('7'), busy503(null), _Reply(201)],
            (async, channel, adapter, delivered) {
          final outcome = _track(channel.publish('room', payload));
          async.elapse(Duration.zero);

          async.elapse(const Duration(seconds: 6));
          expect(adapter.calls, hasLength(1));
          async.elapse(const Duration(seconds: 1));
          expect(adapter.calls, hasLength(2), reason: 'Retry-After: 7');

          async.elapse(const Duration(seconds: 5));
          expect(outcome.done, isTrue);
          expect(times(adapter), [0, 7, 9],
              reason: 'no header: one-second base, doubled for the second wait');
          expect(adapter.calls.every((c) => c.method == 'POST'), isTrue);
        });
      });

      test('retries a network error', () {
        scripted([_Reply.networkError(), _Reply(201)],
            (async, channel, adapter, delivered) {
          final outcome = _track(channel.publish('room', payload));
          async.elapse(const Duration(seconds: 5));

          expect(outcome.done, isTrue);
          expect(adapter.calls, hasLength(2));
        });
      });

      test('gives up after three attempts and reports the final failure', () {
        scripted([busy429(), busy429(), busy429(), _Reply(201)],
            (async, channel, adapter, delivered) {
          final outcome = _track(channel.publish('room', payload));
          async.elapse(const Duration(minutes: 10));

          expect(adapter.calls, hasLength(3), reason: 'bounded, not endless');
          expect(outcome.error, isA<RendezvousPublishFailed>());
          final failure = outcome.error as RendezvousPublishFailed;
          expect(failure.attempts, equals(3));
          expect(failure.statusCode, equals(429));
          expect(failure.retryAfter, equals(const Duration(seconds: 60)));
          expect(failure.toString(), contains('429'));
          expect(failure.toString(), contains('3 attempts'));
        });
      });

      test('does not retry a refusal that waiting cannot fix', () {
        scripted([_Reply(400), _Reply(201)],
            (async, channel, adapter, delivered) {
          final outcome = _track(channel.publish('room', payload));
          async.elapse(const Duration(minutes: 1));

          expect(adapter.calls, hasLength(1));
          expect(
              outcome.error,
              isA<RendezvousPublishFailed>()
                  .having((f) => f.statusCode, 'statusCode', 400)
                  .having((f) => f.attempts, 'attempts', 1));
        });
      });

      test('closing the channel ends a publish that is waiting to retry', () {
        scripted([busy429(), _Reply(201)],
            (async, channel, adapter, delivered) {
          final outcome = _track(channel.publish('room', payload));
          async.elapse(const Duration(seconds: 5));
          expect(adapter.calls, hasLength(1));

          channel.close();
          async.elapse(const Duration(minutes: 5));

          expect(adapter.calls, hasLength(1), reason: 'no request after close');
          expect(outcome.error, isA<RendezvousPublishFailed>());
        });
      });
    });
  });
}

/// How a future ended, once it has: completed, or failed with [error].
class _Outcome {
  bool done = false;
  Object? error;

  bool get failed => error != null;
}

_Outcome _track(Future<void> future) {
  final outcome = _Outcome();
  future.then<void>((_) {
    outcome.done = true;
  }, onError: (Object e) {
    outcome.error = e;
  });
  return outcome;
}

/// One scripted answer from the Worker.
class _Reply {
  final int? status;
  final List<int> body;
  final String? retryAfter;
  final bool network;

  _Reply(this.status, {this.body = const [], this.retryAfter}) : network = false;
  _Reply.networkError()
      : status = null,
        body = const [],
        retryAfter = null,
        network = true;
}

class _Call {
  final String method;
  final Uri uri;
  final Duration at;
  _Call(this.method, this.uri, this.at);
}

/// Answers each request with the next entry of [script] and remembers when it
/// was asked, on the fake clock.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script, this.elapsed);

  final List<Object> script;
  final Duration Function() elapsed;
  final List<_Call> calls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(_Call(options.method, options.uri, elapsed()));
    final index = calls.length - 1;
    if (index >= script.length) {
      throw StateError('the script has no answer for request ${index + 1}');
    }
    final reply = script[index] as _Reply;
    if (reply.network) {
      throw DioException.connectionError(
          requestOptions: options, reason: 'scripted network failure');
    }
    return ResponseBody.fromBytes(
      reply.body,
      reply.status!,
      headers: {
        if (reply.retryAfter != null) 'retry-after': [reply.retryAfter!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// Exercises WorkerAnswerChannel against a tiny local HTTP server that mimics
// the DirectDrop Worker's `/r/:roomId` contract (POST stores raw bytes, GET
// returns them or 404) — the actual Worker runs on Cloudflare's runtime and
// can't be driven by `flutter test`, so this stands in for it.
import 'dart:io';
import 'dart:typed_data';

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
}

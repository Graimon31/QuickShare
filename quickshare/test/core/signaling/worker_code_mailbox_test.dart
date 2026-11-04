// The Worker side of the code mailbox, against a stand-in for `/r/:roomId`:
// one value per room, the last write wins, a GET returns it again and again
// until something replaces it, and under load it answers 429 with
// `Retry-After`.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/core/signaling/worker_code_mailbox.dart';

Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);

class _Worker {
  _Worker._(this.server);

  final HttpServer server;
  final rooms = <String, List<int>>{};
  final gets = <String, int>{};
  final getTimes = <DateTime>[];
  final posts = <String, int>{};

  /// Status to answer every GET with, with the headers to go with it.
  int? getStatus;
  Map<String, String> getHeaders = const {};

  /// Statuses for the next POSTs, oldest first; empty means 201.
  final postStatuses = <int>[];
  Map<String, String> postHeaders = const {};

  static Future<_Worker> start() async {
    late final _Worker worker;
    final server = await shelf_io.serve(
      (request) async {
        final segments = request.url.pathSegments;
        if (segments.length != 2 || segments[0] != 'r') {
          return Response.notFound('not found');
        }
        final room = segments[1];
        if (request.method == 'POST') {
          worker.posts[room] = (worker.posts[room] ?? 0) + 1;
          if (worker.postStatuses.isNotEmpty) {
            return Response(worker.postStatuses.removeAt(0),
                headers: worker.postHeaders);
          }
          worker.rooms[room] = await request.read().expand((c) => c).toList();
          return Response(201);
        }
        if (request.method == 'GET') {
          worker.gets[room] = (worker.gets[room] ?? 0) + 1;
          worker.getTimes.add(DateTime.now());
          if (worker.getStatus != null) {
            return Response(worker.getStatus!, headers: worker.getHeaders);
          }
          final blob = worker.rooms[room];
          return blob == null ? Response.notFound('not found') : Response.ok(blob);
        }
        return Response(405);
      },
      InternetAddress.loopbackIPv4,
      0,
    );
    worker = _Worker._(server);
    return worker;
  }

  String get url => 'http://127.0.0.1:${server.port}';
  int get totalGets => gets.values.fold(0, (a, b) => a + b);
  Future<void> stop() => server.close(force: true);
}

Future<void> _until(bool Function() done,
    {Duration within = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late _Worker worker;
  late List<WorkerCodeMailbox> open;

  WorkerCodeMailbox make({
    Duration poll = const Duration(milliseconds: 40),
    int attempts = 3,
    Duration publishBackoff = const Duration(milliseconds: 20),
    Duration maxPublishWait = const Duration(seconds: 10),
  }) {
    final box = WorkerCodeMailbox(
      baseUrl: worker.url,
      pollInterval: poll,
      publishAttempts: attempts,
      publishBackoff: publishBackoff,
      maxPublishWait: maxPublishWait,
    );
    open.add(box);
    return box;
  }

  setUp(() async {
    worker = await _Worker.start();
    open = [];
  });

  tearDown(() async {
    for (final box in open) {
      await box.close();
    }
    await worker.stop();
  });

  test('polls every five seconds by default: the quota is shared with everyone',
      () {
    expect(WorkerCodeMailbox(baseUrl: 'http://x').pollInterval,
        const Duration(seconds: 5));
  });

  test('a value put in a room is heard once, however often it is read',
      () async {
    final box = make();
    final heard = <MailboxMessage>[];
    box.messages.listen(heard.add);
    await box.subscribe('room-one-room-one-1');
    await make().publish('room-one-room-one-1', _b([1, 2, 3]));

    await _until(() => heard.isNotEmpty);
    final readsBefore = worker.totalGets;
    await _until(() => worker.totalGets >= readsBefore + 4);

    expect(heard, hasLength(1));
    expect(heard.single.payload, [1, 2, 3]);
    expect(heard.single.topic, 'room-one-room-one-1');
    expect(heard.single.source, 'worker');
  });

  test('a replacement is heard, and so is a second value after a first',
      () async {
    final box = make();
    final speaker = make();
    final heard = <MailboxMessage>[];
    box.messages.listen(heard.add);
    await box.subscribe('room-one-room-one-1');

    await speaker.publish('room-one-room-one-1', _b([1]));
    await _until(() => heard.length == 1);
    await speaker.publish('room-one-room-one-1', _b([2]));
    await _until(() => heard.length == 2);

    expect(heard.map((m) => m.payload.first), [1, 2]);
  });

  test('every subscribed topic is read, each round', () async {
    final box = make();
    final heard = <String>[];
    box.messages.listen((m) => heard.add(m.topic));
    await box.subscribe('room-aaaaaaaaaaaaaa');
    await box.subscribe('room-bbbbbbbbbbbbbb');
    final speaker = make();
    await speaker.publish('room-bbbbbbbbbbbbbb', _b([2]));
    await speaker.publish('room-aaaaaaaaaaaaaa', _b([1]));

    await _until(() => heard.length == 2);
    expect(heard.toSet(), {'room-aaaaaaaaaaaaaa', 'room-bbbbbbbbbbbbbb'});
    expect(worker.gets['room-aaaaaaaaaaaaaa'], isNotNull);
    expect(worker.gets['room-bbbbbbbbbbbbbb'], isNotNull);
  });

  test('a topic given up is not read again', () async {
    final box = make();
    await box.subscribe('room-aaaaaaaaaaaaaa');
    await _until(() => (worker.gets['room-aaaaaaaaaaaaaa'] ?? 0) >= 3);

    await box.unsubscribe('room-aaaaaaaaaaaaaa');
    final after = worker.totalGets;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(worker.totalGets, after);
  });

  test('empty, oversized and unreadable rooms are not messages', () async {
    final box = make();
    final heard = <MailboxMessage>[];
    box.messages.listen(heard.add);
    worker.rooms['room-aaaaaaaaaaaaaa'] = [];
    await box.subscribe('room-aaaaaaaaaaaaaa');
    await _until(() => worker.totalGets >= 4);
    expect(heard, isEmpty);

    worker.rooms['room-aaaaaaaaaaaaaa'] =
        List.filled(WorkerCodeMailbox.maxBlobBytes + 1, 1);
    final before = worker.totalGets;
    await _until(() => worker.totalGets >= before + 3);
    expect(heard, isEmpty);

    worker.rooms['room-aaaaaaaaaaaaaa'] = [9];
    await _until(() => heard.isNotEmpty);
    expect(heard.single.payload, [9], reason: 'and it is still listening');
  });

  group('when the Worker is busy', () {
    test('a 429 with Retry-After pauses every read for that long, and reading '
        'resumes after', () async {
      final box = make();
      final heard = <MailboxMessage>[];
      box.messages.listen(heard.add);
      await box.subscribe('room-aaaaaaaaaaaaaa');
      await _until(() => worker.totalGets >= 3);

      worker.getStatus = 429;
      worker.getHeaders = {'retry-after': '1'};
      await _until(() => worker.getTimes.length >= 4);
      final limited = DateTime.now();
      final during = worker.totalGets;
      worker.getStatus = null;
      worker.rooms['room-aaaaaaaaaaaaaa'] = [5];

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(worker.totalGets - during, lessThanOrEqualTo(1),
          reason: 'told to wait a second: it waits');

      await _until(() => heard.isNotEmpty, within: const Duration(seconds: 4));
      expect(DateTime.now().difference(limited),
          greaterThanOrEqualTo(const Duration(milliseconds: 800)));
      expect(heard.single.payload, [5]);
    });

    test('errors back off instead of hammering, and never end the polling',
        () async {
      final box = make();
      final heard = <MailboxMessage>[];
      box.messages.listen(heard.add);
      await box.subscribe('room-aaaaaaaaaaaaaa');

      worker.getStatus = 500;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final hammered = worker.getTimes
          .where((t) => t.isAfter(DateTime.now().subtract(const Duration(milliseconds: 700))))
          .length;
      expect(hammered, lessThan(10), reason: 'exponential, not every 40 ms');
      worker.getStatus = null;
      worker.rooms['room-aaaaaaaaaaaaaa'] = [6];

      await _until(() => heard.isNotEmpty, within: const Duration(seconds: 6));
    });

    test('subscribing to a Worker that answers 429 succeeds: it is up, only '
        'busy', () async {
      worker.getStatus = 429;
      worker.getHeaders = {'retry-after': '60'};
      await make().subscribe('room-aaaaaaaaaaaaaa');
    });

    test('subscribing to a Worker that cannot be reached says so', () async {
      final dead = _Worker.start();
      final url = (await dead).url;
      await (await dead).stop();
      final box = WorkerCodeMailbox(
          baseUrl: url, pollInterval: const Duration(milliseconds: 40));
      open.add(box);

      await expectLater(
          box.subscribe('room-aaaaaaaaaaaaaa'), throwsA(isA<MailboxUnavailable>()));
    });

    test('subscribing to something that is not the Worker says so', () async {
      worker.getStatus = 418;
      await expectLater(make().subscribe('room-aaaaaaaaaaaaaa'),
          throwsA(isA<MailboxUnavailable>()));
    });
  });

  group('publishing', () {
    test('puts the bytes in the room', () async {
      await make().publish('room-aaaaaaaaaaaaaa', _b([4, 5, 6]));
      expect(worker.rooms['room-aaaaaaaaaaaaaa'], [4, 5, 6]);
    });

    test('a short 429 is retried and then succeeds', () async {
      worker.postStatuses.add(429);
      worker.postHeaders = {'retry-after': '0'};
      await make().publish('room-aaaaaaaaaaaaaa', _b([1]));

      expect(worker.posts['room-aaaaaaaaaaaaaa'], 2);
      expect(worker.rooms['room-aaaaaaaaaaaaaa'], [1]);
    });

    test('a 429 that asks for a minute is not waited for: too late to help an '
        'exchange that lasts seconds', () async {
      worker.postStatuses.add(429);
      worker.postHeaders = {'retry-after': '60'};
      final watch = Stopwatch()..start();

      await expectLater(make().publish('room-aaaaaaaaaaaaaa', _b([1])),
          throwsA(isA<MailboxUnavailable>()));

      expect(worker.posts['room-aaaaaaaaaaaaaa'], 1);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a refusal is not retried', () async {
      worker.postStatuses.add(400);
      await expectLater(make().publish('room-aaaaaaaaaaaaaa', _b([1])),
          throwsA(isA<MailboxUnavailable>()));
      expect(worker.posts['room-aaaaaaaaaaaaaa'], 1);
    });

    test('something that does not fit the Worker never leaves the device',
        () async {
      final box = make();
      await expectLater(
          box.publish('room-aaaaaaaaaaaaaa', Uint8List(0)),
          throwsA(isA<MailboxUnavailable>()));
      await expectLater(
          box.publish('room-aaaaaaaaaaaaaa',
              Uint8List(WorkerCodeMailbox.maxBlobBytes + 1)),
          throwsA(isA<MailboxUnavailable>()));
      expect(worker.posts, isEmpty);
    });

    test('closing while waiting to retry ends the wait', () async {
      worker.postStatuses.add(429);
      worker.postHeaders = {'retry-after': '5'};
      final box = make();
      Object? error;
      final done = box
          .publish('room-aaaaaaaaaaaaaa', _b([1]))
          .catchError((Object e) => error = e);

      await _until(() => worker.posts.isNotEmpty);
      await box.close();
      await done.timeout(const Duration(seconds: 2));

      expect(error, isA<MailboxUnavailable>());
    });
  });

  test('closing stops the polling', () async {
    final box = make();
    await box.subscribe('room-aaaaaaaaaaaaaa');
    await _until(() => worker.totalGets >= 3);

    await box.close();
    final after = worker.totalGets;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(worker.totalGets, after);
    await expectLater(box.subscribe('room-aaaaaaaaaaaaaa'),
        throwsA(isA<MailboxUnavailable>()));
  });
}

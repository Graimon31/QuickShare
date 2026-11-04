// The Nostr side of the code mailbox, against a relay that behaves like the
// real ones: events are forwarded to whoever is subscribed at that moment and
// kept for nobody, it checks the signature before it will forward, and it may
// say anything at all to a subscriber.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/crypto/bip340.dart';
import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/core/signaling/nostr_code_mailbox.dart';

Uint8List _unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

/// A relay in a few lines: NIP-01's REQ, EVENT and CLOSE, ephemeral, with the
/// signature check a real one makes.
class _Relay {
  _Relay._(this._server);

  final HttpServer _server;
  final connections = <WebSocket>[];
  final _subs = <WebSocket, Map<String, List<String>>>{};

  /// Every subscription id ever opened, in order.
  final subscriptionIds = <String>[];
  final closed = <String>[];
  int rejectedEvents = 0;

  /// Whether it says it has registered a subscription, as the real ones do.
  bool answersEose = true;

  static Future<_Relay> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final relay = _Relay._(server);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      relay.connections.add(socket);
      relay._subs[socket] = {};
      socket.listen((raw) => relay._onFrame(socket, raw as String),
          onDone: () => relay._subs.remove(socket));
    });
    return relay;
  }

  String get url => 'ws://127.0.0.1:${_server.port}';
  int get port => _server.port;

  int get subscribed =>
      _subs.values.fold(0, (sum, subs) => sum + subs.length);

  void _onFrame(WebSocket socket, String raw) {
    final frame = jsonDecode(raw) as List<dynamic>;
    switch (frame[0]) {
      case 'REQ':
        final id = frame[1] as String;
        final filter = frame[2] as Map<String, dynamic>;
        subscriptionIds.add(id);
        _subs[socket]![id] = List<String>.from(filter['#t'] as List);
        if (answersEose) socket.add(jsonEncode(['EOSE', id]));
      case 'CLOSE':
        closed.add(frame[1] as String);
        _subs[socket]?.remove(frame[1]);
      case 'EVENT':
        final event = frame[1] as Map<String, dynamic>;
        final serialized = jsonEncode([
          0,
          event['pubkey'],
          event['created_at'],
          event['kind'],
          event['tags'],
          event['content'],
        ]);
        final valid = Bip340.verify(
          _unhex(event['id'] as String),
          _unhex(event['pubkey'] as String),
          _unhex(event['sig'] as String),
        );
        if (!valid || serialized.isEmpty) {
          rejectedEvents++;
          socket.add(jsonEncode(['OK', event['id'], false, 'invalid: sig']));
          return;
        }
        socket.add(jsonEncode(['OK', event['id'], true, '']));
        forward(event);
    }
  }

  /// Sends [event] to every subscription whose filter it matches.
  void forward(Map<String, dynamic> event) {
    final tags = (event['tags'] as List).cast<List>();
    final topics = [
      for (final tag in tags)
        if (tag.length >= 2 && tag[0] == 't') tag[1] as String
    ];
    for (final entry in _subs.entries) {
      for (final sub in entry.value.entries) {
        if (sub.value.any(topics.contains)) {
          entry.key.add(jsonEncode(['EVENT', sub.key, event]));
        }
      }
    }
  }

  /// Anything at all, to every connection.
  void say(String frame) {
    for (final socket in connections) {
      socket.add(frame);
    }
  }

  Future<void> dropConnections() async {
    for (final socket in connections.toList()) {
      await socket.close();
    }
    connections.clear();
  }

  Future<void> stop() async {
    await dropConnections();
    await _server.close(force: true);
  }
}

NostrCodeMailbox _mailbox(List<String> relays,
        {Duration reconnect = const Duration(milliseconds: 40),
        Duration confirm = const Duration(milliseconds: 300)}) =>
    NostrCodeMailbox(
      relays: relays,
      connectTimeout: const Duration(seconds: 2),
      confirmTimeout: confirm,
      reconnectDelay: reconnect,
    );

Future<void> _until(bool Function() done,
    {Duration within = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);

void main() {
  late _Relay relay;
  late List<NostrCodeMailbox> open;

  NostrCodeMailbox make({List<String>? relays}) {
    final box = _mailbox(relays ?? [relay.url]);
    open.add(box);
    return box;
  }

  setUp(() async {
    relay = await _Relay.start();
    open = [];
  });

  tearDown(() async {
    for (final box in open) {
      await box.close();
    }
    await relay.stop();
  });

  test('a message published by one mailbox reaches another that is listening',
      () async {
    final listener = make();
    final speaker = make();
    final heard = <MailboxMessage>[];
    listener.messages.listen(heard.add);

    await listener.subscribe('topic-one');
    await speaker.publish('topic-one', _b([1, 2, 3, 250]));
    await _until(() => heard.isNotEmpty);

    expect(heard.single.topic, 'topic-one');
    expect(heard.single.payload, [1, 2, 3, 250]);
    expect(heard.single.source, 'nostr');
    expect(relay.rejectedEvents, 0, reason: 'the relay accepted the signature');
  });

  test('nothing is kept for a subscriber that was late', () async {
    final speaker = make();
    final listener = make();
    final heard = <MailboxMessage>[];
    listener.messages.listen(heard.add);

    await speaker.publish('t', _b([1]));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await listener.subscribe('t');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(heard, isEmpty);
  });

  test('several topics share one connection and are told apart by their tag',
      () async {
    final listener = make();
    final speaker = make();
    final heard = <MailboxMessage>[];
    listener.messages.listen(heard.add);

    await listener.subscribe('one');
    await listener.subscribe('two');
    await speaker.publish('two', _b([2]));
    await speaker.publish('one', _b([1]));
    await speaker.publish('three', _b([3]));
    await _until(() => heard.length >= 2);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(heard.map((m) => '${m.topic}:${m.payload.first}').toSet(),
        {'one:1', 'two:2'});
    expect(relay.connections, hasLength(2), reason: 'one per mailbox, not per topic');
    final ids = relay.subscriptionIds.toSet();
    expect(ids.length, 2, reason: 'a subscription id for each topic');
    expect(ids.every((id) => id.length <= 64), isTrue);
  });

  test('an event for a topic nobody asked for is ignored, whatever the relay '
      'says about it', () async {
    final listener = make();
    final heard = <MailboxMessage>[];
    listener.messages.listen(heard.add);
    await listener.subscribe('mine');

    final stranger = make();
    await stranger.publish('theirs', _b([9]));
    // The relay lies and sends it down the subscription for "mine".
    relay.say(jsonEncode([
      'EVENT',
      relay.subscriptionIds.single,
      {
        'id': 'ab' * 32,
        'pubkey': 'cd' * 32,
        'created_at': 1,
        'kind': 20000,
        'tags': [
          ['t', 'theirs']
        ],
        'content': base64.encode([9]),
        'sig': 'ef' * 64,
      }
    ]));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(heard, isEmpty);
  });

  test('hostile frames neither crash the mailbox nor stop it', () async {
    final listener = make();
    final speaker = make();
    final heard = <MailboxMessage>[];
    listener.messages.listen(heard.add);
    await listener.subscribe('t');
    final sub = relay.subscriptionIds.single;

    Map<String, dynamic> event({Object? content, Object? tags, Object? kind}) => {
          'id': 'id${heard.length}${DateTime.now().microsecondsSinceEpoch}',
          'pubkey': 'cd' * 32,
          'created_at': 1,
          'kind': kind ?? 20000,
          'tags': tags ??
              [
                ['t', 't']
              ],
          'content': content ?? base64.encode([1]),
          'sig': 'ef' * 64,
        };

    for (final frame in <Object>[
      'not json at all',
      '[]',
      '{}',
      '"EVENT"',
      jsonEncode(['EVENT']),
      jsonEncode(['EVENT', sub]),
      jsonEncode(['EVENT', sub, 'not a map']),
      jsonEncode(['EVENT', sub, event(content: 42)]),
      jsonEncode(['EVENT', sub, event(content: '!!! not base64 !!!')]),
      jsonEncode(['EVENT', sub, event(content: 'A' * 40000)]),
      jsonEncode(['EVENT', sub, event(tags: 'nope')]),
      jsonEncode(['EVENT', sub, event(tags: [[], 5, ['t']])]),
      jsonEncode(['EVENT', sub, event(kind: 1)]),
      jsonEncode(['NOTICE', 'rate limited']),
      jsonEncode(['CLOSED', sub, 'auth-required']),
      jsonEncode(['OK', 'x', false, 'blocked']),
      jsonEncode(['SOMETHING', 'else']),
    ]) {
      relay.say(frame as String);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(heard, isEmpty);

    await speaker.publish('t', _b([42]));
    await _until(() => heard.isNotEmpty);
    expect(heard.single.payload, [42], reason: 'still listening');
  });

  test('the same event arriving twice is delivered once', () async {
    final listener = make();
    final heard = <MailboxMessage>[];
    listener.messages.listen(heard.add);
    await listener.subscribe('t');

    final event = {
      'id': '12' * 32,
      'pubkey': 'cd' * 32,
      'created_at': 1,
      'kind': 20000,
      'tags': [
        ['t', 't']
      ],
      'content': base64.encode([5]),
      'sig': 'ef' * 64,
    };
    relay.forward(event);
    relay.forward(event);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(heard, hasLength(1));
  });

  test('unsubscribing tells the relay and stops delivery', () async {
    final listener = make();
    final speaker = make();
    final heard = <MailboxMessage>[];
    listener.messages.listen(heard.add);
    await listener.subscribe('t');
    await listener.unsubscribe('t');
    await _until(() => relay.closed.isNotEmpty);

    await speaker.publish('t', _b([1]));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(relay.closed.single, relay.subscriptionIds.single);
    expect(heard, isEmpty);
    expect(relay.subscribed, 0);
  });

  test('a relay that drops the connection is reconnected and every topic '
      'still wanted is asked for again', () async {
    final listener = make();
    final speaker = make();
    final heard = <MailboxMessage>[];
    listener.messages.listen(heard.add);
    await listener.subscribe('one');
    await listener.subscribe('two');
    await listener.unsubscribe('two');

    await relay.dropConnections();
    await _until(() => relay.subscribed >= 1,
        within: const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await speaker.publish('one', _b([1]));
    await speaker.publish('two', _b([2]));
    await _until(() => heard.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(heard.map((m) => m.topic), ['one'],
        reason: 'the topic given up is not asked for again');
  });

  test('one relay down: the other carries it; all down: says so', () async {
    final dead = await _Relay.start();
    final deadUrl = dead.url;
    await dead.stop();

    final both = make(relays: [deadUrl, relay.url]);
    await both.subscribe('t');
    await both.publish('t', _b([1]));

    final none = make(relays: [deadUrl]);
    await expectLater(none.subscribe('t'), throwsA(isA<MailboxUnavailable>()));
    await expectLater(
        none.publish('t', _b([1])), throwsA(isA<MailboxUnavailable>()));
  });

  test('subscribing waits until the relay says it is listening, so a message '
      'sent right after it is not lost', () async {
    final listener = make();
    final speaker = make();
    final heard = <MailboxMessage>[];
    listener.messages.listen(heard.add);

    await listener.subscribe('t');
    expect(relay.subscribed, 1,
        reason: 'by the time subscribe returns, the relay has registered it');
    await speaker.publish('t', _b([7]));
    await _until(() => heard.isNotEmpty);
  });

  test('a relay that never says so is taken at its word after a moment',
      () async {
    relay.answersEose = false;
    final listener = make();
    final watch = Stopwatch()..start();

    await listener.subscribe('t');

    expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 250)));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('closing drops the connection and every subscription', () async {
    final listener = make();
    await listener.subscribe('t');
    expect(relay.subscribed, 1);

    await listener.close();
    await _until(() => relay.subscribed == 0);

    await expectLater(
        listener.subscribe('t'), throwsA(isA<MailboxUnavailable>()));
    await expectLater(
        listener.publish('t', _b([1])), throwsA(isA<MailboxUnavailable>()));
  });

  test('a topic is never turned into a subscription id that two topics could '
      'share', () {
    expect(NostrCodeMailbox.subscriptionId('a-b_c'),
        isNot(NostrCodeMailbox.subscriptionId('abc')));
    expect(NostrCodeMailbox.subscriptionId('x' * 500), hasLength(26));
  });
}

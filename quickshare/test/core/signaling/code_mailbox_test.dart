// Two public channels used as one: whichever delivers first wins, a failure on
// one never stops the other, and a message that is forged to look like a real
// one is not mistaken for it.
import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/signaling/code_mailbox.dart';

import '../../support/fake_mailbox.dart';

Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);

void main() {
  late FakeMailboxHub hub;
  late FakeMailbox a;
  late FakeMailbox b;
  late RacingCodeMailbox racing;
  late FakeMailbox peer;
  late List<MailboxMessage> heard;

  setUp(() {
    hub = FakeMailboxHub();
    a = hub.endpoint('nostr');
    b = hub.endpoint('worker');
    racing = RacingCodeMailbox([a, b]);
    peer = hub.endpoint('peer');
    heard = [];
    racing.messages.listen(heard.add);
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('a message heard on both channels is delivered once', () async {
    await racing.subscribe('t');
    await peer.publish('t', _b([1, 2, 3]));
    await flush();

    expect(heard, hasLength(1));
    expect(heard.single.payload, [1, 2, 3]);
    expect(heard.single.topic, 't');
  });

  test('a repeat from the same channel is not delivered twice either',
      () async {
    hub.duplicates = 3;
    await racing.subscribe('t');
    await peer.publish('t', _b([9]));
    await flush();

    expect(heard, hasLength(1));
  });

  test('two different messages on one topic are both delivered', () async {
    await racing.subscribe('t');
    await peer.publish('t', _b([1]));
    await peer.publish('t', _b([2]));
    await flush();

    expect(heard.map((m) => m.payload.first), [1, 2]);
  });

  test('the same bytes on another topic are another message', () async {
    await racing.subscribe('t');
    await racing.subscribe('u');
    await peer.publish('t', _b([1]));
    await peer.publish('u', _b([1]));
    await flush();

    expect(heard.map((m) => m.topic), ['t', 'u']);
  });

  test('a forged copy that shares the start of the real one does not shadow '
      'it', () async {
    await racing.subscribe('t');
    final real = _b(List.filled(400, 7));
    final forged = _b([...List.filled(399, 7), 8]);
    await peer.publish('t', forged);
    await peer.publish('t', real);
    await flush();

    expect(heard, hasLength(2),
        reason: 'the whole payload decides, not a prefix of it');
  });

  group('subscribing', () {
    test('one channel down: the other is enough', () async {
      a.down = true;
      await racing.subscribe('t');
      await peer.publish('t', _b([5]));
      await flush();

      expect(heard, hasLength(1));
    });

    test('both channels down: says so, with a type of its own', () async {
      a.down = true;
      b.down = true;

      await expectLater(racing.subscribe('t'), throwsA(isA<MailboxUnavailable>()));
    });

    test('a channel that never answers is given up on, not waited for', () {
      fakeAsync((async) {
        final stuck = _Stuck();
        final lone = RacingCodeMailbox([stuck],
            subscribeTimeout: const Duration(seconds: 3));
        Object? error;
        lone.subscribe('t').catchError((Object e) => error = e);

        async.elapse(const Duration(seconds: 2));
        expect(error, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(error, isA<MailboxUnavailable>());
      });
    });

    test('a slow channel does not hold up a fast one', () {
      fakeAsync((async) {
        final stuck = _Stuck();
        final fast = hub.endpoint('fast');
        final both = RacingCodeMailbox([stuck, fast]);
        var done = false;
        both.subscribe('t').then((_) => done = true);
        async.flushMicrotasks();

        expect(done, isTrue);
      });
    });
  });

  group('publishing', () {
    test('goes to both channels', () async {
      await racing.publish('t', _b([1]));

      expect(a.publishCalls, 1);
      expect(b.publishCalls, 1);
    });

    test('one channel down: the other has taken it, so it is published',
        () async {
      b.down = true;
      await racing.publish('t', _b([1]));

      expect(hub.published, hasLength(1));
    });

    test('both down: fails, so the caller can say "no network"', () async {
      a.down = true;
      b.down = true;

      await expectLater(
          racing.publish('t', _b([1])), throwsA(isA<MailboxUnavailable>()));
    });

    test('returns when the first channel has it, not the slowest', () {
      fakeAsync((async) {
        final stuck = _Stuck();
        final fast = hub.endpoint('fast');
        final both = RacingCodeMailbox([stuck, fast]);
        var done = false;
        both.publish('t', _b([1])).then((_) => done = true);
        async.flushMicrotasks();

        expect(done, isTrue);
      });
    });
  });

  test('unsubscribing reaches every channel', () async {
    await racing.subscribe('t');
    await racing.unsubscribe('t');

    expect(a.subscribed, isEmpty);
    expect(b.subscribed, isEmpty);
    await peer.publish('t', _b([1]));
    await flush();
    expect(heard, isEmpty);
  });

  test('closing closes every channel, drops every topic and goes quiet',
      () async {
    await racing.subscribe('t');
    await racing.close();

    expect(a.isClosed, isTrue);
    expect(b.isClosed, isTrue);
    expect(a.subscribed, isEmpty);
    await peer.publish('t', _b([1]));
    await flush();
    expect(heard, isEmpty);
    await expectLater(
        racing.publish('t', _b([1])), throwsA(isA<MailboxUnavailable>()));
    await expectLater(
        racing.subscribe('t'), throwsA(isA<MailboxUnavailable>()));
  });

  test('closing twice is harmless', () async {
    await racing.close();
    await racing.close();
  });

  test('the message says which channel carried it first', () async {
    await racing.subscribe('t');
    await peer.publish('t', _b([1]));
    await flush();

    expect(heard.single.source, anyOf('nostr', 'worker'));
  });
}

/// A channel that accepts everything and answers nothing.
class _Stuck implements CodeMailbox {
  @override
  String get name => 'stuck';
  @override
  Stream<MailboxMessage> get messages => const Stream.empty();
  @override
  Future<void> subscribe(String topic) => Completer<void>().future;
  @override
  Future<void> unsubscribe(String topic) async {}
  @override
  Future<void> publish(String topic, Uint8List payload) =>
      Completer<void>().future;
  @override
  Future<void> close() async {}
}

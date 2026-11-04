// The answer goes out on every channel at once, and the first to carry it wins.
//
// "Wins" has to mean what it says on the way out as well as on the way in. The
// Worker channel now retries a 429 for up to a couple of minutes, and a
// receiver that waited for the slowest channel before moving on would sit
// behind that retry even though Nostr delivered the answer in a second.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/signaling/answer_channel.dart';

class _Channel implements AnswerChannel {
  _Channel(this.label);
  final String label;
  final Completer<void> publishing = Completer<void>();
  int published = 0;
  bool closed = false;

  @override
  String get name => label;

  @override
  Stream<Uint8List> get answers => const Stream.empty();

  @override
  Future<void> subscribe(String topic) async {}

  @override
  Future<void> publish(String topic, Uint8List payload) {
    published++;
    return publishing.future;
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  final payload = Uint8List.fromList([1, 2, 3]);

  test('publish returns as soon as one channel has carried the answer',
      () async {
    final nostr = _Channel('nostr');
    final worker = _Channel('worker');
    final racing = RacingAnswerChannel([nostr, worker]);

    var returned = false;
    final done = racing.publish('t', payload).then((_) => returned = true);

    nostr.publishing.complete();
    await done.timeout(const Duration(seconds: 1));

    expect(returned, isTrue);
    expect(worker.publishing.isCompleted, isFalse,
        reason: 'the Worker is still retrying, and nobody is waiting for it');
    expect(worker.published, equals(1), reason: 'it was still asked to publish');

    // Its eventual failure is logged, not thrown into the void.
    worker.publishing.completeError(StateError('late failure'));
    await Future<void>.delayed(Duration.zero);
  });

  test('a channel that fails first does not stop another from winning',
      () async {
    final nostr = _Channel('nostr');
    final worker = _Channel('worker');
    final racing = RacingAnswerChannel([nostr, worker]);

    final done = racing.publish('t', payload);
    nostr.publishing.completeError(StateError('relay refused'));
    await Future<void>.delayed(Duration.zero);
    worker.publishing.complete();

    await done.timeout(const Duration(seconds: 1));
  });

  test('when every channel fails, the error says what each one said', () async {
    final nostr = _Channel('nostr');
    final worker = _Channel('worker');
    final racing = RacingAnswerChannel([nostr, worker]);

    final done = racing.publish('t', payload);
    nostr.publishing.completeError(StateError('all relays refused'));
    worker.publishing
        .completeError(StateError('HTTP 429 rate_limited after 3 attempts'));

    await expectLater(
      done,
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('nostr'))
          .having((e) => e.message, 'message', contains('all relays refused'))
          .having((e) => e.message, 'message', contains('worker'))
          .having((e) => e.message, 'message', contains('HTTP 429'))),
    );
  });

  test('closing the race closes every channel, including one still publishing',
      () async {
    final nostr = _Channel('nostr');
    final worker = _Channel('worker');
    final racing = RacingAnswerChannel([nostr, worker]);

    unawaited(racing.publish('t', payload));
    nostr.publishing.complete();
    await Future<void>.delayed(Duration.zero);
    await racing.close();

    expect(nostr.closed, isTrue);
    expect(worker.closed, isTrue);
    worker.publishing.complete();
  });
}

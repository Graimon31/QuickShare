import 'dart:async';
import 'dart:typed_data';

import 'package:quickshare/core/signaling/code_mailbox.dart';

/// One message as it was put on the fake public mailbox, before anything
/// happened to it. What a relay operator would have been able to read.
class PublishedMessage {
  PublishedMessage(this.topic, this.payload, this.at, this.by);

  final String topic;
  final Uint8List payload;
  final Duration at;
  final String by;
}

/// A public mailbox in memory, as hostile as the real ones.
///
/// It behaves like the relays and the Worker the protocol has to survive:
///
///  * **ephemeral** — a message reaches only those subscribed when it arrives,
///    so a late subscriber loses it for good;
///  * **slow and uneven** — [latency], and [delayFor] per message, which also
///    lets messages overtake one another;
///  * **repeating** — [duplicates] extra copies of every message;
///  * **lossy** — [dropIf] makes a chosen message vanish;
///  * **forging** — [tamper] replaces a message on the way, and [inject] lets a
///    stranger publish anything.
///
/// Everything published is recorded in [published], undisturbed, so a test can
/// read the mailbox as an eavesdropper would.
class FakeMailboxHub {
  FakeMailboxHub({this.latency = Duration.zero});

  Duration latency;
  int duplicates = 0;
  Duration Function(String topic, Uint8List payload, int sequence)? delayFor;
  bool Function(String topic, Uint8List payload)? dropIf;
  Uint8List Function(String topic, Uint8List payload)? tamper;

  /// What the mailbox's operator can see, in order.
  final List<PublishedMessage> published = [];

  /// Every subscribe, unsubscribe and publish by anyone, in the order it was
  /// asked, as `who subscribe topic`. For tests of "listen before you speak".
  final List<String> log = [];
  final List<FakeMailbox> _endpoints = [];
  final Stopwatch _clock = Stopwatch()..start();
  int _sequence = 0;

  /// A new participant. Give each party — and each channel of a racing pair —
  /// its own.
  FakeMailbox endpoint([String name = 'fake']) {
    final endpoint = FakeMailbox._(this, name);
    _endpoints.add(endpoint);
    return endpoint;
  }

  /// Every topic anybody is listening on right now.
  Set<String> get listenedTopics => {
        for (final e in _endpoints)
          if (!e.isClosed) ...e.subscribed,
      };

  /// How many participants are still open.
  int get openEndpoints => _endpoints.where((e) => !e.isClosed).length;

  /// A stranger with no subscriptions publishes [payload] on [topic].
  void inject(String topic, Uint8List payload) =>
      _route(topic, payload, 'stranger');

  void _route(String topic, Uint8List payload, String by,
      {Duration? extraDelay}) {
    log.add('$by publish $topic');
    published.add(PublishedMessage(topic, payload, _clock.elapsed, by));
    if (dropIf?.call(topic, payload) ?? false) return;
    final sequence = _sequence++;
    final delivered = tamper?.call(topic, payload) ?? payload;
    final delay =
        (delayFor?.call(topic, payload, sequence) ?? latency) + (extraDelay ?? Duration.zero);
    for (var copy = 0; copy <= duplicates; copy++) {
      if (delay == Duration.zero) {
        scheduleMicrotask(() => _deliver(topic, delivered));
      } else {
        Timer(delay, () => _deliver(topic, delivered));
      }
    }
  }

  void _deliver(String topic, Uint8List payload) {
    for (final endpoint in _endpoints.toList()) {
      endpoint._hear(topic, payload);
    }
  }
}

/// One participant's view of a [FakeMailboxHub].
class FakeMailbox implements CodeMailbox {
  FakeMailbox._(this._hub, this.name);

  final FakeMailboxHub _hub;
  @override
  final String name;
  final _controller = StreamController<MailboxMessage>.broadcast();
  final Set<String> subscribed = {};
  bool _closed = false;

  /// This channel is down: listening and speaking both fail.
  bool down = false;

  /// Everything this participant says takes this much longer to arrive.
  Duration? publishDelay;
  int subscribeCalls = 0;
  int unsubscribeCalls = 0;
  int publishCalls = 0;

  bool get isClosed => _closed;

  @override
  Stream<MailboxMessage> get messages => _controller.stream;

  @override
  Future<void> subscribe(String topic) async {
    subscribeCalls++;
    if (_closed || down) throw const MailboxUnavailable('fake channel is down');
    subscribed.add(topic);
    _hub.log.add('$name subscribe $topic');
  }

  @override
  Future<void> unsubscribe(String topic) async {
    unsubscribeCalls++;
    subscribed.remove(topic);
    _hub.log.add('$name unsubscribe $topic');
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    publishCalls++;
    if (_closed || down) throw const MailboxUnavailable('fake channel is down');
    _hub._route(topic, Uint8List.fromList(payload), name,
        extraDelay: publishDelay);
  }

  void _hear(String topic, Uint8List payload) {
    if (_closed || down || !subscribed.contains(topic)) return;
    if (!_controller.isClosed) {
      _controller.add(MailboxMessage(topic, payload, source: name));
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    subscribed.clear();
    unawaited(_controller.close());
  }
}

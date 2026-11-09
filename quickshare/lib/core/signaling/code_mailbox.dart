import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// One message a mailbox heard on a topic it was subscribed to.
class MailboxMessage {
  final String topic;
  final Uint8List payload;

  /// Which channel carried it first (`nostr`, `worker`, ...). For logs and the
  /// live check; nothing is decided by it.
  final String source;

  const MailboxMessage(this.topic, this.payload, {this.source = ''});
}

/// No channel could be reached: not "the code is wrong", not "nobody answered"
/// — the network or both public services are down. Its own type so the
/// receiver can say exactly that instead of blaming the code.
class MailboxUnavailable implements Exception {
  final String detail;
  const MailboxUnavailable(this.detail);

  @override
  String toString() => 'MailboxUnavailable: $detail';
}

/// A public drop point that carries small messages between two devices that
/// share nothing but a short code.
///
/// Unlike [AnswerChannel], which waits for one sealed answer on one topic, a
/// mailbox is a conversation: several topics are listened to at once, several
/// messages arrive on each, and either end both listens and speaks. It stays
/// deliberately dumb — bytes in, bytes out — and says nothing about what they
/// mean; every check that matters is made by the protocol on top, because the
/// operator of a relay or of the Worker can read, drop, repeat, reorder and
/// forge anything that passes through.
///
/// Delivery is best effort: a message published before the other side
/// subscribed may never arrive (Nostr keeps nothing), the same message may
/// arrive twice, and two messages may swap places. The protocol is written so
/// that each side subscribes before it provokes a reply.
abstract class CodeMailbox {
  /// Short label for logs.
  String get name;

  /// Everything heard on the subscribed topics, from every channel.
  Stream<MailboxMessage> get messages;

  /// Starts listening on [topic]. Completes once at least one channel is
  /// listening, so the caller can provoke a reply; throws
  /// [MailboxUnavailable] when none could be reached. Calling it again for a
  /// topic already listened to is harmless.
  Future<void> subscribe(String topic);

  /// Stops listening on [topic]. Never throws.
  Future<void> unsubscribe(String topic);

  /// Puts [payload] on [topic]. Completes as soon as one channel has taken it;
  /// throws [MailboxUnavailable] when every channel refused.
  Future<void> publish(String topic, Uint8List payload);

  /// Drops every subscription and every pending wait. Never throws, and a
  /// closed mailbox says nothing more.
  Future<void> close();
}

/// Several mailboxes used as one: listens on all, speaks on all, and delivers
/// whichever copy of a message arrives first.
///
/// The channels are free and unowned, so nobody promises they are up; two
/// with independent operators and protocols turn two coin flips into a much
/// better bet. A failure — or a 429 — on one never stops the other.
class RacingCodeMailbox implements CodeMailbox {
  RacingCodeMailbox(
    this.channels, {
    this.subscribeTimeout = const Duration(seconds: 10),
    this.seenLimit = 256,
  }) : assert(channels.isNotEmpty, 'need at least one channel') {
    for (final channel in channels) {
      _listening.add(channel.messages.listen(
        (m) => _onMessage(channel, m),
        onError: (Object _) {},
      ));
    }
  }

  final List<CodeMailbox> channels;

  /// How long [subscribe] waits for the first channel before calling it
  /// unreachable. A black-holed channel must cost seconds, not an OS timeout.
  final Duration subscribeTimeout;

  /// How many distinct messages are remembered for de-duplication.
  final int seenLimit;

  final _controller = StreamController<MailboxMessage>.broadcast();
  final _listening = <StreamSubscription<MailboxMessage>>[];
  final _seen = <String>[];
  final _seenSet = <String>{};
  bool _closed = false;

  @override
  String get name => channels.map((c) => c.name).join('+');

  @override
  Stream<MailboxMessage> get messages => _controller.stream;

  @override
  Future<void> subscribe(String topic) async {
    if (_closed) throw const MailboxUnavailable('the mailbox is closed');
    final first = Completer<void>();
    final failures = <String>[];
    var pending = channels.length;

    for (final channel in channels) {
      unawaited(() async {
        try {
          await channel.subscribe(topic);
          if (!first.isCompleted) first.complete();
        } catch (e) {
          failures.add('${channel.name}: $e');
          AppLogger.warning('Mailbox ${channel.name} cannot listen: $e',
              tag: 'SIGNALING');
        }
        pending--;
        if (pending == 0 && !first.isCompleted) {
          first.completeError(MailboxUnavailable(
              'no channel could be reached (${failures.join('; ')})'));
        }
      }());
    }

    await first.future.timeout(
      subscribeTimeout,
      onTimeout: () =>
          throw const MailboxUnavailable('no channel answered in time'),
    );
  }

  @override
  Future<void> unsubscribe(String topic) async {
    await Future.wait(channels.map((c) async {
      try {
        await c.unsubscribe(topic);
      } catch (_) {}
    }));
  }

  /// Returns as soon as ONE channel has carried the message and fails only
  /// when every channel has failed. The channels still trying carry on in the
  /// background until [close].
  @override
  Future<void> publish(String topic, Uint8List payload) async {
    if (_closed) throw const MailboxUnavailable('the mailbox is closed');
    final delivered = Completer<void>();
    final failures = <String>[];
    var pending = channels.length;

    for (final channel in channels) {
      unawaited(() async {
        try {
          await channel.publish(topic, payload);
          if (!delivered.isCompleted) delivered.complete();
        } catch (e) {
          failures.add('${channel.name}: $e');
          AppLogger.warning('Mailbox ${channel.name} could not publish: $e',
              tag: 'SIGNALING');
        }
        pending--;
        if (pending == 0 && !delivered.isCompleted) {
          delivered.completeError(MailboxUnavailable(
              'could not publish through any channel (${failures.join('; ')})'));
        }
      }());
    }

    await delivered.future;
  }

  /// Gives every channel a chance to publish before its owner closes us.
  /// Used for cancellation, where closing on the first channel's success
  /// would interrupt a retry on the channel the other device may be using.
  Future<void> publishToAll(String topic, Uint8List payload) async {
    if (_closed) throw const MailboxUnavailable('the mailbox is closed');
    var delivered = false;
    await Future.wait(channels.map((channel) async {
      try {
        await channel.publish(topic, payload);
        delivered = true;
      } catch (e) {
        AppLogger.warning('Mailbox ${channel.name} could not publish: $e',
            tag: 'SIGNALING');
      }
    }));
    if (!delivered) {
      throw const MailboxUnavailable('could not publish through any channel');
    }
  }

  void _onMessage(CodeMailbox channel, MailboxMessage message) {
    if (_closed) return;
    // The same message arrives once per healthy channel; hand it on once. The
    // whole payload goes into the key: a forged copy that shares a prefix with
    // the real one must not shadow it.
    final key = '${message.topic}\u0000${_fingerprint(message.payload)}';
    if (!_seenSet.add(key)) return;
    _seen.add(key);
    if (_seen.length > seenLimit) _seenSet.remove(_seen.removeAt(0));
    if (!_controller.isClosed) {
      _controller.add(MailboxMessage(message.topic, message.payload,
          source: channel.name));
    }
  }

  static String _fingerprint(Uint8List bytes) =>
      sha256.convert(bytes).toString();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final s in _listening) {
      unawaited(s.cancel());
    }
    _listening.clear();
    await Future.wait(channels.map((c) async {
      try {
        await c.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }));
    // Not awaited: the future of a broadcast controller whose listeners have
    // already gone is not one to wait on.
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}

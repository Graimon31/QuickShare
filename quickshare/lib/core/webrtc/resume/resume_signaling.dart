import 'dart:async';
import 'dart:typed_data';

import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/resume/resume_keys.dart';

/// No valid answer to the offer arrived in time.
class ResumeSignalingTimeout implements Exception {
  const ResumeSignalingTimeout(this.generation, this.waited);

  final int generation;
  final Duration waited;

  @override
  String toString() => 'no answer to the reconnection offer for link '
      '$generation in ${waited.inSeconds}s';
}

/// An offer for a replacement link, as the receiver hears it.
class ResumeOffer {
  const ResumeOffer(this.generation, this.sdp);

  /// Which link this is. Higher than every one the receiver has heard before.
  final int generation;
  final Uint8List sdp;
}

/// The sender's half of finding the receiver again: puts a sealed offer for a
/// replacement link on the public mailbox, and waits for the sealed answer.
///
/// Everything on the mailbox is hostile until it opens. The relay or the
/// Worker can read, drop, repeat, reorder and forge anything that passes
/// through, so what makes an answer count is not where it came from but that
/// it opens under [ResumeKeys] as an *answer* for *this* generation: only the
/// receiver of this transfer holds those keys. A message that does not open is
/// ignored and not mentioned beyond a counter, because a stranger's message is
/// not an error and must not be able to end an attempt.
///
/// Delivery is best effort (see [CodeMailbox]), so the offer is published
/// again every [republishEvery] until the answer arrives: a receiver that was
/// not yet listening when the first copy went out, or a relay that dropped
/// it, costs a few seconds and not the attempt.
class ResumeSenderSignaling {
  ResumeSenderSignaling({
    required this.mailbox,
    required this.keys,
    this.republishEvery = const Duration(seconds: 4),
    this.tag = 'RESUME_SENDER',
  });

  final CodeMailbox mailbox;
  final ResumeKeys keys;
  final Duration republishEvery;
  final String tag;

  // The subscription is cancelled by close().
  // ignore: cancel_subscriptions
  StreamSubscription<MailboxMessage>? _listening;
  Completer<Uint8List>? _waiting;
  int _waitingFor = 0;
  int _ignored = 0;
  bool _opened = false;
  bool _closed = false;
  bool _offering = false;

  /// How many messages on the answer topic did not open as the answer being
  /// waited for. For tests and the log.
  int get ignored => _ignored;

  /// Starts listening for answers. Throws [MailboxUnavailable] when no channel
  /// could be reached. Listening comes before speaking: the answer cannot be
  /// missed because it was sent before anybody was there to hear it.
  Future<void> open() async {
    if (_opened || _closed) return;
    _opened = true;
    _listening = mailbox.messages.listen(_onMessage, onError: (Object _) {});
    try {
      await mailbox.subscribe(keys.answerTopic);
      if (_closed) {
        await mailbox.close();
        throw StateError('the signaling was closed');
      }
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _onMessage(MailboxMessage message) {
    if (_closed || message.topic != keys.answerTopic) return;
    final waiting = _waiting;
    if (waiting == null || waiting.isCompleted) return;
    // Cheap checks first: size, and a generation that is not the one asked
    // about is somebody else's, or an old answer coming round again.
    final claimed = ResumeKeys.peekGeneration(message.payload);
    if (claimed == null || claimed != _waitingFor) {
      _ignored++;
      return;
    }
    unawaited(() async {
      final opened =
          await keys.open(kind: ResumeKind.answer, envelope: message.payload);
      final still = _waiting;
      if (opened == null || opened.generation != _waitingFor) {
        _ignored++;
        return;
      }
      if (still != null && !still.isCompleted && identical(still, waiting)) {
        still.complete(opened.plaintext);
      }
    }());
  }

  /// Publishes [offerSdp] sealed as the offer for link [generation], again and
  /// again until the receiver's answer for that same link arrives, and returns
  /// it. Throws [ResumeSignalingTimeout] after [timeout].
  ///
  /// One offer at a time: concurrent attempts are rejected.
  Future<Uint8List> offer({
    required int generation,
    required Uint8List offerSdp,
    required Duration timeout,
  }) async {
    if (!_opened || _closed) {
      throw StateError('the signaling is not open');
    }
    if (_offering) throw StateError('an offer is already pending');
    _offering = true;
    try {
      return await _offer(generation, offerSdp, timeout);
    } finally {
      _offering = false;
    }
  }

  Future<Uint8List> _offer(
      int generation, Uint8List offerSdp, Duration timeout) async {
    final sealed = await keys.seal(
        kind: ResumeKind.offer, generation: generation, plaintext: offerSdp);
    if (_closed) throw StateError('the signaling was closed');
    if (sealed.length > ResumeKeys.maxEnvelopeBytes) {
      throw StateError('the sealed offer is ${sealed.length} bytes, too big '
          'for the mailbox');
    }
    final waiting = Completer<Uint8List>();
    _waiting = waiting;
    _waitingFor = generation;

    final started = DateTime.now();
    Timer? ticker;
    var publishing = false;
    Future<void> publish() async {
      if (publishing || waiting.isCompleted || _closed) return;
      publishing = true;
      try {
        await mailbox.publish(keys.offerTopic, sealed);
      } catch (e) {
        // Not the end of the attempt: the next tick tries again, and the
        // attempt's own clock is what ends it.
        AppLogger.warning(
            'Reconnection offer for link $generation not published: '
            '${e.runtimeType}',
            tag: tag);
      } finally {
        publishing = false;
      }
    }

    unawaited(publish());
    ticker = Timer.periodic(republishEvery, (_) => unawaited(publish()));
    try {
      return await waiting.future.timeout(timeout, onTimeout: () {
        throw ResumeSignalingTimeout(
            generation, DateTime.now().difference(started));
      });
    } finally {
      ticker.cancel();
      if (identical(_waiting, waiting)) _waiting = null;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(StateError('the signaling was closed'));
    }
    final listening = _listening;
    _listening = null;
    await listening?.cancel();
    try {
      await mailbox.close();
    } catch (_) {}
  }
}

/// A sealed answer being published until the sender has what it needs.
class ResumeAnswerPublication {
  ResumeAnswerPublication._(this._stop);

  final void Function() _stop;

  /// Stops publishing. The link came up, or the attempt was given up.
  void stop() => _stop();
}

/// The receiver's half: listens for sealed offers for a replacement link, and
/// answers the one it accepts.
///
/// An offer counts when it opens as an *offer* under [ResumeKeys] and is for a
/// link newer than any heard before. The second condition is the whole of
/// replay protection: a recorded offer, however valid it once was, is for a
/// link that has already been taken or passed by, and is dropped before any
/// cryptography is spent on it. An offer that does not open — a stranger's, a
/// forged one, one for another transfer — is dropped without a trace.
class ResumeReceiverSignaling {
  ResumeReceiverSignaling({
    required this.mailbox,
    required this.keys,
    this.republishEvery = const Duration(seconds: 4),
    this.tag = 'RESUME_RECEIVER',
  });

  final CodeMailbox mailbox;
  final ResumeKeys keys;
  final Duration republishEvery;
  final String tag;

  final _offers = StreamController<ResumeOffer>.broadcast();
  // The subscription is cancelled by close().
  // ignore: cancel_subscriptions
  StreamSubscription<MailboxMessage>? _listening;
  int _highest = 0;
  int _ignored = 0;
  bool _opened = false;
  bool _closed = false;
  final _publications = <ResumeAnswerPublication>{};

  /// The newest link the receiver has accepted an offer for; 1 is the link the
  /// QR code started.
  int get highestGeneration => _highest;

  /// Messages on the offer topic that were not an acceptable offer.
  int get ignored => _ignored;

  Stream<ResumeOffer> get offers => _offers.stream;

  /// Marks [generation] as taken without there having been an offer for it:
  /// the link that is already up is 1, and nothing at or below it is an offer.
  void startFrom(int generation) {
    if (generation > _highest) _highest = generation;
  }

  Future<void> open() async {
    if (_opened || _closed) return;
    _opened = true;
    _listening = mailbox.messages.listen(_onMessage, onError: (Object _) {});
    try {
      await mailbox.subscribe(keys.offerTopic);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _onMessage(MailboxMessage message) {
    if (_closed || message.topic != keys.offerTopic) return;
    final claimed = ResumeKeys.peekGeneration(message.payload);
    if (claimed == null || claimed <= _highest) {
      _ignored++;
      return;
    }
    unawaited(() async {
      final opened =
          await keys.open(kind: ResumeKind.offer, envelope: message.payload);
      if (_closed) return;
      // Looked at again: another message may have been taken while this one
      // was being opened.
      if (opened == null || opened.generation <= _highest) {
        _ignored++;
        return;
      }
      _highest = opened.generation;
      if (!_offers.isClosed) {
        _offers.add(ResumeOffer(opened.generation, opened.plaintext));
      }
    }());
  }

  /// Publishes [answerSdp] sealed as the answer for link [generation], now and
  /// every [republishEvery] until [ResumeAnswerPublication.stop] or
  /// [forAtMost] passes.
  ResumeAnswerPublication answer({
    required int generation,
    required Uint8List answerSdp,
    required Duration forAtMost,
  }) {
    Timer? ticker;
    Timer? expiry;
    var stopped = false;
    var publishing = false;
    Uint8List? sealed;

    late final ResumeAnswerPublication publication;
    void stop() {
      if (stopped) return;
      stopped = true;
      ticker?.cancel();
      expiry?.cancel();
      _publications.remove(publication);
    }

    publication = ResumeAnswerPublication._(stop);
    _publications.add(publication);

    Future<void> publish() async {
      if (stopped || publishing || _closed) return;
      publishing = true;
      try {
        sealed ??= await keys.seal(
            kind: ResumeKind.answer,
            generation: generation,
            plaintext: answerSdp);
        if (stopped || _closed) return;
        await mailbox.publish(keys.answerTopic, sealed!);
      } catch (e) {
        AppLogger.warning(
            'Reconnection answer for link $generation not published: '
            '${e.runtimeType}',
            tag: tag);
      } finally {
        publishing = false;
      }
    }

    unawaited(publish());
    ticker = Timer.periodic(republishEvery, (_) => unawaited(publish()));
    expiry = Timer(forAtMost, stop);
    return publication;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final p in _publications.toList()) {
      p.stop();
    }
    final listening = _listening;
    _listening = null;
    await listening?.cancel();
    if (!_offers.isClosed) unawaited(_offers.close());
    try {
      await mailbox.close();
    } catch (_) {}
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/internet_code.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/core/signaling/code_mailbox_factory.dart';
import 'package:quickshare/core/signaling/rendezvous_channels.dart'
    show NoRendezvousChannelConfigured;
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';

/// Looks for the sender of a code over the internet: the receiver's half of
/// `InternetCodeSender`.
///
/// ```text
///   receiver                                      sender (listening on T)
///   n, replyTopic; SUBSCRIBE replyTopic
///   {v, n, pA, reply, ts}  ── T ───────────────────────►  SPAKE2 with its code
///                                                         SUBSCRIBE confirmTopic
///   ◄──────────────────────────────  {pB, cB} ── reply ──
///   check cB ── wrong: ignore, go on listening
///   SUBSCRIBE payloadTopic
///   seal{cA, name} ─ confirmTopic ─────────────────────►  check cA
///                                                         ask a person
///   ◄────────────── seal{offer} or seal{declined} ─ payloadTopic
/// ```
///
/// Each side subscribes before it provokes a reply, because a relay keeps
/// nothing for a subscriber that was late.
///
/// ## What it trusts
///
/// The topic is shared with thousands of other sessions and the mailbox is
/// public, so any number of unrelated senders — and anyone who wants to — may
/// answer. A reply is only believed when its confirmation verifies under the
/// code typed here; the rest are dropped without a word and the search goes
/// on. Until one verifies, the sender has been given a curve point and
/// nothing else: not the code, not this device's name. The name travels only
/// inside a message sealed under a key that only a holder of the code can
/// derive.
class InternetCodeSearch {
  InternetCodeSearch({
    CodeMailbox Function()? mailbox,
    this.timings = const InternetCodeTimings(),
    this.pake = const InternetCodePake(),
    Random? random,
    DateTime Function()? now,
  })  : _mailbox = mailbox ?? buildCodeMailbox,
        _random = random,
        _now = now ?? DateTime.now;

  final CodeMailbox Function() _mailbox;
  final InternetCodeTimings timings;
  final InternetCodePake pake;
  final Random? _random;
  final DateTime Function() _now;

  /// Runs the search for [code]. Never throws. Everything it opened —
  /// subscriptions, timers, the mailbox — is released before it returns,
  /// whichever way it ends, including by [gate] stopping.
  Future<CodeSessionOutcome> run(
    SessionCode code, {
    required String deviceName,
    required SearchGate gate,
    void Function(Future<void> Function())? onOfferCancellation,
  }) async {
    CodeMailbox? mailbox;
    StreamSubscription<MailboxMessage>? listening;
    final timers = <Timer>[];
    try {
      mailbox = _mailbox();
      return await _run(code, deviceName, gate, mailbox, (s) => listening = s,
          timers, onOfferCancellation);
    } on _Stopped {
      return const CodeSessionNotFound();
    } on MailboxUnavailable catch (e) {
      AppLogger.warning('Internet code search: no channel reachable: ${e.detail}',
          tag: 'INET_CODE');
      return const CodeSessionNoNetwork();
    } on NoRendezvousChannelConfigured catch (e) {
      AppLogger.warning('Internet code search: $e', tag: 'INET_CODE');
      return const CodeSessionNoNetwork();
    } catch (e) {
      AppLogger.warning(
          'Internet code search failed: ${e.runtimeType}', tag: 'INET_CODE');
      return const CodeSessionNotFound();
    } finally {
      for (final timer in timers) {
        timer.cancel();
      }
      // Not awaited: a broadcast subscription is cancelled by the time
      // `cancel` returns, and its future only adds a turn of the event loop.
      unawaited(listening?.cancel());
      try {
        await mailbox?.close();
      } catch (_) {}
    }
  }

  Future<CodeSessionOutcome> _run(
    SessionCode code,
    String deviceName,
    SearchGate gate,
    CodeMailbox mailbox,
    void Function(StreamSubscription<MailboxMessage>) keep,
    List<Timer> timers,
    void Function(Future<void> Function())? onOfferCancellation,
  ) async {
    final n = InternetCode.randomBytes(InternetCode.nonceLength, _random);
    final replyTopic = InternetCode.newReplyTopic(_random);
    final begun = await _race(pake.begin(code), gate);

    final verified = Completer<_Proof>();
    final done = Completer<CodeSessionOutcome>();
    var otherVersion = false;
    var checked = 0;
    InternetCodeKeys? keys;

    Future<void> onReply(Uint8List raw) async {
      final reply = CodeReply.tryParse(raw);
      if (reply == null) {
        if (CodeReply.isOtherVersion(raw)) otherVersion = true;
        return;
      }
      if (verified.isCompleted || checked >= timings.maxRepliesChecked) return;
      checked++;
      final Spake2Keys derived;
      try {
        derived = await pake.complete(begun, n: n, senderShare: reply.pB);
      } on Spake2Exception {
        return;
      }
      // Somebody else's sender, a wrong code, or a forgery: all the same to
      // us, and none worth a word.
      if (!derived.verifies(Spake2Role.b, reply.cB)) return;
      if (!verified.isCompleted) verified.complete(_Proof(derived));
    }

    Future<void> onPayload(Uint8List raw) async {
      final current = keys;
      if (current == null || done.isCompleted) return;
      if (raw.length > InternetCode.maxPayloadBytes) return;
      final clear = await InternetCodeSeal.open(
        key: current.aeadKey,
        role: SealRole.payload,
        n: n,
        envelope: raw,
      );
      // Altered, or sealed for someone else: ignored, and the real one may
      // still come.
      if (clear == null || done.isCompleted) return;
      final outcome = _readPayload(clear);
      if (outcome != null && !done.isCompleted) done.complete(outcome);
    }

    keep(mailbox.messages.listen((m) {
      try {
        if (m.topic == replyTopic) {
          unawaited(onReply(m.payload).catchError((Object _) {}));
        } else if (keys != null && m.topic == keys.payloadTopic) {
          unawaited(onPayload(m.payload).catchError((Object _) {}));
        }
      } catch (_) {
        // A message the search cannot read is somebody else's.
      }
    }, onError: (Object _) {}));

    // Listening for the reply before asking for one.
    await _race(mailbox.subscribe(replyTopic), gate);
    final request = CodeRequest(
      n: n,
      pA: begun.share,
      reply: replyTopic,
      ts: _now().millisecondsSinceEpoch ~/ 1000,
    );
    await _race(
        mailbox.publish(InternetCode.requestTopic(code), request.encode()),
        gate);

    final _Proof proof;
    try {
      proof = await _race(
          _within(verified.future, timings.findTimeout, timers), gate);
    } on TimeoutException {
      return otherVersion
          ? const CodeSessionUpdateRequired()
          : const CodeSessionNotFound();
    }

    // The code is proved. Only the first search to get here may go on and say
    // who this device is.
    if (!gate.tryClaim()) throw const _Stopped();
    gate.awaitingApproval();

    final sessionKeys = InternetCodeKeys.derive(proof.keys.ke, n);
    keys = sessionKeys;
    // Listening for the answer before the confirmation that provokes it.
    await _race(mailbox.subscribe(sessionKeys.payloadTopic), gate);
    final confirmation = await InternetCodeSeal.seal(
      key: sessionKeys.aeadKey,
      role: SealRole.confirm,
      n: n,
      plaintext: utf8.encode(jsonEncode({
        'cA': InternetCode.encode(proof.keys.confirmationA),
        'name': InternetCode.cleanName(deviceName),
      })),
      random: _random,
    );
    var finished = false;
    try {
      await _race(mailbox.publish(sessionKeys.confirmTopic, confirmation), gate);
      AppLogger.info('Internet code search: sender proved the code; waiting for '
          'its person', tag: 'INET_CODE');
      final outcome = await _race(
          _within(done.future, timings.approvalWait, timers), gate);
      if (outcome is CodeSessionFoundOnline) {
        onOfferCancellation?.call(() async {
          CodeMailbox? fresh;
          try {
            fresh = _mailbox();
            await _sendCancellation(fresh, sessionKeys, n);
          } catch (_) {
            // The cancellation is best effort, including mailbox creation.
          } finally {
            try {
              await fresh?.close().timeout(const Duration(seconds: 1));
            } catch (_) {}
          }
        });
      }
      finished = true;
      return outcome;
    } on TimeoutException {
      // It proved itself and then went quiet: not a wrong code.
      return const CodeSessionUnreachable();
    } finally {
      if (!finished) {
        // Best effort and bounded: the sender may be an older version, or the
        // mailbox may have gone away. The per-run key and AAD bind this to
        // exactly this exchange and keep confirmation replays distinct.
        await _sendCancellation(mailbox, sessionKeys, n);
      }
    }
  }

  Future<void> _sendCancellation(
      CodeMailbox mailbox, InternetCodeKeys keys, Uint8List n) async {
    try {
      final cancel = await InternetCodeSeal.seal(
        key: keys.aeadKey,
        role: SealRole.cancel,
        n: n,
        plaintext: utf8.encode('cancel'),
        random: _random,
      ).timeout(const Duration(seconds: 1));
      await mailbox.publish(keys.confirmTopic, cancel)
          .timeout(const Duration(seconds: 1));
    } catch (_) {}
  }

  /// The outcome a sealed payload says, or null when it says nothing this
  /// search understands.
  CodeSessionOutcome? _readPayload(Uint8List clear) {
    try {
      final json = jsonDecode(utf8.decode(clear));
      if (json is! Map<String, dynamic>) return null;
      switch (json['k']) {
        case 'declined':
          return const CodeSessionDeclined();
        case 'offer':
          final qs = json['qs'];
          if (qs is! String ||
              qs.isEmpty ||
              qs.length > InternetCode.maxOfferChars ||
              !ServerlessQr.looksLikeOne(qs)) {
            return null;
          }
          return CodeSessionFoundOnline(qs);
      }
    } catch (_) {}
    return null;
  }

  /// [step], or a [TimeoutException] after [limit]. The timer is kept so that
  /// the search can cancel it, instead of leaving it to run out after the
  /// answer is in.
  Future<T> _within<T>(Future<T> step, Duration limit, List<Timer> timers) {
    final result = Completer<T>();
    final timer = Timer(limit, () {
      if (!result.isCompleted) {
        result.completeError(TimeoutException('no answer', limit));
      }
    });
    timers.add(timer);
    step.then<void>((value) {
      timer.cancel();
      if (!result.isCompleted) result.complete(value);
    }, onError: (Object error, StackTrace stack) {
      timer.cancel();
      if (!result.isCompleted) result.completeError(error, stack);
    });
    return result.future;
  }

  /// Waits for [step], or ends the search if the gate stops first.
  Future<T> _race<T>(Future<T> step, SearchGate gate) {
    if (gate.isStopped) {
      unawaited(step.then<void>((_) {}, onError: (Object _) {}));
      return Future<T>.error(const _Stopped());
    }
    return Future.any<T>([
      step,
      gate.stopped.then<T>((_) => throw const _Stopped()),
    ]);
  }
}

class _Proof {
  const _Proof(this.keys);
  final Spake2Keys keys;
}

class _Stopped implements Exception {
  const _Stopped();
}

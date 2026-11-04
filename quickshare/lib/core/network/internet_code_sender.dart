import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/internet_code.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// The sender's half of finding it by an internet code: listens on the
/// request topic for as long as one offer's code is on screen, proves that
/// code to whoever asks, and — only after a person here has said yes — hands
/// that receiver the offer.
///
/// ## What it will and will not do
///
/// Every request is hostile until it has proved the code. The public mailbox
/// can show this end anything, so before a byte of it is parsed the size is
/// checked; before any curve arithmetic the age, the nonce and the budget are;
/// and nothing is sent to a receiver that has not shown, inside an
/// authenticated message, that it holds the code. The budget is the defence of
/// a 33-bit secret: one run is one guess for whoever asked, so one code pays
/// for [InternetCodeTimings.maxAttemptsPerCode] of them, at most one a second,
/// and then goes quiet until it is replaced. A wrong confirmation buys the
/// asker nothing back.
///
/// ## What it holds
///
/// A person is never asked a question that changes underneath them: while a
/// dialog is open, and from consent until the answer arrives or
/// [InternetCodeTimings.payloadHold] passes, the owner is told to hold the
/// rotation of the code ([hold]/[release]). When the hold expires without an
/// answer it is let go and the transfer is not counted as having started.
///
/// One instance serves one code. Rotating means [stop] and a new instance —
/// which is also what resets the budget.
class InternetCodeSender {
  InternetCodeSender({
    required this.mailbox,
    required this.code,
    required this.offer,
    required this.approve,
    this.hold,
    this.release,
    this.timings = const InternetCodeTimings(),
    this.pake = const InternetCodePake(),
    DateTime Function()? now,
    Random? random,
  })  : _now = now ?? DateTime.now,
        _random = random,
        requestTopic = InternetCode.requestTopic(code);

  final CodeMailbox mailbox;
  final SessionCode code;

  /// The offer string a receiver is handed once approved: exactly what the QR
  /// on screen holds. Null when there is none.
  final Future<String?> Function() offer;

  /// Asks a person whether [deviceName] may have the files. [deviceName] is
  /// text a stranger typed into a public mailbox, cleaned and shortened; it is
  /// to be shown as data and nothing else.
  final Future<bool> Function(String deviceName) approve;

  /// Keeps the code from being replaced for [reason], until [release]d.
  final void Function(Object reason)? hold;
  final void Function(Object reason)? release;

  final InternetCodeTimings timings;
  final InternetCodePake pake;
  final DateTime Function() _now;
  final Random? _random;

  /// Where requests for [code] arrive. Shared with every other code whose
  /// twelve bits agree.
  final String requestTopic;

  /// The reasons the code is held for, as the owner's schedule sees them.
  static const String dialogHold = 'internet-code:dialog';
  static const String payloadHoldReason = 'internet-code:payload';

  // Remembered nonces are bounded: the budget already caps what a code can
  // pay for, and this only has to outlast the two minutes a request is
  // accepted for.
  static const int _nonceMemory = 256;

  final _seenNonces = <String>{};
  final _exchanges = <String, _Exchange>{};
  // Cancelled in [stop].
  // ignore: cancel_subscriptions
  StreamSubscription<MailboxMessage>? _listening;
  Timer? _payloadTimer;
  DateTime? _lastRun;
  int _attempts = 0;
  bool _budgetReported = false;
  bool _stopped = false;
  bool _started = false;

  /// A dialog is open, or an offer was handed over and its answer is awaited.
  /// One per code.
  bool _busy = false;
  bool _dialogHeld = false;
  bool _payloadHeld = false;

  /// How many requests this code has paid for.
  int get attempts => _attempts;

  /// The code has used its whole budget and answers nobody.
  bool get exhausted => _attempts >= timings.maxAttemptsPerCode;

  bool get isStopped => _stopped;

  /// Starts listening. Throws [MailboxUnavailable] when no channel could be
  /// reached; the sender is then stopped and has to be built again.
  Future<void> start() async {
    if (_started || _stopped) return;
    _started = true;
    // Listening before subscribing, so that nothing delivered in between is
    // lost.
    _listening = mailbox.messages.listen(_onMessage, onError: (Object _) {});
    try {
      await mailbox.subscribe(requestTopic);
    } catch (_) {
      await stop();
      rethrow;
    }
    AppLogger.info('Internet code: listening for requests', tag: 'INET_CODE');
  }

  /// The sealed answer to the offer arrived: the hand-over worked, and whoever
  /// holds the rotation from here is the transfer, not this.
  void answered() {
    _payloadTimer?.cancel();
    _payloadTimer = null;
    _letGo(payload: true);
    _busy = false;
  }

  /// Stops listening and drops everything pending. A question already put to
  /// the person is left for its owner to withdraw; its answer is ignored.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _payloadTimer?.cancel();
    _payloadTimer = null;
    for (final exchange in _exchanges.values.toList()) {
      exchange.close();
    }
    _exchanges.clear();
    _letGo(dialog: true, payload: true);
    final listening = _listening;
    _listening = null;
    // Not awaited: see InternetCodeSearch.run.
    unawaited(listening?.cancel());
    try {
      await mailbox.close();
    } catch (_) {}
  }

  // ─── Requests ──────────────────────────────────────────────────────────

  void _onMessage(MailboxMessage message) {
    if (_stopped) return;
    try {
      if (message.topic == requestTopic) {
        unawaited(_onRequest(message.payload).catchError((Object e) {
          AppLogger.warning('Internet code: a request failed: ${e.runtimeType}',
              tag: 'INET_CODE');
        }));
        return;
      }
      final exchange = _exchanges[message.topic];
      if (exchange != null) {
        unawaited(_onConfirmation(exchange, message.payload).catchError(
            (Object e) {
          AppLogger.warning(
              'Internet code: a confirmation failed: ${e.runtimeType}',
              tag: 'INET_CODE');
        }));
      }
    } catch (e) {
      // Whatever arrived, the listener goes on.
      AppLogger.warning('Internet code: a message was discarded: ${e.runtimeType}',
          tag: 'INET_CODE');
    }
  }

  Future<void> _onRequest(Uint8List raw) async {
    // Size and shape first, before anything is computed.
    final request = CodeRequest.tryParse(raw);
    if (request == null) return;
    // A reply sent to the topic requests arrive on is a reply nobody reads; it
    // is somebody trying to make this end talk to itself.
    if (request.reply == requestTopic) return;

    final now = _now();
    final age = now
        .difference(DateTime.fromMillisecondsSinceEpoch(request.ts * 1000,
            isUtc: true))
        .abs();
    if (age > timings.requestMaxAge) return;

    // A repeated nonce is a replay — or the Worker handing back the value it
    // keeps for half an hour. Either way it is not asked again.
    final nonceKey = InternetCode.encode(request.n);
    if (!_seenNonces.add(nonceKey)) return;
    if (_seenNonces.length > _nonceMemory) {
      _seenNonces.remove(_seenNonces.first);
    }

    if (exhausted) {
      if (!_budgetReported) {
        _budgetReported = true;
        AppLogger.warning(
            'Internet code: this code has used its $_attempts attempts; it '
            'answers nobody until it is replaced',
            tag: 'INET_CODE');
      }
      return;
    }
    final last = _lastRun;
    if (last != null) {
      final gap = now.difference(last);
      if (!gap.isNegative && gap < timings.minRequestGap) return;
    }
    if (_exchanges.length >= timings.maxPendingExchanges) return;

    // Paid for from here, whatever comes of it.
    _attempts++;
    _lastRun = now;

    final PakeReply reply;
    try {
      reply = await pake.respond(code,
          n: request.n, receiverShare: request.pA);
    } on Spake2Exception {
      // Not a point of the group: nobody honest sends one.
      return;
    }
    if (_stopped) return;

    final keys = InternetCodeKeys.derive(reply.keys.ke, request.n);
    final exchange = _Exchange(
      n: request.n,
      keys: keys,
      reply: reply,
      confirmTopic: keys.confirmTopic,
    );
    _exchanges[keys.confirmTopic] = exchange;
    exchange.timer = Timer(timings.confirmWait, () {
      if (!exchange.confirmed) _drop(exchange);
    });

    try {
      // Listening for the confirmation before the reply that provokes it.
      await mailbox.subscribe(keys.confirmTopic);
      if (_stopped || exchange.closed) return;
      await mailbox.publish(
        request.reply,
        CodeReply(pB: reply.share, cB: reply.keys.confirmationB).encode(),
      );
    } catch (e) {
      AppLogger.warning('Internet code: could not answer a request: '
          '${e.runtimeType}', tag: 'INET_CODE');
      _drop(exchange);
    }
  }

  // ─── Confirmation, the question, the hand-over ─────────────────────────

  Future<void> _onConfirmation(_Exchange exchange, Uint8List raw) async {
    if (exchange.closed || exchange.confirmed) return;
    if (raw.length > InternetCode.maxConfirmBytes) return;

    final clear = await InternetCodeSeal.open(
      key: exchange.keys.aeadKey,
      role: SealRole.confirm,
      n: exchange.n,
      envelope: raw,
    );
    // Not sealed under this run's key: not from the receiver it was meant for.
    // Ignored rather than fatal — anyone on the path can inject, and the real
    // message may still be on its way.
    if (clear == null || exchange.closed || exchange.confirmed) return;

    final parsed = _parseConfirmation(clear);
    if (parsed == null ||
        !exchange.reply.keys.verifies(Spake2Role.a, parsed.cA)) {
      // Sealed with the right key and proving nothing: the exchange is over.
      // The attempt it cost stays spent.
      AppLogger.info('Internet code: a confirmation did not verify',
          tag: 'INET_CODE');
      _drop(exchange);
      return;
    }

    exchange.confirmed = true;
    exchange.timer?.cancel();
    _exchanges.remove(exchange.confirmTopic);
    unawaited(mailbox.unsubscribe(exchange.confirmTopic).catchError((_) {}));

    await _ask(exchange, InternetCode.cleanName(parsed.name));
  }

  ({Uint8List cA, String name})? _parseConfirmation(Uint8List clear) {
    try {
      final json = jsonDecode(utf8.decode(clear));
      if (json is! Map<String, dynamic>) return null;
      final cA = CodePake.decode(json['cA'], length: CodePake.tagLength);
      final name = json['name'];
      if (cA == null ||
          name is! String ||
          name.length > InternetCode.maxRawNameChars) {
        return null;
      }
      return (cA: cA, name: name);
    } catch (_) {
      return null;
    }
  }

  /// The one question a person is asked: may this device have the files?
  Future<void> _ask(_Exchange exchange, String deviceName) async {
    if (_stopped) return;
    if (_busy) {
      // One question per code. The second asker is told no rather than left
      // waiting for an answer that is not coming.
      await _refuse(exchange);
      return;
    }
    _busy = true;
    _holdFor(dialog: true);

    var approved = false;
    try {
      approved = await approve(deviceName)
          .timeout(timings.dialogTimeout, onTimeout: () => false);
    } catch (_) {
      approved = false;
    }
    if (_stopped) return;

    if (!approved) {
      _busy = false;
      await _refuse(exchange);
      _letGo(dialog: true);
      return;
    }

    String? offerString;
    try {
      offerString = await offer();
    } catch (_) {
      offerString = null;
    }
    if (_stopped) return;
    if (offerString == null ||
        offerString.isEmpty ||
        offerString.length > InternetCode.maxOfferChars) {
      _busy = false;
      await _refuse(exchange);
      _letGo(dialog: true);
      return;
    }

    try {
      await mailbox.publish(
        exchange.keys.payloadTopic,
        await InternetCodeSeal.seal(
          key: exchange.keys.aeadKey,
          role: SealRole.payload,
          n: exchange.n,
          plaintext:
              utf8.encode(jsonEncode({'k': 'offer', 'qs': offerString})),
          random: _random,
        ),
      );
    } catch (e) {
      AppLogger.warning('Internet code: could not hand the offer over: '
          '${e.runtimeType}', tag: 'INET_CODE');
      _busy = false;
      _letGo(dialog: true);
      return;
    }
    if (_stopped) return;

    // The new hold before the old one is let go: with none held in between,
    // a deadline that passed meanwhile would fire into the gap.
    _holdFor(payload: true);
    _letGo(dialog: true);
    _payloadTimer = Timer(timings.payloadHold, () {
      _payloadTimer = null;
      AppLogger.info(
          'Internet code: the hand-over was not answered in '
          '${timings.payloadHold.inSeconds}s; the offer may be replaced again',
          tag: 'INET_CODE');
      _letGo(payload: true);
      _busy = false;
    });
  }

  Future<void> _refuse(_Exchange exchange) async {
    try {
      await mailbox.publish(
        exchange.keys.payloadTopic,
        await InternetCodeSeal.seal(
          key: exchange.keys.aeadKey,
          role: SealRole.payload,
          n: exchange.n,
          plaintext: utf8.encode(jsonEncode({'k': 'declined'})),
          random: _random,
        ),
      );
    } catch (_) {
      // The receiver gives up on its own clock.
    }
  }

  // ─── Bookkeeping ───────────────────────────────────────────────────────

  void _drop(_Exchange exchange) {
    exchange.close();
    _exchanges.remove(exchange.confirmTopic);
    if (!_stopped) {
      unawaited(mailbox.unsubscribe(exchange.confirmTopic).catchError((_) {}));
    }
  }

  void _holdFor({bool dialog = false, bool payload = false}) {
    if (dialog && !_dialogHeld) {
      _dialogHeld = true;
      hold?.call(dialogHold);
    }
    if (payload && !_payloadHeld) {
      _payloadHeld = true;
      hold?.call(payloadHoldReason);
    }
  }

  void _letGo({bool dialog = false, bool payload = false}) {
    if (dialog && _dialogHeld) {
      _dialogHeld = false;
      release?.call(dialogHold);
    }
    if (payload && _payloadHeld) {
      _payloadHeld = false;
      release?.call(payloadHoldReason);
    }
  }
}

/// One receiver's run, from the sender's reply to its confirmation.
class _Exchange {
  _Exchange({
    required this.n,
    required this.keys,
    required this.reply,
    required this.confirmTopic,
  });

  final Uint8List n;
  final InternetCodeKeys keys;
  final PakeReply reply;
  final String confirmTopic;
  Timer? timer;
  bool confirmed = false;
  bool closed = false;

  void close() {
    closed = true;
    timer?.cancel();
    timer = null;
  }
}

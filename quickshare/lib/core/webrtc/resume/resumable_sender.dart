import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/resume/item_digest.dart';
import 'package:quickshare/core/webrtc/resume/cancellation_notifier.dart';
import 'package:quickshare/core/webrtc/resume/reconnect_policy.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';

/// The link is dead: the channel closed, ICE gave up, or nothing moved for
/// longer than the stall policy allows. Not a failure of the transfer, but the
/// reason to get another link.
class LinkLost implements Exception {
  const LinkLost(this.reason);

  final String reason;

  @override
  String toString() => 'the link was lost: $reason';
}

/// One open, ordered and reliable pipe to the receiver: a data channel, in
/// practice, and in a test whatever stands in for one.
///
/// The engine knows nothing else about the network. Everything that makes a
/// link a link — the peer connection, ICE, the stall timer on the send buffer
/// — lives behind this, so that the part of the transfer that has to be right
/// after a drop (where to continue from, what to check at the end) can be run
/// against a pipe that is cut on purpose.
abstract class SenderLink {
  /// Which link this is. The one the QR code started is 1.
  int get generation;

  bool get isOpen;

  /// Throws [LinkLost] when the link cannot take the frame.
  void sendText(String frame);
  void sendBinary(Uint8List bytes);

  /// Text frames from the receiver.
  Stream<String> get incoming;

  /// Completes when no more than [limit] bytes are waiting to leave. Throws
  /// [LinkLost] when the link closes, or when nothing leaves for
  /// [stallTimeout].
  Future<void> waitForRoom(int limit, {required Duration stallTimeout});

  /// Completes, with a reason fit for the log, when the link is known to be
  /// dead: its channel closed, or ICE gave up. Never completes for a link that
  /// is merely silent; that is for the stall timers to find out.
  Future<String> get closed;

  /// Closes the link without a word to the far end.
  Future<void> close();
}

/// Brings up a replacement link, numbered [generation]: a new connection
/// negotiated through the same authenticated channel as the first. Throws
/// when it does not come up within [timeout].
typedef SenderReconnector = Future<SenderLink> Function(
    int generation, int attempt, Duration timeout);

/// A file the engine sends, with the item the receiver is told about.
class SendItem {
  const SendItem(this.item, this.path);

  final TransferItem item;
  final String path;
}

enum SenderPhase { sending, reconnecting }

/// The transfer ended, and why. [code] is a [FailureCode] the screen can say
/// in the person's language.
class SendFailure implements Exception {
  const SendFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'SendFailure($code): $message';
}

/// The person on this end stopped the transfer.
class SendCancelled implements Exception {
  const SendCancelled();
}

class _Position {
  const _Position(this.index, this.offset);
  final int index;
  final int offset;
}

class _Hello {
  _Hello(this.version, this.generation, this.sessionId, this.next, this.offset);
  final int version;
  final int generation;
  final String? sessionId;
  final int next;
  final int offset;
}

/// Sends a session over a link that may die, and carries on over the next one.
///
/// ## What survives a drop
///
/// Nothing on the wire does, so the position is kept where it can be trusted:
/// by the receiver, in what it has written to disk. Every link begins with the
/// receiver's `hello`, which says how many items it holds whole and how far it
/// got into the next. The sender throws away whatever it thought it had sent
/// past that, reads the file again from there and goes on. A frame that was in
/// flight when the link died is simply sent again; a byte can be sent twice,
/// but it can only be *written* once.
///
/// ## What proves the file is whole
///
/// A size is not enough, least of all across a splice. Every item ends with a
/// SHA-256 of the *whole* file, computed here over what is read (and, after a
/// resume, over the part the receiver already had, read again first), and the
/// receiver compares it with its own over what it wrote. The transfer is
/// reported complete only when the receiver says `done`, which it does after
/// every item has passed that check. A link that dies between the last byte and
/// that word does not turn the end into a guess: the sender reconnects, the
/// receiver's `hello` says it has everything, and the sender asks again.
///
/// ## Old receivers
///
/// A receiver that predates this protocol never speaks first. After
/// [StallPolicy.legacyHelloWait] the engine takes it for one and sends the old
/// way: no resume, and the end is the drained buffer. If the link then dies
/// there is nothing to resume, and the failure says so (see
/// [FailureCode.connectionLostPeerTooOld]) instead of a vague "failed".
class ResumableSender {
  ResumableSender({
    required this.items,
    required SenderLink firstLink,
    required this.reconnect,
    required this.sendWindow,
    this.chunkSize = 65536,
    this.stall = const StallPolicy(),
    this.policy = const ReconnectPolicy(),
    this.onProgress,
    this.onPhase,
    this.onLinkChanged,
    this.sessionId,
    this.forceInlineDigest = false,
    this.pace,
    DateTime Function()? now,
    this.tag = 'RESUME_SENDER',
  })  : _link = firstLink,
        _ledger = ReconnectLedger(policy, now: now),
        _sid = sessionId ?? _newSessionId(),
        _total = items.fold<int>(0, (sum, i) => sum + i.item.size) {
    var running = 0;
    for (final i in items) {
      _before.add(running);
      running += i.item.size;
    }
  }

  final List<SendItem> items;
  final SenderReconnector reconnect;

  /// How many bytes may wait in the link's buffer before the loop pauses.
  final int sendWindow;
  final int chunkSize;
  final StallPolicy stall;
  final ReconnectPolicy policy;

  /// Fraction of the session sent, never decreasing.
  final void Function(double fraction)? onProgress;
  final void Function(SenderPhase phase)? onPhase;

  /// A new link took over; the transport re-points its own bookkeeping.
  final void Function(SenderLink link)? onLinkChanged;

  /// Fixed in tests; random otherwise.
  final String? sessionId;
  final bool forceInlineDigest;

  /// Debug builds only: called after each chunk, to hold the loop back.
  final Future<void> Function(int sessionBytesSent)? pace;
  final String tag;

  final ReconnectLedger _ledger;
  final String _sid;
  final int _total;
  final List<int> _before = [];

  SenderLink _link;
  StreamSubscription<String>? _incoming;
  Timer? _ping;
  DateTime _lastSent = DateTime.now();
  DateTime _lastHeard = DateTime.now();

  bool _receiverSpeaksV2 = false;
  Completer<_Hello>? _helloWaiter;
  _Hello? _lastHello;
  Completer<void>? _doneWaiter;
  bool _doneOk = false;
  String? _doneCode;
  bool _cancelled = false;
  bool _finished = false;
  double _progressHigh = 0;
  int _sessionSent = 0;
  int _generation = 1;

  /// How many links the session used, the first included.
  int get linksUsed => _generation;

  /// Whether the receiver announced itself as one that can resume.
  bool get receiverSpeaksV2 => _receiverSpeaksV2;

  /// How many times the connection was lost and a new one tried for.
  int get interruptions => _ledger.interruptions;

  static String _newSessionId() {
    final bytes = Uint8List(16);
    final random = Random.secure();
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return hex(bytes);
  }

  static String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<void>? _cancelOperation;

  /// Stops producing bytes immediately, then lets the stop frame reach the peer.
  Future<void> cancel() {
    if (_finished || _peerCancelled) return Future<void>.value();
    return _cancelOperation ??= _cancelAndNotify();
  }

  Future<void> _cancelAndNotify() async {
    _cancelled = true;
    _wake();
    final link = _link;
    try {
      if (!link.isOpen) return;
      if (link is CancellationNotifier) {
        await (link as CancellationNotifier).notifyCancellation();
      } else {
        link.sendText(TransferProtocol.buildCancelled());
        await link
            .waitForRoom(0, stallTimeout: const Duration(seconds: 8))
            .timeout(const Duration(seconds: 8));
      }
    } catch (_) {
      // A vanished peer must never prevent local cancellation.
    }
  }

  void _wake() {
    final hello = _helloWaiter;
    if (hello != null && !hello.isCompleted) {
      hello.completeError(const SendCancelled());
    }
    final done = _doneWaiter;
    if (done != null && !done.isCompleted) {
      done.completeError(const SendCancelled());
    }
  }

  Future<void> run() async {
    _attach(_link);
    _ping = Timer.periodic(stall.pingEvery, (_) => _maybePing());
    try {
      await _awaitFirstHello();
      var position = const _Position(0, 0);
      var manifestSent = false;
      while (true) {
        _check();
        try {
          if (!manifestSent) {
            await _sendManifest();
            manifestSent = true;
          }
          await _sendFrom(position);
          await _finish();
          _finished = true;
          return;
        } on LinkLost catch (e) {
          _check();
          AppLogger.warning('Sender: $e', tag: tag);
          final resumed = await _recover(e);
          if (resumed == null) {
            // The receiver's `done` had already arrived: that is the end.
            _finished = true;
            _progressHigh = 1;
            onProgress?.call(1.0);
            return;
          }
          position = resumed.position;
          manifestSent = !resumed.resendManifest;
        }
      }
    } finally {
      _ping?.cancel();
      _ping = null;
      await _incoming?.cancel();
      _incoming = null;
    }
  }

  void _check() {
    if (_cancelled) throw const SendCancelled();
    if (_peerCancelled) {
      throw const SendFailure(FailureCode.cancelledByReceiver,
          'the receiver cancelled the transfer');
    }
  }

  // ─── Frames from the receiver ──────────────────────────────────────────

  void _attach(SenderLink link) {
    _incoming?.cancel();
    _link = link;
    _lastHeard = DateTime.now();
    _incoming = link.incoming.listen(_onFrame, onError: (Object _) {});
    onLinkChanged?.call(link);
  }

  void _onFrame(String text) {
    _lastHeard = DateTime.now();
    final Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (json is! Map<String, dynamic>) return;
    switch (json['type']) {
      case TransferProtocol.hello:
        final hello = _parseHello(json);
        if (hello == null ||
            hello.version < 2 ||
            hello.generation != _link.generation) {
          return;
        }
        // The receiver announced itself: from here on it can be resumed, even
        // if the first word was slower than the wait for it.
        if (hello.version >= 2) _receiverSpeaksV2 = true;
        _lastHello = hello;
        final waiter = _helloWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete(hello);
      case TransferProtocol.done:
        _doneOk = json['ok'] == true;
        _doneCode = json['code'] as String?;
        final waiter = _doneWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
        _gotDone = true;
      case TransferProtocol.cancelled:
        _peerCancelled = true;
        final waiter = _doneWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
        final hello = _helloWaiter;
        if (hello != null && !hello.isCompleted) {
          hello.completeError(const SendFailure(FailureCode.cancelledByReceiver,
              'the receiver cancelled the transfer'));
        }
      default:
        // `ping` and anything later builds add: only the arrival counts.
        break;
    }
  }

  bool _gotDone = false;
  bool _peerCancelled = false;

  _Hello? _parseHello(Map<String, dynamic> json) {
    final v = json['v'];
    final gen = json['gen'];
    final next = json['next'];
    final offset = json['offset'];
    if (v is! int) return null;
    return _Hello(
      v,
      gen is int ? gen : 0,
      json['sid'] is String ? json['sid'] as String : null,
      next is int && next >= 0 ? next : 0,
      offset is int && offset >= 0 ? offset : 0,
    );
  }

  void _maybePing() {
    if (_finished || _cancelled || !_receiverSpeaksV2 || !_link.isOpen) return;
    if (DateTime.now().difference(_lastSent) < stall.pingEvery) return;
    try {
      _link.sendText(TransferProtocol.buildPing());
      _lastSent = DateTime.now();
    } catch (_) {
      // The link is going; the loop notices on its own.
    }
  }

  void _sendText(String frame) {
    try {
      _link.sendText(frame);
    } on LinkLost {
      rethrow;
    } catch (e) {
      throw LinkLost('the channel refused a frame (${e.runtimeType})');
    }
    _lastSent = DateTime.now();
  }

  void _sendBinary(Uint8List bytes) {
    try {
      _link.sendBinary(bytes);
    } on LinkLost {
      rethrow;
    } catch (e) {
      throw LinkLost('the channel refused a frame (${e.runtimeType})');
    }
    _lastSent = DateTime.now();
  }

  // ─── The first link ────────────────────────────────────────────────────

  /// Waits for the receiver to announce itself. A receiver that does not is a
  /// build from before reconnection existed.
  Future<void> _awaitFirstHello() async {
    final waiter = _helloWaiter = Completer<_Hello>();
    if (_lastHello != null) waiter.complete(_lastHello);
    try {
      await waiter.future.timeout(stall.legacyHelloWait);
    } on TimeoutException {
      AppLogger.info(
          'Sender: the receiver did not announce itself in '
          '${stall.legacyHelloWait.inSeconds}s; sending the way builds '
          'without reconnection expect',
          tag: tag);
    } finally {
      _helloWaiter = null;
    }
    if (_peerCancelled) {
      throw const SendFailure(FailureCode.cancelledByReceiver,
          'the receiver cancelled the transfer');
    }
  }

  Future<void> _sendManifest() async {
    final frames = TransferProtocol.buildManifestFrames(
      [for (final i in items) i.item],
      sessionId: _sid,
    );
    for (final frame in frames) {
      _sendText(frame);
      await _room(sendWindow);
    }
  }

  Future<void> _room(int limit) async {
    try {
      await _link.waitForRoom(limit, stallTimeout: stall.sendNoDrain);
    } on LinkLost {
      rethrow;
    } catch (e) {
      throw LinkLost('the send buffer stopped draining ($e)');
    }
    _check();
    if (_peerCancelled) {
      throw const SendFailure(FailureCode.cancelledByReceiver,
          'the receiver cancelled the transfer');
    }
  }

  // ─── The bytes ─────────────────────────────────────────────────────────

  Future<void> _sendFrom(_Position from) async {
    for (var index = from.index; index < items.length; index++) {
      final send = items[index];
      final size = send.item.size;
      final start = index == from.index ? from.offset : 0;
      _sendText(TransferProtocol.buildFileStart(index,
          offset: start > 0 ? start : null));

      final digest =
          await ItemDigest.start(size, forceInline: forceInlineDigest);
      RandomAccessFile? raf;
      try {
        if (start > 0) await digest.primeFrom(send.path, start);
        raf = await File(send.path).open();
        if (start > 0) await raf.setPosition(start);
        var sent = start;
        _sessionSent = _before[index] + sent;
        _report();
        while (sent < size) {
          _check();
          final want = size - sent < chunkSize ? size - sent : chunkSize;
          final chunk = await raf.read(want);
          if (chunk.isEmpty) {
            throw SendFailure(FailureCode.transferFailedUnexpectedly,
                '${send.path} changed while sending ($sent of $size bytes read)');
          }
          await digest.add(chunk);
          final Uint8List payload;
          if (send.item.compressed) {
            final encoded = GZipEncoder().encode(chunk)!;
            payload =
                encoded is Uint8List ? encoded : Uint8List.fromList(encoded);
          } else {
            payload = chunk;
          }
          _sendBinary(payload);
          sent += chunk.length;
          _sessionSent = _before[index] + sent;
          _ledger.moved(chunk.length);
          _report();
          await pace?.call(_sessionSent);
          await _room(sendWindow);
        }
        final sum = await digest.finish();
        _sendText(TransferProtocol.buildFileEnd(index, sha256: sum));
        await _room(sendWindow);
      } catch (_) {
        await digest.abort();
        rethrow;
      } finally {
        await raf?.close();
      }
    }
  }

  void _report() {
    if (_total <= 0) return;
    // Completion is only reported after the receiver confirms integrity.
    final fraction = (_sessionSent / _total).clamp(0.0, 0.999);
    // After a resume the position goes back to what the receiver holds, and
    // the percentage a person is looking at does not.
    if (fraction > _progressHigh) {
      _progressHigh = fraction;
      onProgress?.call(fraction);
    }
  }

  // ─── The end ───────────────────────────────────────────────────────────

  Future<void> _finish() async {
    // The last item's bytes and its `file-end` may still be in the buffer.
    await _room(0);
    _sendText(TransferProtocol.buildComplete());
    if (!_receiverSpeaksV2) {
      // The old way: the frame has to leave the device, and what the receiver
      // made of it is its own business.
      try {
        await _link.waitForRoom(0, stallTimeout: const Duration(seconds: 5));
      } on LinkLost {
        AppLogger.error(
            'Complete-frame drain went unconfirmed; finishing anyway',
            tag: tag);
      }
      _progressHigh = 1;
      onProgress?.call(1.0);
      return;
    }

    final waiter = _doneWaiter = Completer<void>();
    if (_gotDone) waiter.complete();
    final silence = Timer.periodic(const Duration(seconds: 1), (_) {
      if (waiter.isCompleted) return;
      if (DateTime.now().difference(_lastHeard) > stall.doneWait) {
        waiter.completeError(
            const LinkLost('the receiver said nothing after the last byte'));
      }
    });
    final watching = _link;
    unawaited(watching.closed.then((reason) {
      if (!waiter.isCompleted && identical(watching, _link)) {
        waiter.completeError(LinkLost(reason));
      }
    }));
    try {
      await waiter.future;
    } finally {
      silence.cancel();
      _doneWaiter = null;
    }
    _check();
    if (_peerCancelled && !_gotDone) {
      throw const SendFailure(FailureCode.cancelledByReceiver,
          'the receiver cancelled the transfer');
    }
    if (!_doneOk) {
      final code = _doneCode == 'integrity'
          ? FailureCode.receivedFilesNotIntact
          : FailureCode.transferFailedUnexpectedly;
      throw SendFailure(code,
          'the receiver reported that it could not accept the files (${_doneCode ?? 'no reason given'})');
    }
    _progressHigh = 1;
    onProgress?.call(1.0);
    try {
      _link.sendText(TransferProtocol.buildBye());
    } catch (_) {}
  }

  // ─── Getting a link back ───────────────────────────────────────────────

  /// A new link and where to continue on it, or null when the receiver had
  /// already said `done`.
  Future<({_Position position, bool resendManifest})?> _recover(
      LinkLost why) async {
    if (!_receiverSpeaksV2) {
      throw SendFailure(
          FailureCode.connectionLostPeerTooOld,
          'the connection was lost (${why.reason}) and the other device runs '
          'a version of the app that cannot resume');
    }
    // A `done` that was already on its way is the end, whatever the link did.
    if (_gotDone && _doneOk) return null;
    onPhase?.call(SenderPhase.reconnecting);
    _ledger.lost();
    try {
      await _link.close();
    } catch (_) {}

    while (true) {
      _check();
      final gaveUp = _ledger.exhausted;
      if (gaveUp != null) {
        throw SendFailure(
            FailureCode.connectionLostNotRecovered,
            'the connection was lost (${why.reason}) and could not be '
            'restored: ${gaveUp.name} (${_ledger.attemptsInARow} attempts, '
            '${_ledger.spent.inSeconds}s)');
      }
      final attempt = _ledger.startAttempt();
      final pause = policy.pauseBefore(attempt);
      if (pause > Duration.zero) await Future<void>.delayed(pause);
      _check();

      final generation = ++_generation;
      SenderLink? fresh;
      try {
        AppLogger.info(
            'Sender: reconnecting, attempt $attempt, link $generation',
            tag: tag);
        fresh = await reconnect(generation, attempt, policy.attemptTimeout);
        _attach(fresh);
        final hello = await _awaitHello(fresh);
        final position = _validate(hello);
        _sendResume(position.position, position.resendManifest);
        _ledger.recovered();
        onPhase?.call(SenderPhase.sending);
        AppLogger.info(
            'Sender: link $generation is up; continuing at item '
            '${position.position.index}, byte ${position.position.offset}',
            tag: tag);
        return position;
      } on SendFailure {
        await fresh?.close();
        rethrow;
      } on SendCancelled {
        await fresh?.close();
        rethrow;
      } catch (e) {
        AppLogger.warning(
            'Sender: attempt $attempt (link $generation) failed: $e',
            tag: tag);
        try {
          await fresh?.close();
        } catch (_) {}
      }
    }
  }

  Future<_Hello> _awaitHello(SenderLink link) async {
    final waiter = _helloWaiter = Completer<_Hello>();
    // It may have arrived before anybody asked.
    final early = _lastHello;
    if (early != null && early.generation == link.generation) {
      waiter.complete(early);
    }
    try {
      return await waiter.future.timeout(stall.helloWait,
          onTimeout: () => throw const LinkLost(
              'the receiver did not speak on the new link'));
    } finally {
      _helloWaiter = null;
    }
  }

  /// Where to continue, from what the receiver says it holds. A receiver that
  /// holds a different session, or none, starts again from the manifest.
  ({_Position position, bool resendManifest}) _validate(_Hello hello) {
    if (hello.sessionId != _sid) {
      return (position: const _Position(0, 0), resendManifest: true);
    }
    if (hello.next > items.length) {
      throw SendFailure(FailureCode.connectionLostNotRecovered,
          'the receiver claims ${hello.next} items of ${items.length}');
    }
    if (hello.next == items.length) {
      if (hello.offset != 0) {
        throw const SendFailure(FailureCode.connectionLostNotRecovered,
            'the receiver claims a partial item after the last');
      }
      return (position: _Position(items.length, 0), resendManifest: false);
    }
    final size = items[hello.next].item.size;
    if (hello.offset > size) {
      throw SendFailure(FailureCode.connectionLostNotRecovered,
          'the receiver claims ${hello.offset} bytes of an item of $size');
    }
    return (
      position: _Position(hello.next, hello.offset),
      resendManifest: false
    );
  }

  void _sendResume(_Position at, bool manifestFollows) {
    _sendText(TransferProtocol.buildResume(
      sessionId: _sid,
      generation: _generation,
      next: at.index,
      offset: at.offset,
    ));
    // The session restarts from the manifest: the progress the screen shows
    // is not rewound (see [_report]); the counters are.
    if (manifestFollows) _sessionSent = 0;
  }
}

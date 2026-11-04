import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/retry_after.dart';

/// Decides whether bytes read from the mailbox are worth passing on.
///
/// The Worker is a blind byte store and so is this channel: it cannot tell a
/// sealed answer from anything else that landed in the room. The caller can —
/// it holds the seed the answer is sealed under — and hands that knowledge in
/// here, so a payload that does not open is ignored *by the channel* instead of
/// being delivered, counted as the answer and leaving nothing to wait for.
typedef PayloadAcceptor = FutureOr<bool> Function(Uint8List payload);

/// The answer could not be put in the Worker's mailbox, and this is the last
/// word on it after every retry that was worth making.
class RendezvousPublishFailed implements Exception {
  const RendezvousPublishFailed({
    required this.attempts,
    this.statusCode,
    this.retryAfter,
    this.detail = '',
  });

  /// How many times the Worker was asked.
  final int attempts;

  /// The last HTTP status, if the Worker answered at all.
  final int? statusCode;

  /// What the last answer's `Retry-After` asked for.
  final Duration? retryAfter;

  final String detail;

  @override
  String toString() {
    final what = [
      if (statusCode != null) 'HTTP $statusCode',
      if (retryAfter != null) 'retry after ${retryAfter!.inSeconds}s',
      if (detail.isNotEmpty) detail,
    ].join(', ');
    return 'could not publish to the Worker rendezvous after $attempts '
        '${attempts == 1 ? 'attempt' : 'attempts'}'
        '${what.isEmpty ? '' : ': $what'}';
  }
}

/// Carries the sealed answer through the DirectDrop Worker's KV mailbox
/// (`/r/:roomId`, ТЗ v2.0 §4) — the reserve rendezvous channel next to
/// [NostrAnswerChannel] the RacingAnswerChannel that wraps both fans out to.
///
/// The Worker is a blind byte store: whatever [publish] sends is exactly what
/// a later [subscribe] poll receives, no envelope format imposed on top of
/// [SealedEnvelope]'s own. Unlike the Nostr relays, KV has no push mechanism a
/// client can subscribe to over plain HTTP, so "subscribing" here means
/// polling `GET /r/:roomId` until it stops 404ing or the caller closes the
/// channel.
///
/// ## When the Worker is busy
///
/// The Worker limits both routes and says so: `429 rate_limited` and
/// `503 storage_unavailable`, each with `Retry-After`. A busy Worker is not a
/// dead one, and this channel treats it that way — a 429 or 503 on the probe or
/// on any poll never disables it. It waits as long as it was told (or, with no
/// `Retry-After`, exponentially longer each time, up to [maxBackoff]), goes
/// back to [pollInterval] after the first good answer, and does the same for a
/// dropped connection. [publish] retries the same failures a few times before
/// reporting [RendezvousPublishFailed].
class WorkerAnswerChannel implements AnswerChannel {
  final String baseUrl;
  final Duration pollInterval;

  /// The longest a poll waits after a failure that named no `Retry-After`.
  final Duration maxBackoff;

  /// How many times [publish] asks before giving up.
  final int publishAttempts;

  /// The first wait between publish attempts when the Worker named none;
  /// doubled for each one after.
  final Duration publishBackoff;

  final PayloadAcceptor? _accepts;
  final Dio _dio;

  Timer? _pollTimer;
  String? _topic;
  bool _delivered = false;
  bool _closed = false;
  int _pollFailures = 0;
  int? _lastRejected;
  final _waits = <({Timer timer, Completer<bool> done})>{};
  final _controller = StreamController<Uint8List>.broadcast();

  WorkerAnswerChannel({
    required String baseUrl,
    this.pollInterval = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 60),
    this.publishAttempts = 3,
    this.publishBackoff = const Duration(seconds: 1),
    PayloadAcceptor? acceptPayload,
    Dio? dio,
  })  : baseUrl = _stripTrailingSlash(baseUrl),
        _accepts = acceptPayload,
        _dio = dio ??
            Dio(
              BaseOptions(
                // A black-holed Worker must cost seconds, not an OS-level TCP
                // timeout: the poll chain and publish both wait on each call.
                connectTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 8),
              ),
            );

  static String _stripTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  @override
  String get name => 'worker';

  @override
  Stream<Uint8List> get answers => _controller.stream;

  @override
  Future<void> subscribe(String topic) async {
    _topic = topic;
    // A reachability probe only — every caller in this codebase (see
    // RacingAnswerChannel) does `await subscribe(topic)` and attaches its
    // `answers` listener afterwards, so a delivery made from inside
    // subscribe() itself would go out on a broadcast stream nobody is
    // listening to yet and be lost for good. Real deliveries only ever
    // happen from the timer below, which by construction cannot fire until
    // the caller has had a full `pollInterval` to attach a listener.
    //
    // A Worker that is busy (429/503) has answered, so it is reachable; one
    // that cannot be reached at all throws, which is what lets the race tell
    // "no channel works" from "one channel is slow".
    final next = await _poll(probe: true);
    _scheduleNext(next);
  }

  void _scheduleNext(Duration? delay) {
    if (delay == null || _closed || _delivered) return;
    _pollTimer = Timer(delay, () async {
      final next = await _poll();
      _scheduleNext(next);
    });
  }

  /// One look at the mailbox. Returns how long to wait before the next one, or
  /// null when there is nothing left to wait for.
  Future<Duration?> _poll({bool probe = false}) async {
    if (_delivered || _closed || _topic == null) return null;

    final Response<List<int>> response;
    try {
      response = await _dio.get<List<int>>(
        '$baseUrl/r/$_topic',
        options: Options(
          responseType: ResponseType.bytes,
          // Every status is read below rather than thrown: what to do next
          // depends on which one it was.
          validateStatus: (_) => true,
        ),
      );
    } catch (e) {
      if (probe) rethrow;
      return _backoff(null, 'connection failed: $e');
    }
    if (_closed) return null;

    final status = response.statusCode;
    final retryAfter = parseRetryAfter(response.headers.value('retry-after'));
    if (status == 429 || status == 503) {
      return _backoff(retryAfter, 'HTTP $status');
    }
    if (status != 200 && status != 404) {
      if (probe) {
        throw StateError('unexpected HTTP $status from the Worker rendezvous');
      }
      return _backoff(retryAfter, 'unexpected HTTP $status');
    }

    // The Worker answered properly; whatever slowed it down is over.
    _pollFailures = 0;

    // 404 just means "not yet" — keep polling until close() or the Worker's
    // 30-minute TTL outlives the caller's patience.
    if (status == 200 && !probe && await _deliver(response.data)) return null;
    return pollInterval;
  }

  /// Passes a payload on if it is one. True when the answer has been delivered
  /// and polling is over; false for an empty or unreadable payload, which is
  /// ignored — the real answer overwrites it (the room is a bulletin board,
  /// not create-once) and is still worth waiting for.
  Future<bool> _deliver(List<int>? bytes) async {
    if (bytes == null || bytes.isEmpty) return false;
    final payload = Uint8List.fromList(bytes);

    var accepted = true;
    final accepts = _accepts;
    if (accepts != null) {
      try {
        accepted = await accepts(payload);
      } catch (_) {
        accepted = false;
      }
    }
    if (_closed) return true;

    if (!accepted) {
      final fingerprint = Object.hashAll(payload);
      if (fingerprint != _lastRejected) {
        _lastRejected = fingerprint;
        AppLogger.warning(
            'Worker rendezvous: ignoring a ${payload.length}-byte payload '
            'that is not the answer; still waiting',
            tag: 'SIGNALING');
      }
      return false;
    }

    _delivered = true;
    _pollTimer?.cancel();
    if (!_controller.isClosed) _controller.add(payload);
    return true;
  }

  /// The wait after a failed poll: what the Worker asked for, else twice as
  /// long as last time, up to [maxBackoff].
  Duration _backoff(Duration? retryAfter, String why) {
    _pollFailures++;
    final scaled = pollInterval.inMilliseconds * (1 << min(_pollFailures, 16));
    final delay = retryAfter ??
        Duration(milliseconds: min(scaled, maxBackoff.inMilliseconds));
    AppLogger.warning(
        'Worker rendezvous poll: $why; next try in ${delay.inSeconds}s '
        '(failure #$_pollFailures)',
        tag: 'SIGNALING');
    return delay;
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    int? status;
    Duration? retryAfter;
    var detail = '';
    var attempts = 0;

    while (attempts < publishAttempts) {
      if (_closed) {
        throw RendezvousPublishFailed(
            attempts: attempts,
            statusCode: status,
            retryAfter: retryAfter,
            detail: 'the channel was closed');
      }
      attempts++;

      var retryable = true;
      try {
        final response = await _dio.post<void>(
          '$baseUrl/r/$topic',
          data: payload,
          options: Options(
            contentType: 'application/octet-stream',
            validateStatus: (_) => true,
          ),
        );
        status = response.statusCode;
        if (status == 201) return;
        retryAfter = parseRetryAfter(response.headers.value('retry-after'));
        detail = '';
        // Overload is worth another try; a refusal is not (a 400 or 404 will
        // be a 400 or 404 again).
        retryable = status == 429 || status == 503;
      } catch (e) {
        status = null;
        retryAfter = null;
        detail = '$e';
      }

      if (!retryable || attempts >= publishAttempts) break;
      final wait =
          retryAfter ?? publishBackoff * (1 << min(attempts - 1, 16));
      AppLogger.warning(
          'Worker rendezvous publish attempt $attempts failed '
          '(${status == null ? detail : 'HTTP $status'}); '
          'trying again in ${wait.inSeconds}s',
          tag: 'SIGNALING');
      if (!await _sleep(wait)) {
        throw RendezvousPublishFailed(
            attempts: attempts,
            statusCode: status,
            retryAfter: retryAfter,
            detail: 'the channel was closed');
      }
    }

    throw RendezvousPublishFailed(
        attempts: attempts,
        statusCode: status,
        retryAfter: retryAfter,
        detail: detail);
  }

  /// Waits [duration]; false if the channel was closed meanwhile.
  Future<bool> _sleep(Duration duration) {
    final done = Completer<bool>();
    late final ({Timer timer, Completer<bool> done}) wait;
    final timer = Timer(duration, () {
      _waits.remove(wait);
      if (!done.isCompleted) done.complete(true);
    });
    wait = (timer: timer, done: done);
    _waits.add(wait);
    return done.future;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    for (final wait in _waits.toList()) {
      wait.timer.cancel();
      if (!wait.done.isCompleted) wait.done.complete(false);
    }
    _waits.clear();
    if (!_controller.isClosed) await _controller.close();
  }
}

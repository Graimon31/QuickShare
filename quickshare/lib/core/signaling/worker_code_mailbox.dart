import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/retry_after.dart';

/// A [CodeMailbox] on the DirectDrop Worker's rooms (`POST`/`GET /r/:topic`).
///
/// A room is one value: the last write wins and it lives for 30 minutes. That
/// is a much blunter instrument than a relay, and this class does not pretend
/// otherwise —
///
///  * KV has no push, so listening means asking. Every subscribed topic is
///    read once per [pollInterval] (five seconds, not the two the sealed
///    answer uses: this one is open for minutes at a time and the Worker's
///    quota is shared with everyone);
///  * a poll returns the same value again until something replaces it, so each
///    distinct value is delivered once and a value that comes back identical
///    is not delivered twice;
///  * two writers to one room overwrite each other, which is the price of a
///    topic that thousands of sessions share, and why the protocol on top
///    never depends on a single message arriving.
///
/// ## When the Worker is busy
///
/// It limits writes to 10 a minute per address and reads to 120, and says so
/// with `429` and `Retry-After`. A busy Worker is not a dead one: a poll that
/// is told to wait waits as long as it was told (or exponentially longer when
/// it was not), and a publish is retried only when the wait is short enough
/// to still matter to an exchange that lasts seconds.
class WorkerCodeMailbox implements CodeMailbox {
  WorkerCodeMailbox({
    required String baseUrl,
    this.pollInterval = const Duration(seconds: 5),
    this.maxBackoff = const Duration(seconds: 60),
    this.publishAttempts = 3,
    this.publishBackoff = const Duration(seconds: 1),
    this.maxPublishWait = const Duration(seconds: 10),
    Dio? dio,
  })  : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _dio = dio ??
            Dio(BaseOptions(
              // A black-holed Worker must cost seconds, not an OS-level TCP
              // timeout.
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 8),
            ));

  final String baseUrl;
  final Duration pollInterval;
  final Duration maxBackoff;
  final int publishAttempts;
  final Duration publishBackoff;

  /// The longest a publish will wait before another attempt. A `Retry-After`
  /// of a minute is the Worker saying "not in time for this exchange".
  final Duration maxPublishWait;

  /// What the Worker accepts in one room.
  static const int maxBlobBytes = 8 * 1024;
  static const int _valueMemory = 8;

  final Dio _dio;
  final _controller = StreamController<MailboxMessage>.broadcast();

  /// topic -> hashes of the values already delivered from it.
  final _topics = <String, List<String>>{};
  final _waits = <({Timer timer, Completer<bool> done})>{};
  Timer? _timer;
  bool _polling = false;
  bool _closed = false;
  int _failures = 0;

  @override
  String get name => 'worker';

  @override
  Stream<MailboxMessage> get messages => _controller.stream;

  @override
  Future<void> subscribe(String topic) async {
    if (_closed) throw const MailboxUnavailable('the mailbox is closed');
    final first = _topics.isEmpty;
    _topics.putIfAbsent(topic, () => <String>[]);
    if (first) {
      // Reachability only. A Worker that answers 429 has answered, so it is
      // up; one that cannot be reached at all is what lets the race tell "no
      // channel works" from "one channel is busy". Values are never delivered
      // from here: the caller attaches its listener to `messages` before it
      // subscribes, but nothing stored in the room should be read as an event
      // of the moment the caller subscribed.
      try {
        final status = await _probe(topic);
        if (status != 200 && status != 404 && status != 429 && status != 503) {
          throw MailboxUnavailable('unexpected HTTP $status from the Worker');
        }
      } catch (e) {
        _topics.remove(topic);
        if (e is MailboxUnavailable) rethrow;
        throw MailboxUnavailable('the Worker cannot be reached: ${e.runtimeType}');
      }
    }
    _ensurePolling();
  }

  Future<int?> _probe(String topic) async {
    final response = await _dio.get<List<int>>(
      '$baseUrl/r/$topic',
      options: Options(
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
      ),
    );
    return response.statusCode;
  }

  @override
  Future<void> unsubscribe(String topic) async {
    _topics.remove(topic);
    if (_topics.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Starts the polling loop if it is not already running. A topic added while
  /// it runs is picked up by the next round.
  void _ensurePolling() {
    if (_timer == null && !_polling) _arm(pollInterval);
  }

  void _arm(Duration delay) {
    if (_closed || _topics.isEmpty) return;
    _timer?.cancel();
    _timer = Timer(delay, _pollRound);
  }

  Future<void> _pollRound() async {
    _timer = null;
    if (_closed || _topics.isEmpty || _polling) return;
    _polling = true;
    Duration next = pollInterval;
    try {
      for (final topic in _topics.keys.toList()) {
        if (_closed || !_topics.containsKey(topic)) continue;
        final wait = await _pollOne(topic);
        if (wait != null) {
          next = wait;
          break;
        }
      }
      if (next == pollInterval) _failures = 0;
    } finally {
      _polling = false;
    }
    _arm(next);
  }

  /// One read of one room. Returns how long to wait before reading anything
  /// again when the Worker asked for it, or null when all is well.
  Future<Duration?> _pollOne(String topic) async {
    final Response<List<int>> response;
    try {
      response = await _dio.get<List<int>>(
        '$baseUrl/r/$topic',
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ),
      );
    } catch (e) {
      return _backoff(null, 'connection failed: ${e.runtimeType}');
    }
    if (_closed) return null;

    final status = response.statusCode;
    if (status == 429 || status == 503) {
      return _backoff(
          parseRetryAfter(response.headers.value('retry-after')), 'HTTP $status');
    }
    if (status == 404) return null;
    if (status != 200) {
      return _backoff(null, 'unexpected HTTP $status');
    }

    final bytes = response.data;
    if (bytes == null || bytes.isEmpty || bytes.length > maxBlobBytes) {
      return null;
    }
    final history = _topics[topic];
    if (history == null) return null;
    final fingerprint = sha256.convert(bytes).toString();
    if (history.contains(fingerprint)) return null;
    history.add(fingerprint);
    if (history.length > _valueMemory) history.removeAt(0);
    if (!_controller.isClosed) {
      _controller.add(
          MailboxMessage(topic, Uint8List.fromList(bytes), source: 'worker'));
    }
    return null;
  }

  Duration _backoff(Duration? retryAfter, String why) {
    _failures++;
    final scaled = pollInterval.inMilliseconds * (1 << min(_failures, 16));
    final delay = retryAfter ??
        Duration(milliseconds: min(scaled, maxBackoff.inMilliseconds));
    AppLogger.warning(
        'Worker mailbox poll: $why; next try in ${delay.inSeconds}s '
        '(failure #$_failures)',
        tag: 'SIGNALING');
    return delay;
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    if (_closed) throw const MailboxUnavailable('the mailbox is closed');
    if (payload.isEmpty || payload.length > maxBlobBytes) {
      throw MailboxUnavailable(
          'a ${payload.length}-byte message does not fit the Worker');
    }

    int? status;
    var detail = '';
    for (var attempt = 1; attempt <= publishAttempts; attempt++) {
      if (_closed) {
        throw const MailboxUnavailable('the mailbox was closed');
      }
      Duration? retryAfter;
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
        detail = 'HTTP $status';
        // Overload is worth another try; a refusal is not.
        retryable = status == 429 || status == 503;
      } catch (e) {
        status = null;
        detail = e.runtimeType.toString();
      }

      if (!retryable || attempt >= publishAttempts) break;
      final wait =
          retryAfter ?? publishBackoff * (1 << min(attempt - 1, 16));
      if (wait > maxPublishWait) {
        detail = '$detail (retry after ${wait.inSeconds}s is too late to help)';
        break;
      }
      AppLogger.warning(
          'Worker mailbox publish attempt $attempt failed ($detail); '
          'trying again in ${wait.inSeconds}s',
          tag: 'SIGNALING');
      if (!await _sleep(wait)) {
        throw const MailboxUnavailable('the mailbox was closed');
      }
    }
    throw MailboxUnavailable('could not publish to the Worker: $detail');
  }

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
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _topics.clear();
    for (final wait in _waits.toList()) {
      wait.timer.cancel();
      if (!wait.done.isCompleted) wait.done.complete(false);
    }
    _waits.clear();
    _dio.close(force: true);
    // Not awaited: the future of a broadcast controller whose listeners have
    // already gone is not one to wait on.
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}

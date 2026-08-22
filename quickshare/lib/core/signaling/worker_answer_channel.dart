import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/utils/app_logger.dart';

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
class WorkerAnswerChannel implements AnswerChannel {
  final String baseUrl;
  final Duration pollInterval;
  final Dio _dio;

  Timer? _pollTimer;
  String? _topic;
  bool _delivered = false;
  final _controller = StreamController<Uint8List>.broadcast();

  WorkerAnswerChannel({
    required String baseUrl,
    this.pollInterval = const Duration(seconds: 2),
    Dio? dio,
  })  : baseUrl = _stripTrailingSlash(baseUrl),
        _dio = dio ?? Dio();

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
    // happen from the periodic timer below, which by construction cannot
    // fire until the caller has had a full `pollInterval` to attach a
    // listener.
    await _poll(throwOnFailure: true, deliver: false);
    _pollTimer = Timer.periodic(pollInterval, (_) => _poll());
  }

  Future<void> _poll({bool throwOnFailure = false, bool deliver = true}) async {
    if (_delivered || _topic == null) return;
    try {
      final response = await _dio.get<List<int>>(
        '$baseUrl/r/$_topic',
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (status) => status == 200 || status == 404,
        ),
      );
      if (response.statusCode == 200 && deliver) {
        final bytes = response.data;
        if (bytes == null || bytes.isEmpty) return;
        _delivered = true;
        _pollTimer?.cancel();
        if (!_controller.isClosed) {
          _controller.add(Uint8List.fromList(bytes));
        }
      }
      // 404 just means "not yet" — keep polling until close() or the Worker's
      // 30-minute TTL outlives the caller's patience.
    } catch (e) {
      AppLogger.warning('Worker rendezvous poll failed: $e', tag: 'SIGNALING');
      if (throwOnFailure) rethrow;
    }
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    try {
      await _dio.post<void>(
        '$baseUrl/r/$topic',
        data: payload,
        options: Options(
          contentType: 'application/octet-stream',
          validateStatus: (status) => status == 201,
        ),
      );
    } catch (e) {
      throw StateError('could not publish to the Worker rendezvous: $e');
    }
  }

  @override
  Future<void> close() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_controller.isClosed) await _controller.close();
  }
}

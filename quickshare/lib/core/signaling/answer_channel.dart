import 'dart:async';
import 'dart:typed_data';

import 'package:quickshare/core/utils/app_logger.dart';

/// A one-shot drop point for the sealed SDP answer.
///
/// Both peers are behind NAT that will not accept an unsolicited packet, so
/// the answer cannot travel straight from the phone to the desktop. It goes
/// through somebody else's already-running public infrastructure instead —
/// nothing here is hosted by us, and the payload is sealed before it leaves
/// the device, so the operator of the drop point carries opaque bytes.
abstract class AnswerChannel {
  /// Short label for logs and diagnostics.
  String get name;

  /// Desktop side. Starts waiting for an answer on [topic]; completes once the
  /// channel is actually subscribed, so the caller can safely show the QR code
  /// only after somebody is listening.
  Future<void> subscribe(String topic);

  /// Phone side. One shot, no connection kept afterwards.
  Future<void> publish(String topic, Uint8List payload);

  /// Sealed payloads seen on the subscribed topic.
  Stream<Uint8List> get answers;

  Future<void> close();
}

/// Runs several independent channels at once and surfaces whichever one
/// delivers first.
///
/// Public drop points are free and unowned, which also means nobody promises
/// they are up: a single broker having a bad afternoon would otherwise mean a
/// failed transfer. Two channels with independent operators and protocols turn
/// two coin flips into one much better bet, and the cost is a few hundred bytes
/// published twice.
class RacingAnswerChannel implements AnswerChannel {
  final List<AnswerChannel> channels;

  final _controller = StreamController<Uint8List>.broadcast();
  final _subscriptions = <StreamSubscription<Uint8List>>[];
  final _seen = <String>{};

  RacingAnswerChannel(this.channels)
      : assert(channels.isNotEmpty, 'need at least one channel');

  @override
  String get name => channels.map((c) => c.name).join('+');

  @override
  Stream<Uint8List> get answers => _controller.stream;

  @override
  Future<void> subscribe(String topic) async {
    final results = await Future.wait(
      channels.map((c) async {
        try {
          await c.subscribe(topic);
          _subscriptions.add(c.answers.listen(_onPayload));
          AppLogger.info('Answer channel ready: ${c.name}', tag: 'SIGNALING');
          return true;
        } catch (e) {
          AppLogger.warning('Answer channel ${c.name} unavailable: $e',
              tag: 'SIGNALING');
          return false;
        }
      }),
    );

    if (!results.contains(true)) {
      throw StateError('no answer channel could be reached '
          '(${channels.map((c) => c.name).join(', ')})');
    }
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    final results = await Future.wait(
      channels.map((c) async {
        try {
          await c.publish(topic, payload);
          AppLogger.info('Answer published via ${c.name}', tag: 'SIGNALING');
          return true;
        } catch (e) {
          AppLogger.warning('Answer publish via ${c.name} failed: $e',
              tag: 'SIGNALING');
          return false;
        }
      }),
    );

    if (!results.contains(true)) {
      throw StateError('could not publish the answer through any channel');
    }
  }

  /// The same answer arrives once per healthy channel. Deduplicate so the
  /// caller sets a remote description exactly once.
  void _onPayload(Uint8List payload) {
    final key = payload.length > 28
        ? String.fromCharCodes(payload.sublist(0, 28))
        : String.fromCharCodes(payload);
    if (!_seen.add(key)) return;
    if (!_controller.isClosed) _controller.add(payload);
  }

  @override
  Future<void> close() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await Future.wait(channels.map((c) => c.close().catchError((_) {})));
    await _controller.close();
  }
}

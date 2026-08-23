import 'dart:async';

/// Raised when the DataChannel send buffer stops draining altogether.
///
/// The distinction that matters is "slow" versus "dead". A relay path runs at
/// 1-3 MB/s and the buffer sits near its ceiling the whole time, which is
/// normal and must not abort anything. A buffer that has not moved *at all*
/// for [stalledFor] means the far side is gone — ICE dropped, the relay
/// allocation expired, the peer process died — and no amount of further
/// waiting will help.
class TransferStalled implements Exception {
  final int bufferedBytes;
  final Duration stalledFor;
  final String reason;

  const TransferStalled({
    required this.bufferedBytes,
    required this.stalledFor,
    required this.reason,
  });

  @override
  String toString() => 'transfer stalled: $reason '
      '($bufferedBytes bytes stuck in the send buffer for '
      '${stalledFor.inSeconds}s)';
}

/// Backpressure for a WebRTC DataChannel, with an escape hatch.
///
/// Written as free functions over closures rather than against RTCDataChannel
/// so the stall logic can be tested without a live peer connection — which is
/// the only way this behaviour could be covered at all, since the failure it
/// guards against needs a peer that goes away mid-transfer.
class SendBuffer {
  const SendBuffer._();

  /// Blocks until the buffer has room below [limit], the channel closes, or
  /// nothing drains for [stallTimeout].
  ///
  /// [bufferedAmount] returns null when the platform does not report it; that
  /// is treated as "no backpressure information available", and the caller is
  /// let through rather than parked forever on a value that will never change.
  /// [onDrain], when given, should return a future that completes the next
  /// time the buffer is reported to have drained. It turns the wait from
  /// polling into something event-driven: without it the loop can only notice
  /// room every [pollInterval], which caps throughput at
  /// `limit / pollInterval` regardless of what the link can carry — measured
  /// at 4.8 MB/s against a predicted 5.0 with a 256 KB window and a 50 ms
  /// poll, on a loopback connection with no network in the way at all.
  ///
  /// The poll interval stays as a backstop underneath it: some platforms
  /// report buffered amounts late or not at all, and a wait that depends
  /// solely on an event that never arrives is a hang.
  static Future<void> waitForRoom({
    required int? Function() bufferedAmount,
    required bool Function() isOpen,
    required int limit,
    Future<void> Function()? onDrain,
    Duration pollInterval = const Duration(milliseconds: 50),
    Duration stallTimeout = const Duration(seconds: 30),
  }) async {
    var best = bufferedAmount();
    if (best == null) return;

    var lastImprovement = DateTime.now();

    while (true) {
      if (!isOpen()) {
        throw TransferStalled(
          bufferedBytes: bufferedAmount() ?? 0,
          stalledFor: DateTime.now().difference(lastImprovement),
          reason: 'the data channel closed mid-transfer',
        );
      }

      final current = bufferedAmount();
      if (current == null || current <= limit) return;

      // Any downward movement counts as progress, however small: on a slow
      // relay the buffer hovers just above the limit for long stretches and
      // that is a working transfer, not a stalled one.
      if (current < best!) {
        best = current;
        lastImprovement = DateTime.now();
      }

      final stuckFor = DateTime.now().difference(lastImprovement);
      if (stuckFor >= stallTimeout) {
        throw TransferStalled(
          bufferedBytes: current,
          stalledFor: stuckFor,
          reason: 'the send buffer stopped draining',
        );
      }

      if (onDrain == null) {
        await Future<void>.delayed(pollInterval);
      } else {
        // Whichever comes first: the platform saying there is room, or the
        // backstop tick.
        await Future.any<void>([
          onDrain(),
          Future<void>.delayed(pollInterval),
        ]);
      }
    }
  }

  /// Same guarantees as [waitForRoom], but waits for the buffer to empty
  /// completely — the drain before signalling completion, so the receiver is
  /// not told the file is done while bytes are still queued.
  static Future<void> waitUntilEmpty({
    required int? Function() bufferedAmount,
    required bool Function() isOpen,
    Future<void> Function()? onDrain,
    Duration pollInterval = const Duration(milliseconds: 50),
    Duration stallTimeout = const Duration(seconds: 30),
  }) =>
      waitForRoom(
        bufferedAmount: bufferedAmount,
        isOpen: isOpen,
        limit: 0,
        onDrain: onDrain,
        pollInterval: pollInterval,
        stallTimeout: stallTimeout,
      );
}

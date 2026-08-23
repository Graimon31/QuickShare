import 'dart:async';

// The failure this guards against is a transfer that freezes at some
// percentage and never moves again: the sender parks in its backpressure loop,
// the UI keeps showing the last progress and the last speed, and no error ever
// arrives. Reproduced here with a buffer that simply stops draining.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/webrtc/send_buffer.dart';

void main() {
  group('SendBuffer.waitForRoom', () {
    test('returns as soon as the buffer drops below the limit', () async {
      var buffered = 500;
      final done = SendBuffer.waitForRoom(
        bufferedAmount: () => buffered,
        isOpen: () => true,
        limit: 100,
        pollInterval: const Duration(milliseconds: 1),
        stallTimeout: const Duration(seconds: 5),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      buffered = 50;

      await done; // completes rather than hanging
    });

    test('a buffer that never drains raises instead of waiting forever',
        () async {
      // The bug: this used to be `while (buffered > limit) await delay(50ms)`
      // with no exit, so a peer that went away froze the transfer silently.
      await expectLater(
        SendBuffer.waitForRoom(
          bufferedAmount: () => 999999,
          isOpen: () => true,
          limit: 100,
          pollInterval: const Duration(milliseconds: 1),
          stallTimeout: const Duration(milliseconds: 40),
        ),
        throwsA(isA<TransferStalled>()),
      );
    });

    test('a slow but moving buffer is never mistaken for a stall', () async {
      // A relay path keeps the buffer pinned just above the limit for long
      // stretches. That is a working transfer and must not abort.
      var buffered = 100000;
      final done = SendBuffer.waitForRoom(
        bufferedAmount: () {
          if (buffered > 100) buffered -= 200; // creeping down
          return buffered;
        },
        isOpen: () => true,
        limit: 100,
        pollInterval: const Duration(milliseconds: 1),
        stallTimeout: const Duration(milliseconds: 60),
      );

      await done;
    });

    test('a channel that closes mid-wait raises rather than hanging', () async {
      var open = true;
      final done = SendBuffer.waitForRoom(
        bufferedAmount: () => 999999,
        isOpen: () => open,
        limit: 100,
        pollInterval: const Duration(milliseconds: 1),
        stallTimeout: const Duration(seconds: 10),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      open = false;

      await expectLater(done, throwsA(isA<TransferStalled>()));
    });

    test('a platform that reports no buffered amount does not block', () async {
      // flutter_webrtc leaves bufferedAmount null on some platforms; parking on
      // a value that will never change would freeze every transfer there.
      await SendBuffer.waitForRoom(
        bufferedAmount: () => null,
        isOpen: () => true,
        limit: 100,
        pollInterval: const Duration(milliseconds: 1),
        stallTimeout: const Duration(milliseconds: 20),
      );
    });

    test('the raised error names the byte count and how long it was stuck',
        () async {
      try {
        await SendBuffer.waitForRoom(
          bufferedAmount: () => 262144,
          isOpen: () => true,
          limit: 1000,
          pollInterval: const Duration(milliseconds: 1),
          stallTimeout: const Duration(milliseconds: 30),
        );
        fail('expected a TransferStalled');
      } on TransferStalled catch (e) {
        expect(e.bufferedBytes, equals(262144));
        expect(e.toString(), contains('262144'));
        expect(e.toString(), contains('stopped draining'));
      }
    });
  });

  group('SendBuffer.waitUntilEmpty', () {
    test('waits for a full drain, not merely for room', () async {
      var buffered = 5000;
      final done = SendBuffer.waitUntilEmpty(
        bufferedAmount: () => buffered,
        isOpen: () => true,
        pollInterval: const Duration(milliseconds: 1),
        stallTimeout: const Duration(seconds: 5),
      );

      await Future<void>.delayed(const Duration(milliseconds: 5));
      buffered = 1; // still not empty
      await Future<void>.delayed(const Duration(milliseconds: 5));
      buffered = 0;

      await done;
    });

    test('a final drain that never finishes raises', () async {
      await expectLater(
        SendBuffer.waitUntilEmpty(
          bufferedAmount: () => 4096,
          isOpen: () => true,
          pollInterval: const Duration(milliseconds: 1),
          stallTimeout: const Duration(milliseconds: 40),
        ),
        throwsA(isA<TransferStalled>()),
      );
    });
  });

  group('the stale-bufferedAmount trap', () {
    test('a source that only reports a stale zero lets everything through',
        () async {
      // This is the shape of the real bug: flutter_webrtc caches
      // bufferedAmount on the Dart side and only refreshes it when the native
      // layer pushes an event. A send loop polling that cached value sees 0,
      // decides there is room, and keeps sending — until libwebrtc's hard
      // 16 MiB SCTP send buffer is full and it closes the channel.
      //
      // waitForRoom cannot detect this on its own: from in here, a buffer that
      // reads 0 IS an empty buffer. The fix has to be at the caller, which now
      // counts what it queued itself. This test pins the behaviour so the
      // limitation stays visible.
      var calls = 0;
      for (var i = 0; i < 100; i++) {
        await SendBuffer.waitForRoom(
          bufferedAmount: () {
            calls++;
            return 0; // never moves, exactly like the stale cache
          },
          isOpen: () => true,
          limit: 262144,
          pollInterval: const Duration(milliseconds: 1),
          stallTimeout: const Duration(milliseconds: 20),
        );
      }
      expect(calls, greaterThan(0));
    });

    test('a locally counted queue does apply backpressure', () async {
      // What the transport does now: add every payload to its own counter on
      // send, and let the platform event correct it downward as bytes drain.
      var queued = 0;
      var chunksSent = 0;

      // Drains 16 KB per tick, mimicking the native event arriving late.
      Timer.periodic(const Duration(milliseconds: 2), (t) {
        queued = queued > 16384 ? queued - 16384 : 0;
        if (chunksSent >= 40) t.cancel();
      });

      var peak = 0;
      for (var i = 0; i < 40; i++) {
        queued += 16384; // one chunk queued
        chunksSent++;
        if (queued > peak) peak = queued;
        await SendBuffer.waitForRoom(
          bufferedAmount: () => queued,
          isOpen: () => true,
          limit: 262144,
          pollInterval: const Duration(milliseconds: 1),
          stallTimeout: const Duration(seconds: 5),
        );
      }

      // The whole point: the queue never runs away toward libwebrtc's 16 MiB
      // ceiling the way an unchecked loop would.
      expect(peak, lessThan(16 * 1024 * 1024));
      expect(peak, lessThanOrEqualTo(262144 + 16384));
    });
  });

  group('event-driven waking', () {
    test('wakes on the drain signal without waiting out the poll interval',
        () async {
      // The measured ceiling: with a 256 KB window and a 50 ms poll, polling
      // alone caps throughput at ~5 MB/s no matter what the link can carry.
      var queued = 500000;
      final drained = Completer<void>();

      final started = DateTime.now();
      final done = SendBuffer.waitForRoom(
        bufferedAmount: () => queued,
        isOpen: () => true,
        limit: 262144,
        onDrain: () => drained.future,
        pollInterval: const Duration(seconds: 5), // would dominate if polled
        stallTimeout: const Duration(seconds: 30),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      queued = 0;
      drained.complete();
      await done;

      expect(DateTime.now().difference(started).inSeconds, lessThan(2),
          reason: 'a 5 s poll must not be what ends the wait');
    });

    test('the poll still ends the wait when no drain event ever comes',
        () async {
      // Some platforms report buffered amounts late or not at all; depending
      // solely on an event that never fires would be a hang.
      var queued = 500000;
      final never = Completer<void>();

      final done = SendBuffer.waitForRoom(
        bufferedAmount: () => queued,
        isOpen: () => true,
        limit: 262144,
        onDrain: () => never.future,
        pollInterval: const Duration(milliseconds: 5),
        stallTimeout: const Duration(seconds: 30),
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      queued = 0;
      await done;
    });

    test('stall detection still fires with a drain signal that never comes',
        () async {
      final never = Completer<void>();
      await expectLater(
        SendBuffer.waitForRoom(
          bufferedAmount: () => 999999,
          isOpen: () => true,
          limit: 100,
          onDrain: () => never.future,
          pollInterval: const Duration(milliseconds: 1),
          stallTimeout: const Duration(milliseconds: 40),
        ),
        throwsA(isA<TransferStalled>()),
      );
    });
  });
}

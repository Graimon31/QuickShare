// A negotiation frame is cut into parts that each fit a notification, and put
// back together on the far side.
//
// The limits that matter are 20 (what a connection nobody negotiated carries),
// 182 (an iPhone) and something large; the faults that matter are the ones a
// stranger can cause, because the channel is neither encrypted nor bonded.
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/transfer/ble_frame.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List _frameOf(int size) =>
    _bytes('{"serve":"${'x' * (size - '{"serve":""}'.length)}"}');

void main() {
  group('cutting a frame up', () {
    test('a frame that fits is one part with a four-byte header', () {
      final frame = _bytes('{"link":{"host":"receiver"}}');
      final parts = BleFrameSplitter().split(frame,
          notificationBytes: 182, frameId: 7);

      expect(parts, hasLength(1));
      expect(parts.single.sublist(0, 4), [BleFrame.marker, 7, 0, 1]);
      expect(parts.single.sublist(4), frame);
    });

    for (final limit in [20, 182, 512]) {
      test('no part is longer than $limit, and together they are the frame',
          () {
        for (final size in [1, 15, 16, 17, 100, 203, 225, 1000, 3072]) {
          final frame = _frameOf(size < 12 ? 12 : size);
          final parts = BleFrameSplitter().split(frame, notificationBytes: limit);

          expect(parts.map((p) => p.length),
              everyElement(lessThanOrEqualTo(limit)),
              reason: '$size bytes at $limit');
          expect(parts.length, (frame.length + limit - 5) ~/ (limit - 4),
              reason: 'no more parts than it takes');
          final joined = BytesBuilder();
          for (final p in parts) {
            joined.add(p.sublist(4));
          }
          expect(joined.toBytes(), frame);
        }
      });
    }

    test('the sizes that were asked about: 203 and 225 bytes', () {
      final cut = BleFrameSplitter();

      expect(cut.split(_frameOf(203), notificationBytes: 182), hasLength(2));
      expect(cut.split(_frameOf(225), notificationBytes: 182), hasLength(2));
      expect(cut.split(_frameOf(203), notificationBytes: 20), hasLength(13));
      expect(cut.split(_frameOf(225), notificationBytes: 20), hasLength(15));
      expect(cut.split(_frameOf(203), notificationBytes: 244), hasLength(1));
      expect(cut.split(_frameOf(225), notificationBytes: 244), hasLength(1));
    });

    test('every part of a frame has its number, its place and the count', () {
      final parts =
          BleFrameSplitter().split(_frameOf(100), notificationBytes: 20, frameId: 200);

      for (var i = 0; i < parts.length; i++) {
        expect(parts[i].sublist(0, 4), [BleFrame.marker, 200, i, parts.length]);
      }
    });

    test('the next frame is numbered after the last, and 255 is followed by 0',
        () {
      final cut = BleFrameSplitter(firstId: 254);
      final ids = [
        for (var i = 0; i < 4; i++)
          cut.split(_frameOf(30), notificationBytes: 182).first[1]
      ];

      expect(ids, [254, 255, 0, 1]);
    });

    test('an empty frame is refused', () {
      expect(
          () => BleFrameSplitter().split(Uint8List(0), notificationBytes: 20),
          throwsA(isA<BleFrameException>()
              .having((e) => e.problem, 'problem', BleFrameProblem.emptyFrame)));
    });

    test('the largest frame is allowed and one byte more is not', () {
      expect(
          BleFrameSplitter()
              .split(_frameOf(BleFrame.maxFrameBytes), notificationBytes: 20),
          hasLength(192),
          reason: '3072 bytes at 16 a part: inside the 255 a frame may have');
      expect(
          () => BleFrameSplitter()
              .split(_frameOf(BleFrame.maxFrameBytes + 1), notificationBytes: 512),
          throwsA(isA<BleFrameException>().having(
              (e) => e.problem, 'problem', BleFrameProblem.frameTooLarge)));
    });

    test('a connection that cannot hold a header and a byte is refused', () {
      for (final limit in [-1, 0, 1, 4]) {
        expect(
            () => BleFrameSplitter().split(_frameOf(50), notificationBytes: limit),
            throwsA(isA<BleFrameException>().having((e) => e.problem, 'problem',
                BleFrameProblem.notificationTooSmall)),
            reason: '$limit');
      }
    });

    test('a connection so small the frame would need more than 255 parts is '
        'refused', () {
      expect(
          () => BleFrameSplitter().split(_frameOf(256), notificationBytes: 5),
          throwsA(isA<BleFrameException>()
              .having((e) => e.problem, 'problem', BleFrameProblem.tooManyParts)));
      expect(BleFrameSplitter().split(_frameOf(255), notificationBytes: 5),
          hasLength(255));
    });
  });

  group('putting it back together', () {
    late List<Uint8List> frames;
    late List<BleFrameException> faults;
    late BleFrameAssembler assembler;

    setUp(() {
      frames = [];
      faults = [];
      assembler = BleFrameAssembler(onFrame: frames.add, onFault: faults.add);
    });

    tearDown(() => assembler.dispose());

    void feed(Iterable<Uint8List> parts) => parts.forEach(assembler.add);

    for (final limit in [20, 182, 512]) {
      test('at $limit what was cut comes out whole, byte for byte', () {
        for (final size in [12, 100, 203, 225, 1000, 3072]) {
          final frame = _frameOf(size);
          feed(BleFrameSplitter().split(frame, notificationBytes: limit));

          expect(frames.last, frame, reason: '$size bytes at $limit');
        }
        expect(faults, isEmpty);
      });
    }

    test('one frame after another, with nothing left over between them', () {
      final cut = BleFrameSplitter();
      final a = _frameOf(225);
      final b = _frameOf(81);

      feed(cut.split(a, notificationBytes: 20));
      feed(cut.split(b, notificationBytes: 182));
      feed(cut.split(a, notificationBytes: 20));

      expect(frames, [a, b, a]);
      expect(assembler.isAssembling, isFalse);
      expect(faults, isEmpty);
    });

    test('the same id twice in a row is fine once the first has ended', () {
      final cut = BleFrameSplitter();
      feed(cut.split(_frameOf(60), notificationBytes: 20, frameId: 3));
      feed(cut.split(_frameOf(60), notificationBytes: 20, frameId: 3));

      expect(frames, hasLength(2));
      expect(faults, isEmpty);
    });

    test('binary payload survives: nothing is read as text on the way', () {
      final frame = Uint8List.fromList(List.generate(300, (i) => i % 256));
      feed(BleFrameSplitter().split(frame, notificationBytes: 20));

      expect(frames.single, frame);
    });

    test('a part the platform reuses the buffer of does not change the frame',
        () {
      final frame = _frameOf(100);
      final buffer = Uint8List(20);
      for (final p in BleFrameSplitter().split(frame, notificationBytes: 20)) {
        buffer.fillRange(0, buffer.length, 0);
        buffer.setRange(0, p.length, p);
        assembler.add(Uint8List.sublistView(buffer, 0, p.length));
      }

      expect(frames.single, frame);
    });

    // -- what is wrong, and what is said ------------------------------------

    void expectFault(BleFrameProblem problem) {
      expect(faults, hasLength(1), reason: 'one fault, not a cascade');
      expect(faults.single.problem, problem, reason: faults.single.message);
      expect(frames, isEmpty);
      expect(assembler.isAssembling, isFalse,
          reason: 'a fault leaves nothing half-built');
    }

    test('a part skipped is a lost part', () {
      final p = BleFrameSplitter().split(_frameOf(100), notificationBytes: 20);
      feed([p[0], p[1], ...p.skip(3)]);
      expectFault(BleFrameProblem.missingPart);
    });

    test('a part repeated is refused', () {
      final p = BleFrameSplitter().split(_frameOf(100), notificationBytes: 20);
      feed([p[0], p[1], p[1], p[2]]);
      expectFault(BleFrameProblem.duplicatePart);
    });

    test('the first part sent twice is a repeat, not a new frame', () {
      final p = BleFrameSplitter().split(_frameOf(100), notificationBytes: 20);
      feed([p[0], p[0]]);
      expectFault(BleFrameProblem.duplicatePart);
    });

    test('a part after the last has no frame to belong to', () {
      final p = BleFrameSplitter().split(_frameOf(100), notificationBytes: 20);
      feed(p);
      frames.clear();
      assembler.add(p.last);
      expectFault(BleFrameProblem.orphanPart);
    });

    test('a part from the middle with no beginning is an orphan', () {
      final p = BleFrameSplitter().split(_frameOf(100), notificationBytes: 20);
      assembler.add(p[2]);
      expectFault(BleFrameProblem.orphanPart);
    });

    test('a part of another frame inside this one is interleaved', () {
      final cut = BleFrameSplitter();
      final mine = cut.split(_frameOf(100), notificationBytes: 20, frameId: 1);
      final theirs = cut.split(_frameOf(100), notificationBytes: 20, frameId: 2);
      feed([mine[0], mine[1], theirs[2]]);
      expectFault(BleFrameProblem.interleaved);
    });

    test('the start of another frame inside this one is an interruption', () {
      final cut = BleFrameSplitter();
      final mine = cut.split(_frameOf(100), notificationBytes: 20, frameId: 1);
      final theirs = cut.split(_frameOf(100), notificationBytes: 20, frameId: 2);
      feed([mine[0], mine[1], theirs[0]]);
      expectFault(BleFrameProblem.interrupted);
    });

    test('a part that changes the count is refused', () {
      final p = BleFrameSplitter().split(_frameOf(100), notificationBytes: 20);
      final lying = Uint8List.fromList(p[1])..[3] = p.length + 1;
      feed([p[0], lying]);
      expectFault(BleFrameProblem.countChanged);
    });

    test('a count of zero, or an index past the count, is a bad header', () {
      assembler.add(Uint8List.fromList([BleFrame.marker, 1, 0, 0, 65]));
      expectFault(BleFrameProblem.badHeader);
      faults.clear();
      assembler.reset();
      assembler.add(Uint8List.fromList([BleFrame.marker, 1, 3, 3, 65]));
      expectFault(BleFrameProblem.badHeader);
    });

    test('a header with nothing after it, and an empty notification, are '
        'too short', () {
      assembler.add(Uint8List.fromList([BleFrame.marker, 1, 0, 1]));
      expectFault(BleFrameProblem.tooShort);
      faults.clear();
      assembler.reset();
      assembler.add(Uint8List(0));
      expectFault(BleFrameProblem.tooShort);
    });

    test('a notification that is not ours is not a frame', () {
      assembler.add(Uint8List.fromList([0x00, 1, 2, 3, 4, 5]));
      expectFault(BleFrameProblem.notAFrame);
    });

    test('bare JSON is what an older sender sends, and is the one thing that '
        'says so', () {
      assembler.add(_bytes('{"link":{"host":"receiver"}}'));
      expectFault(BleFrameProblem.unframed);
      expect(faults.single.isOlderSender, isTrue);
    });

    test('every other fault is damage, not an older sender', () {
      final p = BleFrameSplitter().split(_frameOf(100), notificationBytes: 20);
      for (final bad in <List<Uint8List>>[
        [p[0], p[2]],
        [p[0], p[0]],
        [p[2]],
        [Uint8List.fromList([0x00, 1, 2, 3, 4])],
        [Uint8List.fromList([BleFrame.marker, 1, 0, 1])],
      ]) {
        faults.clear();
        assembler.reset();
        feed(bad);
        expect(faults.single.isOlderSender, isFalse,
            reason: faults.single.message);
      }
    });

    test('bare JSON in the middle of a frame is damage: nothing older sends '
        'a frame that has begun', () {
      final p = BleFrameSplitter().split(_frameOf(100), notificationBytes: 20);
      feed([p[0], _bytes('{"x":1}')]);
      expectFault(BleFrameProblem.notAFrame);
    });

    test('a frame cannot outgrow the limit, and the check is at the part '
        'that crosses it', () {
      final parts = [
        for (var i = 0; i < 250; i++)
          Uint8List.fromList([BleFrame.marker, 5, i, 250, ...List.filled(16, 0x41)])
      ];
      var fed = 0;
      for (final part in parts) {
        if (faults.isNotEmpty) break;
        assembler.add(part);
        fed++;
      }

      expectFault(BleFrameProblem.tooLarge);
      expect(fed, 193, reason: '192 parts of 16 bytes is exactly 3072; the '
          '193rd crosses it');
    });

    test('a first part that is itself past the limit is refused', () {
      final small = BleFrameAssembler(
          onFrame: frames.add, onFault: faults.add, maxFrameBytes: 10);
      addTearDown(small.dispose);
      small.add(Uint8List.fromList([BleFrame.marker, 1, 0, 2, ...List.filled(11, 1)]));

      expect(faults.single.problem, BleFrameProblem.tooLarge);
    });

    test('a fault is final: what follows it is ignored, not reported again',
        () {
      final cut = BleFrameSplitter();
      final p = cut.split(_frameOf(100), notificationBytes: 20);
      feed([p[0], p[2]]);
      expect(assembler.hasFaulted, isTrue);
      feed(p.skip(3));
      feed(cut.split(_frameOf(50), notificationBytes: 20));

      expect(faults, hasLength(1),
          reason: 'the first fault says what happened; the rest would bury it');
      expect(frames, isEmpty, reason: 'nothing after it is believed');
    });

    test('reset() takes the fault back, for a new connection', () {
      final cut = BleFrameSplitter();
      final p = cut.split(_frameOf(100), notificationBytes: 20);
      feed([p[0], p[2]]);
      assembler.reset();
      final good = _frameOf(50);
      feed(cut.split(good, notificationBytes: 20));

      expect(assembler.hasFaulted, isFalse);
      expect(frames.single, good);
      expect(faults, hasLength(1));
    });

    test('memory does not grow with what it is fed', () {
      // A stranger sending parts of a frame that never ends: the buffer is
      // bounded by the limit, and a fault empties it.
      for (var round = 0; round < 50; round++) {
        for (var i = 0; i < 255; i++) {
          assembler.add(Uint8List.fromList(
              [BleFrame.marker, round, i, 255, ...List.filled(100, 1)]));
          if (faults.isNotEmpty) break;
        }
        expect(faults.last.problem, BleFrameProblem.tooLarge);
        faults.clear();
        assembler.reset();
      }
      expect(assembler.isAssembling, isFalse);
    });
  });

  group('the clock', () {
    test('a frame that does not finish in time is a timeout, said once', () {
      fakeAsync((async) {
        final faults = <BleFrameException>[];
        final frames = <Uint8List>[];
        final assembler = BleFrameAssembler(
            onFrame: frames.add,
            onFault: faults.add,
            timeout: const Duration(seconds: 10));
        final p = BleFrameSplitter().split(_frameOf(100), notificationBytes: 20);

        assembler.add(p[0]);
        assembler.add(p[1]);
        async.elapse(const Duration(seconds: 9));
        expect(faults, isEmpty, reason: 'still inside the time');
        async.elapse(const Duration(seconds: 2));

        expect(faults, hasLength(1));
        expect(faults.single.problem, BleFrameProblem.timedOut);
        expect(faults.single.message, contains('2 of ${p.length}'));
        expect(assembler.isAssembling, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(faults, hasLength(1), reason: 'once');
      });
    });

    test('the time counts from the first part, not from the latest', () {
      fakeAsync((async) {
        final faults = <BleFrameException>[];
        final assembler = BleFrameAssembler(
            onFrame: (_) {},
            onFault: faults.add,
            timeout: const Duration(seconds: 10));
        final p = BleFrameSplitter().split(_frameOf(300), notificationBytes: 20);

        // A part every three seconds never lets a gap-based timer fire.
        for (var i = 0; i < 5; i++) {
          assembler.add(p[i]);
          async.elapse(const Duration(seconds: 3));
        }

        expect(faults.single.problem, BleFrameProblem.timedOut);
      });
    });

    test('a frame that finishes stops the clock', () {
      fakeAsync((async) {
        final faults = <BleFrameException>[];
        final frames = <Uint8List>[];
        final assembler = BleFrameAssembler(
            onFrame: frames.add,
            onFault: faults.add,
            timeout: const Duration(seconds: 10));

        for (final part in BleFrameSplitter()
            .split(_frameOf(100), notificationBytes: 20)) {
          assembler.add(part);
        }
        async.elapse(const Duration(minutes: 1));

        expect(frames, hasLength(1));
        expect(faults, isEmpty);
      });
    });

    test('the next frame has a clock of its own', () {
      fakeAsync((async) {
        final faults = <BleFrameException>[];
        final frames = <Uint8List>[];
        final assembler = BleFrameAssembler(
            onFrame: frames.add,
            onFault: faults.add,
            timeout: const Duration(seconds: 10));
        final cut = BleFrameSplitter();

        for (final part in cut.split(_frameOf(100), notificationBytes: 20)) {
          assembler.add(part);
        }
        async.elapse(const Duration(seconds: 8));
        final next = cut.split(_frameOf(100), notificationBytes: 20);
        assembler.add(next[0]);
        async.elapse(const Duration(seconds: 8));
        expect(faults, isEmpty,
            reason: 'eight seconds into the second frame, not sixteen');
        async.elapse(const Duration(seconds: 3));

        expect(faults.single.problem, BleFrameProblem.timedOut);
      });
    });

    test('dispose stops a clock that is running', () {
      fakeAsync((async) {
        final faults = <BleFrameException>[];
        final assembler = BleFrameAssembler(
            onFrame: (_) {}, onFault: faults.add);
        assembler.add(BleFrameSplitter()
            .split(_frameOf(100), notificationBytes: 20)
            .first);

        assembler.dispose();
        async.elapse(const Duration(minutes: 1));

        expect(faults, isEmpty);
      });
    });
  });
}

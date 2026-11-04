// OPS-01 — a transfer that cannot fit says so before it starts, and one that
// runs out of room half-way keeps what it has.
//
// The free-space check was a stub that always answered "unknown" (the plugin
// it used crashed on iOS 18.4.1), so a 40 GB transfer onto a 10 GB disk ran
// for twenty minutes and failed at the end. When the disk filled mid-write the
// receiver then *deleted* its partial — throwing away the only thing a retry
// could have resumed from.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/storage/disk_space.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';

import 'qhtp_receive_harness.dart';

Uint8List _bytes(int n, int seed) {
  final rand = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => rand.nextInt(256)));
}

class _FixedSpace extends DiskSpaceProbe {
  _FixedSpace(this.answer);
  final DiskSpace answer;
  final asked = <String>[];

  @override
  Future<DiskSpace> available(String path) async {
    asked.add(path);
    return answer;
  }
}

/// A volume with a fixed number of bytes left, shared by every file opened
/// on it: takes what fits of a write, then reports the OS's own "no space
/// left on device" — the shape a real full disk takes, partial block and all.
class _Volume {
  _Volume(this.room);
  int room;

  RandomAccessFile wrap(RandomAccessFile real) => _FillingDisk(real, this);
}

class _FillingDisk implements RandomAccessFile {
  _FillingDisk(this._real, this._volume);

  final RandomAccessFile _real;
  final _Volume _volume;

  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer,
      [int start = 0, int? end]) async {
    final stop = end ?? buffer.length;
    final wanted = stop - start;
    if (wanted <= _volume.room) {
      _volume.room -= wanted;
      await _real.writeFrom(buffer, start, stop);
      return this;
    }
    if (_volume.room > 0) {
      await _real.writeFrom(buffer, start, start + _volume.room);
    }
    _volume.room = 0;
    throw const FileSystemException(
        'writeFrom failed', '', OSError('No space left on device', 28));
  }

  @override
  Future<RandomAccessFile> flush() async {
    await _real.flush();
    return this;
  }

  @override
  Future<void> close() => _real.close();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} on a test disk');
}

void main() {
  setUpAll(installFakeWakelock);

  const margin = 64 * 1024 * 1024;
  late QhtpHarness h;
  final a = _bytes(200 * 1024, 21);
  final b = _bytes(160 * 1024, 22);

  setUp(() async => h = await QhtpHarness.create());
  tearDown(() => h.dispose());

  Future<void> stopWhenSecondItemIsAsked() async {
    late QhtpReceiverClient first;
    first = h.client(onRequest: (r) {
      if (r.isFile && r.fileId == h.idOf('b.bin')) first.cancel();
    });
    expectRefused(await first.downloadSession(
        payload: h.payload, targetBaseDir: h.target.path));
    h.requests.clear();
  }

  group('before anything is requested', () {
    test('all verified items need no free-space margin', () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      final states = <String, QhtpItemState>{};
      for (final entry in {'a.bin': a, 'b.bin': b}.entries) {
        final item = h.indexed.manifest.items
            .firstWhere((i) => i.id == h.idOf(entry.key));
        final file = File(h.received(entry.key))
          ..createSync(recursive: true)
          ..writeAsBytesSync(entry.value);
        states[item.id] = QhtpItemState(
          id: item.id,
          path: item.path,
          size: item.size,
          status: 'completed',
          partialBytes: item.size,
          sha256: 'sha256:${sha256.convert(entry.value)}',
          finalPath: file.path,
          modifiedMs: file.statSync().modified.millisecondsSinceEpoch,
        );
      }
      await h.store.saveState(
          sessionId: h.sessionId,
          host: '127.0.0.1',
          port: h.payload.port,
          token: h.payload.token,
          baseDir: h.target.path,
          items: states);
      final probe = _FixedSpace(const DiskSpace.known(0));

      expectReceived(await h
          .client(diskSpace: probe)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));
      expect(probe.asked, isEmpty);
      expect(h.requests.where((r) => r.isFile), isEmpty);
    });

    test('an oversized partial is discarded and credits no item', () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      File('${h.received('a.bin')}.qs.partial')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(a.length + b.length, 0));
      final needed = a.length + b.length + margin;
      final probe = _FixedSpace(DiskSpace.known(needed - 1));

      final failure = expectRefused(await h
          .client(diskSpace: probe)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));
      expect(FailureCode.parseNotEnoughSpace(failure.code)?.needed, needed);
      expect(h.requests.where((r) => r.isFile), isEmpty);

      expectReceived(await h
          .client(diskSpace: _FixedSpace(DiskSpace.known(needed)))
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
      expect(File(h.received('b.bin')).readAsBytesSync(), b);
    });

    test('a pinned numbered partial is counted at its actual path', () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      final item =
          h.indexed.manifest.items.firstWhere((i) => i.id == h.idOf('a.bin'));
      const have = 100 * 1024;
      final pinned = h.received('a (1).bin');
      File(h.received('a.bin'))
        ..createSync(recursive: true)
        ..writeAsStringSync('existing');
      File('$pinned.qs.partial').writeAsBytesSync(a.sublist(0, have));
      await h.store.saveState(
          sessionId: h.sessionId,
          host: '127.0.0.1',
          port: h.payload.port,
          token: h.payload.token,
          baseDir: h.target.path,
          items: {
            item.id: QhtpItemState(
                id: item.id,
                path: item.path,
                size: item.size,
                status: 'partial',
                partialBytes: have,
                finalPath: pinned)
          });
      final exactly = a.length - have + b.length + margin;
      final probe = _FixedSpace(DiskSpace.known(exactly));

      expectReceived(await h
          .client(diskSpace: probe)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));
      expect(File(pinned).readAsBytesSync(), a);
      expect(File(h.received('a.bin')).readAsStringSync(), 'existing');
      expect(h.requests.where((r) => r.fileId == item.id).first.range,
          'bytes=$have-');
    });
    test('enough room: the transfer runs, and the destination was asked',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      final probe = _FixedSpace(const DiskSpace.known(10 * margin));

      expectReceived(await h
          .client(diskSpace: probe)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(probe.asked, isNotEmpty);
      expect(probe.asked.first, h.target.path,
          reason: 'the volume that matters is the destination\'s');
    });

    test('not enough room: refused before a single file is requested',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      final probe = _FixedSpace(const DiskSpace.known(10 * 1024 * 1024));

      final failure = expectRefused(await h
          .client(diskSpace: probe)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(FailureCode.parseNotEnoughSpace(failure.code), (
        needed: a.length + b.length + margin,
        available: 10 * 1024 * 1024,
      ));
      expect(failure.message, contains('space'));
      expect(h.requests.where((r) => r.isFile), isEmpty,
          reason: 'no body may be requested for a transfer that cannot fit');
      expect(
          Directory(h.target.path).listSync(recursive: true).whereType<File>(),
          isEmpty,
          reason: 'and nothing may be written');
    });

    test('only what is still to come has to fit: finished items are free',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      await stopWhenSecondItemIsAsked();

      // Room for b and the margin — not for a and b. A check against the
      // session total would turn this resume away.
      final probe = _FixedSpace(DiskSpace.known(b.length + margin));
      expectReceived(await h
          .client(diskSpace: probe)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));
      expect(File(h.received('b.bin')).readAsBytesSync(), b);
    });

    test('a partial that can be resumed is not counted a second time',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      const have = 100 * 1024;
      File('${h.received('b.bin')}.qs.partial')
        ..createSync(recursive: true)
        ..writeAsBytesSync(b.sublist(0, have));

      // a.bin whole, plus the rest of b.bin, plus the margin — to the byte.
      final exactly = a.length + (b.length - have) + margin;
      final short = _FixedSpace(DiskSpace.known(exactly - 1));
      final refused = expectRefused(await h
          .client(diskSpace: short)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));
      expect(FailureCode.parseNotEnoughSpace(refused.code)?.needed, exactly);

      final enough = _FixedSpace(DiskSpace.known(exactly));
      expectReceived(await h
          .client(diskSpace: enough)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));
      expect(File(h.received('b.bin')).readAsBytesSync(), b);
    });

    test('an unknown answer proceeds, says so in the log, and claims no check',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      final probe = _FixedSpace(const DiskSpace.unknown('no such channel'));

      expectReceived(await h
          .client(diskSpace: probe)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      final log = AppLogger.getInMemoryLogs().join('\n');
      expect(log, contains('free space unknown'));
      expect(log, contains('no such channel'));
      expect(log, isNot(contains('free-space check passed')));
    });
  });

  group('when the disk fills during the transfer', () {
    test('the partial and the record survive, and the retry resumes from them',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      const room = 70 * 1024;
      final probe = _FixedSpace(const DiskSpace.known(10 * margin));

      // a.bin takes 200 KB; this volume has 200 KB + 70 KB.
      final volume = _Volume(a.length + room);
      final failure = expectRefused(await h
          .client(diskSpace: probe, wrapSink: volume.wrap)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(failure.code, FailureCode.diskFull);
      expect(h.fileRequestsFor('b.bin'), 1,
          reason: 'a full disk is not a flaky network: no blind retries');

      final partial = File('${h.received('b.bin')}.qs.partial');
      expect(partial.existsSync(), isTrue,
          reason: 'deleting it would throw away the resume point');
      expect(partial.lengthSync(), room);
      expect(File(h.received('b.bin')).existsSync(), isFalse);
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
      expect((await h.store.loadState(h.sessionId))?[h.idOf('a.bin')]?.status,
          'completed');

      // The user frees some space and tries again.
      h.requests.clear();
      expectReceived(await h
          .client(diskSpace: probe)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      final resumed = h.requests.where((r) => r.isFile).toList();
      expect(resumed, hasLength(1));
      expect(resumed.single.range, 'bytes=$room-',
          reason: 'continues from the bytes that are already there');
      expect(File(h.received('b.bin')).readAsBytesSync(), b);
      expect(partial.existsSync(), isFalse);
    });
  });
}

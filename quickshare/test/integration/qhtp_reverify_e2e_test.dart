// DATA-01 — a "completed" item in the resume state is a claim, not a fact.
//
// The state file says an item finished. By the time the receiver resumes, the
// user may have deleted it, edited it, replaced it with a link, or the disk
// may have rotted a bit of it. The old receiver skipped every item the state
// called complete without looking at the disk, counted its bytes as received,
// and told the sender the transfer had succeeded — a false success, with the
// "received" file absent or wrong.
//
// What these tests pin down: before an item is skipped it is a regular file
// of the right size with the right SHA-256; when it is not, it is received
// again — and never over the top of whatever is there, because that may be the
// only copy of the user's own edit.
//
// Everything runs a real sender against a real receiver in temp directories.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';

import 'qhtp_receive_harness.dart';

Uint8List _bytes(int n, int seed) {
  final rand = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => rand.nextInt(256)));
}

void main() {
  setUpAll(installFakeWakelock);

  late QhtpHarness h;
  final a = _bytes(300 * 1024, 1);
  final b = _bytes(120 * 1024, 2);

  setUp(() async => h = await QhtpHarness.create());
  tearDown(() => h.dispose());

  /// Receives `a.bin` and then stops when `b.bin` is asked for — a transfer
  /// interrupted between two items, which is the state resume exists for.
  Future<void> interruptedAfterFirstItem() async {
    late QhtpReceiverClient first;
    first = h.client(onRequest: (r) {
      if (r.isFile && r.fileId == h.idOf('b.bin')) first.cancel();
    });
    final result = await first.downloadSession(
        payload: h.payload, targetBaseDir: h.target.path);
    expectRefused(result);

    final saved = await h.store.loadState(h.sessionId);
    expect(saved?[h.idOf('a.bin')]?.status, 'completed',
        reason: 'setup: the first item must be recorded as finished');
    expect(File(h.received('a.bin')).readAsBytesSync(), a);
    h.requests.clear();
  }

  /// [interruptedAfterFirstItem] for a session whose second item is `z.bin`.
  Future<void> interruptedAfterFirstItem2() async {
    late QhtpReceiverClient first;
    first = h.client(onRequest: (r) {
      if (r.isFile && r.fileId == h.idOf('z.bin')) first.cancel();
    });
    expectRefused(await first.downloadSession(
        payload: h.payload, targetBaseDir: h.target.path));
    expect((await h.store.loadState(h.sessionId))?.values.map((i) => i.status),
        contains('completed'),
        reason: 'setup: the first item must be recorded as finished');
    h.requests.clear();
  }

  /// Rewrites the saved record of [relative], the way a crash, an older build
  /// or somebody with a text editor could leave it. [baseDir] is the
  /// destination the record claims to have been made for.
  Future<void> editRecord(
    String relative,
    QhtpItemState Function(QhtpItemState record) edit, {
    String? baseDir,
  }) async {
    final loaded = (await h.store.loadState(h.sessionId))!;
    final id = h.idOf(relative);
    loaded[id] = edit(loaded[id]!);
    await h.store.saveState(
      sessionId: h.sessionId,
      host: '127.0.0.1',
      port: h.payload.port,
      token: h.payload.token,
      baseDir: baseDir ?? h.target.path,
      items: loaded,
    );
  }

  Future<List<QhtpProgress>> resume({QhtpReceiverClient? client}) async {
    final progress = <QhtpProgress>[];
    final result = await (client ?? h.client()).downloadSession(
      payload: h.payload,
      targetBaseDir: h.target.path,
      onProgress: progress.add,
    );
    expectReceived(result);
    return progress;
  }

  group('the item is checked before it is skipped', () {
    test('A: an intact item is not received again, and counts as received',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();
      final before = File(h.received('a.bin')).statSync().modified;

      final progress = await resume();

      expect(h.fileRequestsFor('a.bin'), 0,
          reason: 'a verified file must not cost a second transfer');
      expect(h.fileRequestsFor('b.bin'), 1);
      expect(File(h.received('a.bin')).statSync().modified, before);
      expect(File(h.received('b.bin')).readAsBytesSync(), b);

      // Progress counts the verified item, once, and never goes backwards.
      final transferring =
          progress.where((e) => e.phase == 'transferring').toList();
      expect(transferring.first.sessionReceived, greaterThanOrEqualTo(a.length),
          reason: 'the verified item is already received');
      var last = 0;
      for (final e in progress) {
        expect(e.sessionReceived, greaterThanOrEqualTo(last));
        last = e.sessionReceived;
      }
      expect(progress.last.phase, 'completed');
      expect(progress.last.sessionReceived, a.length + b.length);
    });

    test('B: a deleted item is received again under its own name', () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();
      File(h.received('a.bin')).deleteSync();

      final progress = await resume();

      expect(h.fileRequestsFor('a.bin'), 1);
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
      expect(File(h.received('a (1).bin')).existsSync(), isFalse,
          reason: 'the name is free again, so it is reused');

      // The bytes of the missing item were not claimed as received up front.
      final first = progress.firstWhere((e) => e.phase == 'transferring');
      expect(first.sessionReceived, lessThan(a.length));
      expect(progress.last.sessionReceived, a.length + b.length);
    });

    test(
        'C: an edited item (another size) is kept and the real one lands '
        'beside it', () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();
      final edited = Uint8List.fromList([...a, 1, 2, 3]);
      File(h.received('a.bin')).writeAsBytesSync(edited);

      await resume();

      expect(File(h.received('a.bin')).readAsBytesSync(), edited,
          reason: 'the user\'s version is never replaced');
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });

    test('E: same size, different content is caught by the checksum', () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();
      final rotted = Uint8List.fromList(a)..[a.length ~/ 2] ^= 0xFF;
      File(h.received('a.bin')).writeAsBytesSync(rotted);

      await resume();

      expect(h.fileRequestsFor('a.bin'), 1,
          reason: 'only a hash can tell these two apart');
      expect(File(h.received('a.bin')).readAsBytesSync(), rotted);
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });

    test('D: an item replaced by a symlink is never written through', () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();

      final victim = File(p.join(h.outside.path, 'victim.txt'))
        ..writeAsStringSync('the user\'s own file');
      File(h.received('a.bin')).deleteSync();
      Link(h.received('a.bin')).createSync(victim.path);
      final outsideBefore = QhtpHarness.snapshot(h.outside);

      await resume();

      expect(QhtpHarness.snapshot(h.outside), outsideBefore,
          reason: 'nothing may be written through the link');
      expect(FileSystemEntity.isLinkSync(h.received('a.bin')), isTrue,
          reason: 'the link is left exactly as it was');
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a,
          reason: 'the real file is received under a name that is free');
      expect(File(h.received('b.bin')).readAsBytesSync(), b);
    });

    test('a folder where the file should be is left alone', () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();
      File(h.received('a.bin')).deleteSync();
      Directory(h.received('a.bin')).createSync();
      File(p.join(h.received('a.bin'), 'mine.txt')).writeAsStringSync('mine');

      await resume();

      expect(File(p.join(h.received('a.bin'), 'mine.txt')).readAsStringSync(),
          'mine');
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });

    test('an item replaced by a link to a copy of itself is not trusted',
        () async {
      // Same size, same bytes, same digest: everything but the file being a
      // file. The copy is somebody else's, and a link can be pointed
      // elsewhere tomorrow.
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();
      final copy = File(p.join(h.outside.path, 'copy.bin'))
        ..writeAsBytesSync(a);
      File(h.received('a.bin')).deleteSync();
      Link(h.received('a.bin')).createSync(copy.path);

      await resume();

      expect(h.fileRequestsFor('a.bin'), 1,
          reason: 'a link to a good copy is still not the file');
      expect(FileSystemEntity.isLinkSync(h.received('a.bin')), isTrue,
          reason: 'the link is left exactly as it was');
      expect(copy.readAsBytesSync(), a);
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });

    test(
        'an item inside a folder that became a link is not trusted, even '
        'when the folder leads to a copy', () async {
      await h.serve({'sub/a.bin': a, 'z.bin': b});
      await interruptedAfterFirstItem2();
      final copyDir = Directory(p.join(h.outside.path, 'sub'))
        ..createSync(recursive: true);
      File(p.join(copyDir.path, 'a.bin')).writeAsBytesSync(a);
      Directory(h.received('sub')).deleteSync(recursive: true);
      Link(h.received('sub')).createSync(copyDir.path);
      final outsideBefore = QhtpHarness.snapshot(h.outside);

      final failure = expectRefused(await h
          .client()
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(failure.code, FailureCode.unsafeDestination,
          reason: 'what is on disk was reached through a link; it was neither '
              'counted as received nor written to');
      expect(QhtpHarness.snapshot(h.outside), outsideBefore);
    });

    test('the digest the sender gives outranks the one the record holds',
        () async {
      // A record is a file the user can edit, and so is the file it vouches
      // for. Rot the one and rewrite the other to match, and the pair agrees
      // with each other — and with nothing the sender ever sent.
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();
      final rotted = Uint8List.fromList(a)..[a.length ~/ 2] ^= 0xFF;
      File(h.received('a.bin')).writeAsBytesSync(rotted);
      await editRecord(
        'a.bin',
        (r) => QhtpItemState(
          id: r.id,
          path: r.path,
          size: r.size,
          status: r.status,
          partialBytes: r.partialBytes,
          sha256: 'sha256:${sha256.convert(rotted)}',
          finalPath: r.finalPath,
          modifiedMs: r.modifiedMs,
        ),
      );

      await resume();

      expect(h.fileRequestsFor('a.bin'), 1);
      expect(File(h.received('a.bin')).readAsBytesSync(), rotted,
          reason: 'what was there is kept');
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });

    test(
        'a record that belongs to another file under the same id is not '
        'used', () async {
      // Ids are positions in the manifest. A record that says `000001` was
      // `other.bin`, whole and in place, is not a record of this `000001`
      // even when the bytes it points at happen to be right.
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();
      final other = File(h.received('other.bin'))..writeAsBytesSync(a);
      File(h.received('a.bin')).deleteSync();
      await editRecord(
        'a.bin',
        (r) => QhtpItemState(
          id: r.id,
          path: '${p.basename(h.source.path)}/other.bin',
          size: r.size,
          status: 'completed',
          partialBytes: r.size,
          sha256: r.sha256,
          finalPath: other.path,
          modifiedMs: other.statSync().modified.millisecondsSinceEpoch,
        ),
      );

      await resume();

      expect(h.fileRequestsFor('a.bin'), 1,
          reason:
              'the file the sender is offering as a.bin was never received');
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
    });

    test('state recorded for another destination is not trusted', () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();

      final elsewhere = Directory.systemTemp.createTempSync('qhtp_elsewhere_');
      addTearDown(() => elsewhere.deleteSync(recursive: true));

      final result = await h
          .client()
          .downloadSession(payload: h.payload, targetBaseDir: elsewhere.path);
      expectReceived(result);

      expect(h.fileRequestsFor('a.bin'), 1,
          reason: 'a.bin completed somewhere else, not in this folder');
      expect(
          File(p.join(elsewhere.path, p.basename(h.source.path), 'a.bin'))
              .readAsBytesSync(),
          a);
    });
  });

  group('a record cannot be used to aim the receiver', () {
    test('a saved name outside the destination is ignored, not written to',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();

      final victim = File(p.join(h.outside.path, 'victim.txt'))
        ..writeAsStringSync('the user\'s own file');
      final loaded = (await h.store.loadState(h.sessionId))!;
      final item = loaded[h.idOf('a.bin')]!;
      loaded[h.idOf('a.bin')] = QhtpItemState(
        id: item.id,
        path: item.path,
        size: item.size,
        status: 'pending',
        finalPath: victim.path,
      );
      await h.store.saveState(
        sessionId: h.sessionId,
        host: '127.0.0.1',
        port: h.payload.port,
        token: h.payload.token,
        baseDir: h.target.path,
        items: loaded,
      );
      final before = QhtpHarness.snapshot(h.outside);

      await resume();

      expect(QhtpHarness.snapshot(h.outside), before);
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });
  });

  group('a record cannot be used to aim the receiver, even at nothing', () {
    test(
        'a saved name outside the destination that does not exist yet is '
        'ignored, not followed', () async {
      // Nothing is there to be written over, so nothing else would stop it:
      // the name would be taken as free, and a file would be created in a
      // folder the user never chose.
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();
      final planted = p.join(h.outside.path, 'planted.bin');
      File(h.received('a.bin')).deleteSync();
      await editRecord(
        'a.bin',
        (r) => QhtpItemState(
            id: r.id,
            path: r.path,
            size: r.size,
            status: 'pending',
            finalPath: planted),
      );
      final before = QhtpHarness.snapshot(h.outside);

      await resume();

      expect(QhtpHarness.snapshot(h.outside), before,
          reason: 'not a byte, and not a file, outside the destination');
      expect(File(planted).existsSync(), isFalse);
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
    });

    test('a record made for a folder inside this one is not this one\'s',
        () async {
      // The case where "outside the destination" does not rescue it: the
      // earlier destination lies within the new one, so every path in the
      // record is still under the base. It was made for somewhere else.
      await h.serve({'a.bin': a, 'b.bin': b});
      final inner = Directory(p.join(h.target.path, 'inner'))..createSync();
      late QhtpReceiverClient first;
      first = h.client(onRequest: (r) {
        if (r.isFile && r.fileId == h.idOf('b.bin')) first.cancel();
      });
      expectRefused(await first.downloadSession(
          payload: h.payload, targetBaseDir: inner.path));
      final innerCopy =
          File(p.join(inner.path, p.basename(h.source.path), 'a.bin'));
      expect(innerCopy.readAsBytesSync(), a, reason: 'setup');
      h.requests.clear();

      expectReceived(await h
          .client()
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(h.fileRequestsFor('a.bin'), 1,
          reason: 'a.bin was received into inner/, not into this folder');
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
      expect(File(h.received('b.bin')).readAsBytesSync(), b);
    });
  });

  group('cancelling while the files are being re-checked', () {
    test('stops at once, without asking the sender for anything', () async {
      // Large enough to be hashed in a worker, where Cancel has to reach it.
      final big = _bytes(9 * 1024 * 1024, 5);
      await h.serve({'a.bin': big, 'b.bin': b});
      late QhtpReceiverClient first;
      first = h.client(onRequest: (r) {
        if (r.isFile && r.fileId == h.idOf('b.bin')) first.cancel();
      });
      expectRefused(await first.downloadSession(
          payload: h.payload, targetBaseDir: h.target.path));
      h.requests.clear();

      late QhtpReceiverClient second;
      second = h.client();
      final watch = Stopwatch()..start();
      final result = await second.downloadSession(
        payload: h.payload,
        targetBaseDir: h.target.path,
        onProgress: (e) {
          if (e.phase == 'verifying') second.cancel();
        },
      );

      expectRefused(result);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(h.requests.where((r) => r.isFile), isEmpty);
    });
  });

  group('the crash between rename and state save', () {
    /// The state a crash leaves: the file is under its real name, but the
    /// record still says the item is in flight with its name pinned.
    Future<void> forgetCompletion() async {
      final loaded = (await h.store.loadState(h.sessionId))!;
      final item = loaded[h.idOf('a.bin')]!;
      loaded[h.idOf('a.bin')] = QhtpItemState(
        id: item.id,
        path: item.path,
        size: item.size,
        status: 'pending',
        finalPath: item.finalPath,
      );
      await h.store.saveState(
        sessionId: h.sessionId,
        host: '127.0.0.1',
        port: h.payload.port,
        token: h.payload.token,
        baseDir: h.target.path,
        items: loaded,
      );
    }

    test('a whole file with the right digest is adopted, not duplicated',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      await interruptedAfterFirstItem();
      await forgetCompletion();

      await resume();

      expect(h.fileRequestsFor('a.bin'), 0);
      expect(File(h.received('a (1).bin')).existsSync(), isFalse,
          reason: 'no "name (1)" twin of a file that is already whole');
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
    });

    test(
        'an in-flight record is not adopted on its modification time '
        'either', () async {
      // No digest anywhere, and the record even carries the file's time. For
      // a finished record that is evidence enough; for one that was still in
      // flight when the process died it proves nothing about who wrote the
      // file under that name, and the safe duplicate is kept.
      await h.serve({'a.bin': a, 'b.bin': b}, checksums: false);
      late QhtpReceiverClient first;
      first = h.client(
          failDigests: true,
          onRequest: (r) {
            if (r.isFile && r.fileId == h.idOf('b.bin')) first.cancel();
          });
      expectRefused(await first.downloadSession(
          payload: h.payload, targetBaseDir: h.target.path));
      h.requests.clear();
      await editRecord(
        'a.bin',
        (r) => QhtpItemState(
          id: r.id,
          path: r.path,
          size: r.size,
          status: 'pending',
          finalPath: r.finalPath,
          modifiedMs:
              File(r.finalPath!).statSync().modified.millisecondsSinceEpoch,
        ),
      );

      expectReceived(await h
          .client(failDigests: true)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(h.fileRequestsFor('a.bin'), 1);
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });

    test('with no digest anywhere the safe duplicate is kept', () async {
      await h.serve({'a.bin': a, 'b.bin': b}, checksums: false);
      late QhtpReceiverClient first;
      first = h.client(
          failDigests: true,
          onRequest: (r) {
            if (r.isFile && r.fileId == h.idOf('b.bin')) first.cancel();
          });
      expectRefused(await first.downloadSession(
          payload: h.payload, targetBaseDir: h.target.path));
      h.requests.clear();
      await forgetCompletion();

      expectReceived(await h
          .client(failDigests: true)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(File(h.received('a.bin')).readAsBytesSync(), a,
          reason: 'what was there is never touched');
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a,
          reason: 'unprovable, so received again beside it');
    });
  });

  group('no digest anywhere (a big session whose /digest failed)', () {
    /// The record of a finished item with its digest gone, as an older build
    /// or a failed digest lookup leaves it.
    Future<void> dropStoredDigest() async {
      final loaded = (await h.store.loadState(h.sessionId))!;
      final item = loaded[h.idOf('a.bin')]!;
      expect(item.modifiedMs, isNotNull,
          reason: 'completion records the file\'s modification time');
      loaded[h.idOf('a.bin')] = QhtpItemState(
        id: item.id,
        path: item.path,
        size: item.size,
        status: 'completed',
        partialBytes: item.size,
        finalPath: item.finalPath,
        modifiedMs: item.modifiedMs,
      );
      await h.store.saveState(
        sessionId: h.sessionId,
        host: '127.0.0.1',
        port: h.payload.port,
        token: h.payload.token,
        baseDir: h.target.path,
        items: loaded,
      );
    }

    Future<void> interrupted() async {
      late QhtpReceiverClient first;
      first = h.client(
          failDigests: true,
          onRequest: (r) {
            if (r.isFile && r.fileId == h.idOf('b.bin')) first.cancel();
          });
      expectRefused(await first.downloadSession(
          payload: h.payload, targetBaseDir: h.target.path));
      h.requests.clear();
      await dropStoredDigest();
    }

    test('size and an unchanged modification time are accepted, as unverified',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b}, checksums: false);
      await interrupted();

      expectReceived(await h
          .client(failDigests: true)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(h.fileRequestsFor('a.bin'), 0);
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
    });

    test(
        'a file of another size is received again, whatever its '
        'modification time says', () async {
      await h.serve({'a.bin': a, 'b.bin': b}, checksums: false);
      await interrupted();
      final previous =
          (await h.store.loadState(h.sessionId))![h.idOf('a.bin')]!;
      final edited = File(h.received('a.bin'))
        ..writeAsBytesSync([...a, 1, 2, 3])
        ..setLastModifiedSync(
            DateTime.fromMillisecondsSinceEpoch(previous.modifiedMs!));
      // Some platforms round setLastModified to whole seconds. Model a
      // coarse-resolution filesystem by storing the actual resulting time.
      await editRecord('a.bin', (r) => r.copyWith(
          modifiedMs: edited.statSync().modified.millisecondsSinceEpoch));
      final recorded =
          (await h.store.loadState(h.sessionId))![h.idOf('a.bin')]!;
      expect(edited.statSync().modified.millisecondsSinceEpoch,
          recorded.modifiedMs,
          reason: 'the size must be the only evidence that the file changed');
      expect(recorded.sha256, isNull);
      expect(
          h.indexed.manifest.items
              .firstWhere((i) => i.id == recorded.id)
              .sha256,
          isNull);

      expectReceived(await h
          .client(failDigests: true)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(h.fileRequestsFor('a.bin'), 1,
          reason: 'the time is a witness only for a file of the right size');
      expect(edited.readAsBytesSync(), [...a, 1, 2, 3]);
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });

    test('a changed modification time means it is received again', () async {
      await h.serve({'a.bin': a, 'b.bin': b}, checksums: false);
      await interrupted();
      File(h.received('a.bin')).setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 3)));

      expectReceived(await h
          .client(failDigests: true)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(h.fileRequestsFor('a.bin'), 1);
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });

    test('a digest the sender can still give settles it by content', () async {
      await h.serve({'a.bin': a, 'b.bin': b}, checksums: false);
      await interrupted();
      final rotted = Uint8List.fromList(a)..[7] ^= 0x01;
      final original = File(h.received('a.bin')).statSync().modified;
      File(h.received('a.bin'))
        ..writeAsBytesSync(rotted)
        ..setLastModifiedSync(original); // same time, same size, other bytes

      expectReceived(await h
          .client()
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(h.fileRequestsFor('a.bin'), 1,
          reason: 'the sender\'s digest outranks the modification time');
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });
  });

  group('the end of the session', () {
    test('a file that vanishes mid-session is a failure, not a success',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      final client = h.client(onRequest: (r) {
        if (r.isFile && r.fileId == h.idOf('b.bin')) {
          // a.bin is whole and renamed by now; the user drags it away.
          File(h.received('a.bin')).deleteSync();
        }
      });

      final failure = expectRefused(await client.downloadSession(
          payload: h.payload, targetBaseDir: h.target.path));

      expect(failure.code, FailureCode.receivedFilesNotIntact);
      expect(h.completionBody, isNull,
          reason: 'the sender is only told "complete" for a complete receive');
      expect(await h.store.loadState(h.sessionId), isNotNull,
          reason:
              'the record is kept, so a retry only fetches what is missing');

      // And the retry does exactly that.
      h.requests.clear();
      expectReceived(await h
          .client()
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));
      expect(h.fileRequestsFor('a.bin'), 1);
      expect(h.fileRequestsFor('b.bin'), 0);
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
    });

    test('a file that is cut short mid-session is a failure, not a success',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      final client = h.client(onRequest: (r) {
        if (r.isFile && r.fileId == h.idOf('b.bin')) {
          // a.bin is whole and renamed by now; something truncates it.
          final handle =
              File(h.received('a.bin')).openSync(mode: FileMode.append);
          handle.truncateSync(a.length ~/ 2);
          handle.closeSync();
        }
      });

      final failure = expectRefused(await client.downloadSession(
          payload: h.payload, targetBaseDir: h.target.path));

      expect(failure.code, FailureCode.receivedFilesNotIntact);
      expect(h.completionBody, isNull,
          reason: 'the sender is only told "complete" for a complete receive');
    });

    test('a file swapped for a link to a copy is a failure, not a success',
        () async {
      await h.serve({'a.bin': a, 'b.bin': b});
      final copy = File(p.join(h.outside.path, 'copy.bin'))
        ..writeAsBytesSync(a);
      final client = h.client(onRequest: (r) {
        if (r.isFile && r.fileId == h.idOf('b.bin')) {
          File(h.received('a.bin')).deleteSync();
          Link(h.received('a.bin')).createSync(copy.path);
        }
      });

      final failure = expectRefused(await client.downloadSession(
          payload: h.payload, targetBaseDir: h.target.path));

      expect(failure.code, FailureCode.receivedFilesNotIntact,
          reason: 'identical bytes, but behind a link');
      expect(h.completionBody, isNull);
    });

    test('a folder swapped for a link to a copy is a failure, not a success',
        () async {
      await h.serve({'sub/a.bin': a, 'z.bin': b});
      final copyDir = Directory(p.join(h.outside.path, 'sub'))
        ..createSync(recursive: true);
      File(p.join(copyDir.path, 'a.bin')).writeAsBytesSync(a);
      final client = h.client(onRequest: (r) {
        if (r.isFile && r.fileId == h.idOf('z.bin')) {
          Directory(h.received('sub')).deleteSync(recursive: true);
          Link(h.received('sub')).createSync(copyDir.path);
        }
      });

      final failure = expectRefused(await client.downloadSession(
          payload: h.payload, targetBaseDir: h.target.path));

      expect(failure.code, FailureCode.receivedFilesNotIntact,
          reason: 'the file is there, byte for byte, behind a folder link');
      expect(h.completionBody, isNull);
    });

    test('the completion report states what was actually received', () async {
      await h.serve({'a.bin': a, 'b.bin': b});

      expectReceived(await h
          .client()
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      final body = h.completionBody!;
      expect(body['receivedItems'], 2);
      expect(body['receivedBytes'], a.length + b.length);
      expect(body['failedItems'], 0);
    });
  });
}

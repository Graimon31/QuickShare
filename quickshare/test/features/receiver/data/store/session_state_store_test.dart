// sessionId reaches this class straight from `sid` in a scanned QR code or a
// pasted share link — nothing upstream validates it. Every test here is
// about what a hostile sessionId can and cannot do to the filesystem, not
// about the ordinary bookkeeping this class does for a well-behaved one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/features/receiver/data/store/session_state_store.dart';

void main() {
  late Directory root;
  late Directory outside;
  late SessionStateStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_sessionstore_');
    outside = Directory.systemTemp.createTempSync('dd_outside_');
    store = SessionStateStore(storeDirectory: root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (outside.existsSync()) outside.deleteSync(recursive: true);
  });

  QhtpItemState item() => const QhtpItemState(
        id: 'a',
        path: 'a.bin',
        size: 10,
        status: 'partial',
      );

  group('a malicious sessionId cannot escape the store directory', () {
    test('saveState never writes outside the store dir, even with ../', () async {
      final target = File(p.join(outside.path, 'planted.json'));
      final traversal = p.relative(target.path, from: '${root.path}/qhtp_sessions')
          .replaceAll(p.extension(target.path), '');

      await store.saveState(
        sessionId: traversal,
        host: 'h',
        port: 1,
        token: 't',
        baseDir: '/tmp',
        items: {'a': item()},
      );

      expect(target.existsSync(), isFalse,
          reason: 'the crafted id must not have reached $target');
    });

    test('deleteState cannot delete a file elsewhere on disk', () async {
      final planted = File(p.join(outside.path, 'important.json'))
        ..writeAsStringSync('do not touch');

      // The extension is always forced to .json, so the traversal targets
      // the file by its name minus that suffix.
      final withoutExt = planted.path.substring(0, planted.path.length - 5);
      final traversal =
          p.relative(withoutExt, from: '${root.path}/qhtp_sessions');

      await store.deleteState(traversal);

      expect(planted.existsSync(), isTrue,
          reason: 'a file outside the store directory must survive');
      expect(planted.readAsStringSync(), equals('do not touch'));
    });

    test('an absolute path as sessionId is treated as an opaque id, not a path',
        () async {
      // path.join would normally let an absolute second argument replace the
      // base entirely; the sanitizer has to stop that before it reaches join.
      final absoluteLooking = outside.path;

      await store.saveState(
        sessionId: absoluteLooking,
        host: 'h',
        port: 1,
        token: 't',
        baseDir: '/tmp',
        items: {'a': item()},
      );

      final written = Directory('${root.path}/qhtp_sessions').listSync();
      expect(written, hasLength(1),
          reason: 'exactly one file, inside the store directory');
      expect(p.isWithin(root.path, written.single.path), isTrue);
    });

    test('loadState on a traversal id reads nothing, not the real target',
        () async {
      final secret = File(p.join(outside.path, 'secret.json'))
        ..writeAsStringSync('{"items": {"leak": {"status": "completed"}}}');
      final withoutExt = secret.path.substring(0, secret.path.length - 5);
      final traversal =
          p.relative(withoutExt, from: '${root.path}/qhtp_sessions');

      final result = await store.loadState(traversal);

      expect(result, isNull,
          reason: 'nothing was ever legitimately saved under this id');
    });
  });

  group('an ordinary sessionId still works exactly as before', () {
    test('save, load and delete round-trip', () async {
      const id = 'session_1700000000000';

      await store.saveState(
        sessionId: id,
        host: '127.0.0.1',
        port: 8000,
        token: 'tok',
        baseDir: '/tmp/x',
        items: {'a': item()},
      );

      final loaded = await store.loadState(id);
      expect(loaded, isNotNull);
      expect(loaded!['a']!.status, equals('partial'));

      await store.deleteState(id);
      expect(await store.loadState(id), isNull);
    });

    test('two different malicious ids do not collide with each other',
        () async {
      // Determinism matters as much as containment: the same crafted id has
      // to keep mapping to the same (safe) file so resume still finds it,
      // and two different ids must not collapse onto one file.
      await store.saveState(
        sessionId: '../../a',
        host: 'h',
        port: 1,
        token: 't',
        baseDir: '/tmp',
        items: {'a': item()},
      );
      await store.saveState(
        sessionId: '../../b',
        host: 'h',
        port: 1,
        token: 't',
        baseDir: '/tmp',
        items: {'a': item()},
      );

      final written = Directory('${root.path}/qhtp_sessions').listSync();
      expect(written, hasLength(2));
    });
  });

  group('what a resume needs to trust the record', () {
    test('the modification time recorded at completion survives a reload',
        () async {
      await store.saveState(
        sessionId: 'sid',
        host: 'h',
        port: 1,
        token: 't',
        baseDir: '/dest',
        items: {
          'a': const QhtpItemState(
            id: 'a',
            path: 'a.bin',
            size: 10,
            status: 'completed',
            sha256: 'sha256:abc',
            finalPath: '/dest/a.bin',
            modifiedMs: 1700000000123,
          ),
        },
      );

      final loaded = await store.loadState('sid');
      expect(loaded!['a']!.modifiedMs, 1700000000123);
      expect(loaded['a']!.sha256, 'sha256:abc');
    });

    test('a record from before the field existed still loads', () async {
      final dir = Directory(p.join(root.path, 'qhtp_sessions'))..createSync();
      File(p.join(dir.path, 'old.json')).writeAsStringSync(
          '{"sessionId":"old","baseDir":"/d","items":{"a":{"id":"a",'
          '"path":"a.bin","size":3,"status":"completed"}}}');
      final loaded = await store.loadState('old');
      expect(loaded!['a']!.modifiedMs, isNull);
    });

    test('loadSession returns the destination and session it was saved for',
        () async {
      await store.saveState(
        sessionId: 'sid/with:odd chars',
        host: 'h',
        port: 1,
        token: 't',
        baseDir: '/dest',
        items: {'a': item()},
      );
      final saved = await store.loadSession('sid/with:odd chars');
      expect(saved!.sessionId, 'sid/with:odd chars');
      expect(saved.baseDir, '/dest');
      expect(saved.items.keys, ['a']);
    });

    test('loadSession on nothing is null', () async {
      expect(await store.loadSession('never saved'), isNull);
    });

    test('a record is replaced whole, with no scratch file left over',
        () async {
      for (var i = 0; i < 3; i++) {
        await store.saveState(
          sessionId: 'sid',
          host: 'h',
          port: i,
          token: 't',
          baseDir: '/dest',
          items: {'a': item()},
        );
      }
      final names = Directory(p.join(root.path, 'qhtp_sessions'))
          .listSync()
          .map((e) => p.basename(e.path))
          .toList();
      expect(names, ['sid.json']);
    });
  });
}

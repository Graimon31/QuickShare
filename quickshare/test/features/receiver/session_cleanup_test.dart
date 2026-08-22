// The only code in this app that deletes files off the user's disk.
//
// It works from JSON it read back from that same disk, so a bug in parsing or
// path building here does not produce a wrong pixel — it produces a missing
// photo. Every branch below exists because it is a way that could go wrong,
// and the tests run against a real temp directory rather than an in-memory
// filesystem, because the failure modes worth catching are path failures.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/features/receiver/data/store/session_state_store.dart';

void main() {
  late Directory root;
  late Directory downloads;
  late Directory sessions;
  late SessionStateStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('directdrop_cleanup_');
    downloads = Directory(p.join(root.path, 'downloads'))..createSync();
    sessions = Directory(p.join(root.path, 'qhtp_sessions'))..createSync();
    store = SessionStateStore(storeDirectory: root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// Writes a state record and back-dates it so the sweep considers it expired.
  File writeState(
    String sessionId,
    List<Map<String, Object?>> items, {
    Duration age = const Duration(days: 2),
    String? baseDir,
  }) {
    final file = File(p.join(sessions.path, '$sessionId.json'));
    file.writeAsStringSync(jsonEncode({
      'protocolVersion': 1,
      'sessionId': sessionId,
      'host': '192.168.1.10',
      'port': 8000,
      'token': 'tok',
      'baseDir': baseDir ?? downloads.path,
      'updatedAt': DateTime.now().subtract(age).millisecondsSinceEpoch,
      'items': {for (final item in items) item['id'] as String: item},
    }));
    file.setLastModifiedSync(DateTime.now().subtract(age));
    return file;
  }

  Map<String, Object?> item(
    String id,
    String relPath, {
    String status = 'partial',
    String? finalPath,
  }) =>
      {
        'id': id,
        'path': relPath,
        'size': 1024,
        'status': status,
        'partialBytes': 0,
        if (finalPath != null) 'finalPath': finalPath,
      };

  File makeFile(String relPath, {int bytes = 1024}) {
    final file = File(p.join(downloads.path, relPath));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 7));
    return file;
  }

  group('cleanExpiredStates', () {
    test('removes the partials an abandoned session left behind', () async {
      final partialA = makeFile('holiday/one.jpg.qs.partial', bytes: 4096);
      final partialB = makeFile('holiday/two.jpg.qs.partial', bytes: 2048);
      final state = writeState('abandoned', [
        item('000001', 'holiday/one.jpg'),
        item('000002', 'holiday/two.jpg'),
      ]);

      final reclaimed = await store.cleanExpiredStates();

      expect(partialA.existsSync(), isFalse);
      expect(partialB.existsSync(), isFalse);
      expect(state.existsSync(), isFalse, reason: 'the record goes last');
      expect(reclaimed, equals(4096 + 2048));
    });

    test('leaves finished files alone', () async {
      // These are files the user asked for and already has. Deleting them
      // would be the worst outcome this method could produce.
      final finished = makeFile('holiday/done.jpg');
      final partial = makeFile('holiday/pending.jpg.qs.partial');
      writeState('mixed', [
        item('000001', 'holiday/done.jpg',
            status: 'completed', finalPath: finished.path),
        item('000002', 'holiday/pending.jpg'),
      ]);

      await store.cleanExpiredStates();

      expect(finished.existsSync(), isTrue);
      expect(partial.existsSync(), isFalse);
    });

    test('a session still inside its TTL is untouched', () async {
      final partial = makeFile('recent/file.bin.qs.partial');
      final state = writeState('fresh', [item('000001', 'recent/file.bin')],
          age: const Duration(minutes: 5));

      final reclaimed = await store.cleanExpiredStates();

      expect(partial.existsSync(), isTrue,
          reason: 'a transfer paused five minutes ago is still resumable');
      expect(state.existsSync(), isTrue);
      expect(reclaimed, isZero);
    });

    test('refuses a path that escapes the recorded base directory', () async {
      // The record is read back off disk, so it is not trusted input. A path
      // that climbs out of baseDir must be skipped, not followed.
      final outsider = File(p.join(root.path, 'precious.jpg.qs.partial'))
        ..writeAsBytesSync(List<int>.filled(512, 1));
      writeState('malicious', [item('000001', '../precious.jpg')]);

      await store.cleanExpiredStates();

      expect(outsider.existsSync(), isTrue,
          reason: 'the guard must stop a traversal out of baseDir');
    });

    test('refuses an absolute finalPath pointing somewhere else entirely',
        () async {
      final outsider = File(p.join(root.path, 'elsewhere.bin'))
        ..writeAsBytesSync(List<int>.filled(256, 2));
      final decoy = File('${outsider.path}.qs.partial')
        ..writeAsBytesSync(List<int>.filled(256, 3));
      writeState('absolute', [
        item('000001', 'looks/innocent.bin', finalPath: outsider.path),
      ]);

      await store.cleanExpiredStates();

      expect(decoy.existsSync(), isTrue,
          reason: 'finalPath comes from the same untrusted record');
      expect(outsider.existsSync(), isTrue);
    });

    test('a corrupt record is dropped without taking anything with it',
        () async {
      final bystander = makeFile('kept/file.bin.qs.partial');
      final corrupt = File(p.join(sessions.path, 'corrupt.json'))
        ..writeAsStringSync('{ this is not json');
      corrupt.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 2)));

      final reclaimed = await store.cleanExpiredStates();

      expect(corrupt.existsSync(), isFalse);
      expect(bystander.existsSync(), isTrue);
      expect(reclaimed, isZero);
    });

    test('a record with no baseDir deletes nothing', () async {
      final partial = makeFile('orphan/file.bin.qs.partial');
      final state = File(p.join(sessions.path, 'nobase.json'))
        ..writeAsStringSync(jsonEncode({
          'sessionId': 'nobase',
          'items': {
            '000001': item('000001', 'orphan/file.bin'),
          },
        }));
      state.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 2)));

      await store.cleanExpiredStates();

      expect(partial.existsSync(), isTrue,
          reason: 'without a base directory there is nothing to bound against');
    });

    test('survives a store directory that does not exist yet', () async {
      sessions.deleteSync(recursive: true);
      await expectLater(store.cleanExpiredStates(), completion(isZero));
    });

    test('ignores files that are not session records', () async {
      final stray = File(p.join(sessions.path, 'notes.txt'))
        ..writeAsStringSync('hello');
      stray.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 30)));

      await store.cleanExpiredStates();

      expect(stray.existsSync(), isTrue);
    });

    test('a custom TTL is honoured', () async {
      final partial = makeFile('ttl/file.bin.qs.partial');
      writeState('ttl', [item('000001', 'ttl/file.bin')],
          age: const Duration(hours: 2));

      await store.cleanExpiredStates(ttl: const Duration(days: 1));
      expect(partial.existsSync(), isTrue);

      await store.cleanExpiredStates(ttl: const Duration(minutes: 30));
      expect(partial.existsSync(), isFalse);
    });
  });

  group('state round trip', () {
    test('saves and reloads through the injected directory', () async {
      await store.saveState(
        sessionId: 'rt',
        host: '10.0.0.1',
        port: 8000,
        token: 'tok',
        baseDir: downloads.path,
        items: {
          '000001': const QhtpItemState(
              id: '000001', path: 'a.bin', size: 10, status: 'completed'),
        },
      );

      final loaded = await store.loadState('rt');
      expect(loaded, isNotNull);
      expect(loaded!['000001']!.status, equals('completed'));

      await store.deleteState('rt');
      expect(await store.loadState('rt'), isNull);
    });

    test('writes inside the injected directory, not the real app support one',
        () async {
      await store.saveState(
        sessionId: 'isolated',
        host: 'h',
        port: 1,
        token: 't',
        baseDir: downloads.path,
        items: const {},
      );
      expect(File(p.join(sessions.path, 'isolated.json')).existsSync(), isTrue);
    });
  });
}

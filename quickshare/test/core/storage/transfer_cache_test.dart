import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/transfer_cache.dart';

void main() {
  late Directory root;
  late TransferCache cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_cache_test_');
    cache = TransferCache(overrideRoot: () => root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<File> write(String name, int bytes) async {
    final dir = await cache.directory();
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(List<int>.filled(bytes, 7));
    return file;
  }

  test('creates its directory on first use', () async {
    final dir = await cache.directory();
    expect(dir.existsSync(), isTrue);
    expect(p.basename(dir.path), equals('incoming'));
  });

  group('size', () {
    test('is zero when nothing has arrived', () async {
      expect(await cache.size(), equals(0));
    });

    test('adds up every file, including nested ones', () async {
      await write('a.bin', 1000);
      await write('b.bin', 2000);
      final dir = await cache.directory();
      final nested = Directory(p.join(dir.path, 'folder'))..createSync();
      File(p.join(nested.path, 'c.bin')).writeAsBytesSync(List.filled(500, 1));

      expect(await cache.size(), equals(3500));
    });
  });

  group('clear', () {
    test('removes everything and reports what was freed', () async {
      await write('a.bin', 1500);
      await write('b.bin', 2500);

      final freed = await cache.clear();

      expect(freed, equals(4000),
          reason: 'the number is what tells the user something happened');
      expect(await cache.size(), equals(0));
    });

    test('leaves a usable directory behind', () async {
      await write('a.bin', 10);
      await cache.clear();

      // The next transfer must not have to recreate anything.
      final dir = await cache.directory();
      expect(dir.existsSync(), isTrue);
      await write('b.bin', 20);
      expect(await cache.size(), equals(20));
    });

    test('on an empty cache is a harmless no-op', () async {
      expect(await cache.clear(), equals(0));
      expect((await cache.directory()).existsSync(), isTrue);
    });
  });

  group('discard', () {
    test('removes only the named files', () async {
      final keep = await write('keep.bin', 100);
      final drop = await write('drop.bin', 300);

      final freed = await cache.discard([drop.path]);

      expect(freed, equals(300));
      expect(keep.existsSync(), isTrue,
          reason: 'another session may still be waiting on its own decision');
      expect(drop.existsSync(), isFalse);
    });

    test('refuses to touch anything outside the cache', () async {
      // A path from a manifest is attacker-influenced; deleting by it must be
      // bounded by the cache directory no matter what the caller passes.
      final outside = File(p.join(root.path, 'precious.txt'))
        ..writeAsStringSync('do not delete');

      final freed = await cache.discard([outside.path, '/etc/hosts']);

      expect(freed, equals(0));
      expect(outside.existsSync(), isTrue);
    });

    test('a path that is already gone costs nothing', () async {
      final dir = await cache.directory();
      expect(await cache.discard([p.join(dir.path, 'never_existed.bin')]),
          equals(0));
    });
  });

  group('session directories', () {
    test('every session gets one of its own', () async {
      final a = await cache.sessionDirectory();
      final b = await cache.sessionDirectory();

      expect(a.path, isNot(equals(b.path)),
          reason: 'two transfers must not write into the same staging area');
      expect(a.existsSync(), isTrue);
      expect(p.isWithin((await cache.directory()).path, a.path), isTrue,
          reason: 'still inside the cache, so discard will accept it');
    });

    test('itemsIn reports what a session left, top level only', () async {
      final session = await cache.sessionDirectory();
      File(p.join(session.path, 'b.jpg')).writeAsStringSync('12345');
      final folder = Directory(p.join(session.path, 'A trip'))..createSync();
      File(p.join(folder.path, 'inner.mp4')).writeAsStringSync('1234567890');

      final items = TransferCache.itemsIn(session);

      expect(items.map((i) => i.name), equals(['A trip', 'b.jpg']),
          reason: 'sorted by name, and the folder is one item not two');
      expect(items.first.isDirectory, isTrue);
      expect(items.first.size, equals(10), reason: 'the whole tree');
      expect(items.last.isDirectory, isFalse);
      expect(items.last.mimeType, equals('image/jpeg'));
    });

    test('itemsIn on a session that produced nothing is empty', () async {
      expect(TransferCache.itemsIn(await cache.sessionDirectory()), isEmpty);
    });

    test('discarding a session leaves no empty folder behind', () async {
      final session = await cache.sessionDirectory();
      final file = File(p.join(session.path, 'a.bin'))
        ..writeAsStringSync('12345');

      await cache.discard([file.path]);

      expect(session.existsSync(), isFalse,
          reason: 'an empty staging folder still shows up in a storage '
              'breakdown and reads as a leak');
    });

    test('a session still holding something is left alone', () async {
      final session = await cache.sessionDirectory();
      final kept = File(p.join(session.path, 'keep.bin'))
        ..writeAsStringSync('12345');
      final dropped = File(p.join(session.path, 'drop.bin'))
        ..writeAsStringSync('12345');

      await cache.discard([dropped.path]);

      expect(kept.existsSync(), isTrue);
      expect(session.existsSync(), isTrue);
    });

    test('discard removes a whole received folder', () async {
      final session = await cache.sessionDirectory();
      final folder = Directory(p.join(session.path, 'Trip'))..createSync();
      File(p.join(folder.path, 'a.jpg')).writeAsStringSync('x' * 40);
      Directory(p.join(folder.path, 'day 2')).createSync();
      File(p.join(folder.path, 'day 2', 'b.jpg')).writeAsStringSync('y' * 60);

      final freed = await cache.discard([folder.path]);

      expect(freed, equals(100), reason: 'the whole tree counts');
      expect(folder.existsSync(), isFalse);
    });
  });

  group('formatBytes', () {
    test('keeps small sizes in bytes', () {
      expect(TransferCache.formatBytes(0), equals('0 B'));
      expect(TransferCache.formatBytes(999), equals('999 B'));
    });

    test('switches units and drops the decimal once it stops helping', () {
      expect(TransferCache.formatBytes(1536), equals('1.5 KB'));
      expect(TransferCache.formatBytes(5 * 1024 * 1024), equals('5.0 MB'));
      expect(TransferCache.formatBytes(42 * 1024 * 1024), equals('42 MB'));
      expect(TransferCache.formatBytes(3 * 1024 * 1024 * 1024), equals('3.0 GB'));
    });
  });
}

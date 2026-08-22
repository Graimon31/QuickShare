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

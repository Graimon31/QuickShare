import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/received_item.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('dd_received_item_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory makeTree() {
    final trip = Directory(p.join(root.path, 'trip'))..createSync();
    File(p.join(trip.path, 'a.jpg')).writeAsStringSync('12345');
    final day2 = Directory(p.join(trip.path, 'day 2'))..createSync();
    File(p.join(day2.path, 'b.jpg')).writeAsStringSync('1234567890');
    return trip;
  }

  group('treeSizeOf', () {
    test('sums every file in the tree, nested folders included', () async {
      final trip = makeTree();
      expect(await ReceivedItem.treeSizeOf(trip.path), equals(15));
    });

    test('a path that vanished measures as nothing, not an error', () async {
      expect(await ReceivedItem.treeSizeOf(p.join(root.path, 'gone')),
          equals(0));
    });
  });

  group('fromCacheEntity', () {
    test('a directory carries the size of its whole tree', () async {
      final trip = makeTree();

      final item = await ReceivedItem.fromCacheEntity(trip, 'inode/directory');

      expect(item.isDirectory, isTrue);
      expect(item.name, equals('trip'));
      expect(item.size, equals(15));
      expect(item.mimeType, equals('inode/directory'));
    });

    test('a file keeps its own length', () async {
      final file = File(p.join(root.path, 'a.bin'))
        ..writeAsStringSync('1234567');

      final item =
          await ReceivedItem.fromCacheEntity(file, 'application/octet-stream');

      expect(item.isDirectory, isFalse);
      expect(item.size, equals(7));
      expect(item.mimeType, equals('application/octet-stream'));
    });
  });
}

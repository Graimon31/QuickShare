import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/core/storage/durable_file.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('dd_durable_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('DurableFile', () {
    test('writes through a .qs.partial then commits to the final name', () async {
      final finalPath = p.join(root.path, 'video.mp4');
      final f = DurableFile(finalPath);
      await f.open();

      expect(File(f.partialPath).existsSync(), isTrue,
          reason: 'the partial exists the moment writing starts');
      expect(File(finalPath).existsSync(), isFalse,
          reason: 'the final name does not exist until commit');

      await f.add([1, 2, 3]);
      await f.add([4, 5]);
      final committed = await f.commit();

      expect(committed, finalPath);
      expect(File(finalPath).readAsBytesSync(), [1, 2, 3, 4, 5]);
      expect(File(f.partialPath).existsSync(), isFalse,
          reason: 'the partial is gone once renamed');
    });

    test('commit is idempotent', () async {
      final f = DurableFile(p.join(root.path, 'a.bin'));
      await f.open();
      await f.add([9]);
      await f.commit();
      final again = await f.commit();
      expect(again, f.finalPath);
      expect(File(f.finalPath).readAsBytesSync(), [9]);
    });

    test('abort removes the partial and leaves no final file', () async {
      final f = DurableFile(p.join(root.path, 'b.bin'));
      await f.open();
      await f.add([1, 2, 3]);
      await f.abort();

      expect(File(f.partialPath).existsSync(), isFalse);
      expect(File(f.finalPath).existsSync(), isFalse);
    });

    test('abort after a successful commit keeps the final file', () async {
      final f = DurableFile(p.join(root.path, 'c.bin'));
      await f.open();
      await f.add([7, 7]);
      await f.commit();
      await f.abort();

      expect(File(f.finalPath).readAsBytesSync(), [7, 7]);
    });

    test('open truncates a stale partial from a previous attempt', () async {
      final finalPath = p.join(root.path, 'd.bin');
      File('$finalPath$kPartialSuffix').writeAsBytesSync(List.filled(999, 1));

      final f = DurableFile(finalPath);
      await f.open();
      await f.add([2, 2]);
      await f.commit();

      expect(File(finalPath).readAsBytesSync(), [2, 2]);
    });

    test('creates missing parent directories', () async {
      final finalPath = p.join(root.path, 'x', 'y', 'z.bin');
      final f = DurableFile(finalPath);
      await f.open();
      await f.add([1]);
      await f.commit();
      expect(File(finalPath).existsSync(), isTrue);
    });
  });

  group('syncDirectory', () {
    test('does not throw on a real directory', () async {
      await syncDirectory(root.path);
    });

    test('does not throw on a path that is not there', () async {
      await syncDirectory(p.join(root.path, 'nope'));
    });
  });

  group('commitDirectory', () {
    test('renames a staged folder onto its final name atomically', () async {
      final staged = Directory(p.join(root.path, 'Trip$kPartialSuffix'))
        ..createSync(recursive: true);
      File(p.join(staged.path, 'one.jpg')).writeAsBytesSync([1]);
      File(p.join(staged.path, 'sub', 'two.jpg')).createSync(recursive: true);

      final finalPath = p.join(root.path, 'Trip');
      await commitDirectory(staged.path, finalPath);

      expect(Directory(finalPath).existsSync(), isTrue);
      expect(staged.existsSync(), isFalse);
      expect(File(p.join(finalPath, 'one.jpg')).existsSync(), isTrue);
      expect(File(p.join(finalPath, 'sub', 'two.jpg')).existsSync(), isTrue);
    });
  });

  group('sweepPartials', () {
    test('removes stale partial files and folders, keeps the rest', () async {
      final oldFile = File(p.join(root.path, 'a.mp4$kPartialSuffix'))
        ..writeAsBytesSync(List.filled(100, 0));
      final oldDir = Directory(p.join(root.path, 'B$kPartialSuffix'))
        ..createSync();
      File(p.join(oldDir.path, 'inner.bin')).writeAsBytesSync(List.filled(40, 0));

      final keeper = File(p.join(root.path, 'real.mp4'))
        ..writeAsBytesSync(List.filled(10, 0));
      final fresh = File(p.join(root.path, 'live.mp4$kPartialSuffix'))
        ..writeAsBytesSync(List.filled(5, 0));

      final cutoff = DateTime.now().add(const Duration(seconds: 1));
      // Push the "keep" partial's mtime into the future so it counts as fresh.
      fresh.setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));

      final freed = await sweepPartials(root.path, before: cutoff);

      expect(freed, 140);
      expect(oldFile.existsSync(), isFalse);
      expect(oldDir.existsSync(), isFalse);
      expect(keeper.existsSync(), isTrue);
      expect(fresh.existsSync(), isTrue);
    });

    test('returns 0 and does nothing for a missing root', () async {
      final freed =
          await sweepPartials(p.join(root.path, 'gone'), before: DateTime.now());
      expect(freed, 0);
    });
  });
}

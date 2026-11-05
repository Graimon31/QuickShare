import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/utils/app_logger.dart';

import '../../support/links.dart';
import '../../support/open_files.dart';

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

    test('abort while a write is still running closes the handle and removes '
        'the partial', () async {
      // An abort comes from a timer or a dropped connection, not from the
      // code that is writing, so it can land with a write in flight. A handle
      // with an operation pending does not close — the call returns an error
      // and the handle stays open — and on Windows an open partial can be
      // neither deleted nor have its folder removed.
      final f = DurableFile(p.join(root.path, 'busy.bin'));
      await f.open();
      final handle = f.handleForTesting!;
      final write = f.add(Uint8List(48 * 1024 * 1024)); // still running below

      await f.abort();
      await write; // it was waited for, not cancelled
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(handleIsClosed(handle), isTrue,
          reason: 'the close was refused while the write was pending');
      expect(File(f.partialPath).existsSync(), isFalse);
      expect(Directory(root.path).listSync(), isEmpty,
          reason: 'and the folder can be emptied, which an open handle '
              'forbids on Windows');
    });

    test('a second abort, while the first is closing, is harmless', () async {
      final f = DurableFile(p.join(root.path, 'twice.bin'));
      await f.open();
      final handle = f.handleForTesting!;
      final write = f.add(Uint8List(16 * 1024 * 1024));

      await Future.wait([f.abort(), f.abort()]);
      await write;

      expect(handleIsClosed(handle), isTrue);
      expect(File(f.partialPath).existsSync(), isFalse);
    });

    test('a write that comes in after an abort is refused, not made',
        () async {
      final f = DurableFile(p.join(root.path, 'late.bin'));
      await f.open();
      await f.abort();

      expect(() => f.add([1]), throwsStateError);
      expect(File(f.partialPath).existsSync(), isFalse);
    });

    test('abort after a successful commit keeps the final file', () async {
      final f = DurableFile(p.join(root.path, 'c.bin'));
      await f.open();
      await f.add([7, 7]);
      await f.commit();
      await f.abort();

      expect(File(f.finalPath).readAsBytesSync(), [7, 7]);
    });

    // ---- cleaning up after a failure never goes through a link -------------
    //
    // `abort` looked at the last component of the path without following a
    // link and deleted by the whole path. The folders above it were followed
    // like any others, so a folder that had been swapped for a link made the
    // delete land in whatever the link pointed at, on a file that only had to
    // carry the same name.
    group('abort, when a folder above the file is a link', () {
      late Directory dest;
      late Directory outside;

      setUp(() {
        dest = Directory(p.join(root.path, 'dest'))..createSync();
        outside = Directory(p.join(root.path, 'outside'))..createSync();
      });

      Map<String, String> contents(Directory d) => {
            for (final e in d.listSync(recursive: true, followLinks: false))
              p.relative(e.path, from: d.path):
                  e is File ? e.readAsStringSync() : e is Link ? 'link' : 'dir',
          };

      test('a staged partial: what is on the far side of the link survives',
          () async {
        // Never opened, so there is no handle to hold the folder in place and
        // the state is the same on every platform: the chain has a link in it
        // when the delete comes.
        final f = DurableFile(p.join(dest.path, 'sub', 'x.bin'),
            base: dest.path);
        if (!linkOrSkip(p.join(dest.path, 'sub'), outside.path)) return;
        File(p.join(outside.path, 'x.bin$kPartialSuffix'))
            .writeAsStringSync('belongs to somebody else');
        final before = contents(outside);

        await f.abort();

        expect(contents(outside), before,
            reason: 'the delete went through the link and removed a file '
                'outside the destination');
      });

      test('a file inside a staged folder: the same', () async {
        // `staged: false` is how a folder's files are written, straight to
        // their real names inside `Trip.qs.partial/`.
        final f = DurableFile(
            p.join(dest.path, 'Trip.qs.partial', 'sub', 'b.bin'),
            staged: false,
            base: dest.path);
        Directory(p.join(dest.path, 'Trip.qs.partial')).createSync();
        if (!linkOrSkip(
            p.join(dest.path, 'Trip.qs.partial', 'sub'), outside.path)) {
          return;
        }
        File(p.join(outside.path, 'b.bin')).writeAsStringSync('not ours');
        final before = contents(outside);

        await f.abort();

        expect(contents(outside), before);
      });

      test('a folder swapped for a link after the file was opened: the file '
          'stays, and nothing else is touched', () async {
        // Windows refuses to move a folder that holds an open file, so the
        // swap cannot be made to an open partial there; the case above is the
        // portable one, and `windows_native_test.dart` covers junctions.
        if (Platform.isWindows) {
          markTestSkipped('Windows cannot move a folder that holds an open '
              'file, so an open partial cannot be swapped out from under '
              'its writer there');
          return;
        }
        final f = DurableFile(p.join(dest.path, 'sub', 'x.bin'),
            base: dest.path);
        await f.open();
        await f.add([1, 2, 3]);
        Directory(p.join(dest.path, 'sub'))
            .renameSync(p.join(dest.path, 'moved'));
        if (!linkOrSkip(p.join(dest.path, 'sub'), outside.path)) return;
        File(p.join(outside.path, 'x.bin$kPartialSuffix'))
            .writeAsStringSync('belongs to somebody else');
        final before = contents(outside);

        await f.abort();

        expect(contents(outside), before);
        expect(File(p.join(dest.path, 'moved', 'x.bin$kPartialSuffix'))
            .existsSync(), isTrue,
            reason: 'it cannot be reached without going through the link, so '
                'it is left in place rather than removed blind');
      });

      test('says what it left, so the debris can be found', () async {
        final f = DurableFile(p.join(dest.path, 'sub', 'x.bin'),
            base: dest.path);
        if (!linkOrSkip(p.join(dest.path, 'sub'), outside.path)) return;
        File(p.join(outside.path, 'x.bin$kPartialSuffix'))
            .writeAsStringSync('belongs to somebody else');

        await f.abort();

        expect(
            AppLogger.getInMemoryLogs().where((line) =>
                line.contains('[DISK]') &&
                line.contains('x.bin$kPartialSuffix') &&
                line.contains('symbolic link')),
            isNotEmpty,
            reason: 'a file left in place on purpose is written to the log');
      });

      test('does not throw, and does not hide a failure that came first',
          () async {
        final f = DurableFile(p.join(dest.path, 'sub', 'x.bin'),
            base: dest.path);
        if (!linkOrSkip(p.join(dest.path, 'sub'), outside.path)) return;

        // The caller is already reporting an error of its own. A cleanup that
        // throws would replace it with one about the cleanup.
        await expectLater(f.abort(), completes);
      });
    });

    test('abort removes a link that stands where the partial goes — the link, '
        'not what it points at', () async {
      final precious = File(p.join(root.path, 'precious.bin'))
        ..writeAsStringSync('keep me');
      final f = DurableFile(p.join(root.path, 'e.bin'));
      if (!linkOrSkip(f.partialPath, precious.path)) return;

      await f.abort();

      expect(FileSystemEntity.typeSync(f.partialPath, followLinks: false),
          FileSystemEntityType.notFound);
      expect(precious.readAsStringSync(), 'keep me');
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

    test('a link that is named like a partial is not followed', () async {
      final outside = Directory.systemTemp.createTempSync('dd_sweep_outside_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final precious = File(p.join(outside.path, 'precious.bin'))
        ..writeAsBytesSync(List.filled(64, 1));
      Link(p.join(root.path, 'x.mp4$kPartialSuffix')).createSync(outside.path);
      Link(p.join(root.path, 'y.mp4$kPartialSuffix')).createSync(precious.path);

      await sweepPartials(root.path,
          before: DateTime.now().add(const Duration(seconds: 1)));

      expect(precious.existsSync(), isTrue);
      expect(precious.lengthSync(), 64);
      expect(outside.listSync().map((e) => p.basename(e.path)),
          ['precious.bin']);
    });

    test('returns 0 and does nothing for a missing root', () async {
      final freed =
          await sweepPartials(p.join(root.path, 'gone'), before: DateTime.now());
      expect(freed, 0);
    });
  });
}

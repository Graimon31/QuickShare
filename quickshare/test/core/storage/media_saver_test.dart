import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/media_saver.dart';
import 'package:quickshare/core/storage/safe_path.dart';
import 'package:quickshare/core/storage/received_item.dart';

/// Root writes wherever it likes, so a folder's mode bits stop nothing it does.
final bool _isRoot =
    !Platform.isWindows && Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

void main() {
  late Directory workspace;
  late Directory cacheDir;
  late Directory downloads;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('dd_saver_test_');
    cacheDir = Directory(p.join(workspace.path, 'cache'))..createSync();
    downloads = Directory(p.join(workspace.path, 'downloads'))..createSync();
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  ReceivedItem cached(String name, String mime, {String body = 'payload'}) {
    final file = File(p.join(cacheDir.path, name))..writeAsStringSync(body);
    return ReceivedItem(
      cachePath: file.path,
      name: name,
      size: file.lengthSync(),
      mimeType: mime,
    );
  }

  MediaSaver saverWith({
    List<String>? images,
    List<String>? videos,
    bool failGallery = false,
  }) =>
      MediaSaver(
        saveImageHook: (path, {album}) async {
          if (failGallery) throw Exception('gallery is full');
          images?.add(path);
        },
        saveVideoHook: (path, {album}) async {
          if (failGallery) throw Exception('gallery is full');
          videos?.add(path);
        },
        downloadsHook: () async => downloads,
      );

  group('saveToDownloads', () {
    test('copies the file and reports where it landed', () async {
      final item = cached('report.pdf', 'application/pdf', body: 'hello');
      final saved = await saverWith().saveToDownloads(item);

      expect(saved.isSaved, isTrue);
      expect(File(saved.savedPath!).readAsStringSync(), equals('hello'));
      expect(p.dirname(saved.savedPath!), equals(downloads.path));
    });

    test('moves rather than copies when it can', () async {
      // Saving used to copy every byte a second time, and a gigabyte
      // received over Wi-Fi then spent most of a minute being written again
      // while the screen said "saving". Cache and destination are normally
      // the same filesystem, where a rename costs nothing whatever the size.
      //
      // The cache copy was deliberately kept before, so a batch that failed
      // halfway could still be recovered. A move does not weaken that: every
      // item is either at its destination or still in the cache, which is
      // what the next test checks.
      final item = cached('report.pdf', 'application/pdf', body: 'hello');
      final saved = await saverWith().saveToDownloads(item);

      expect(File(saved.savedPath!).readAsStringSync(), equals('hello'));
      expect(File(item.cachePath).existsSync(), isFalse,
          reason: 'the bytes were moved, not duplicated');
    });

    test('a save that fails leaves the cache copy untouched', () async {
      // The recoverability the cache is there for: an item that could not be
      // written anywhere must still exist to be offered again.
      final item = cached('report.pdf', 'application/pdf');

      // The destination is chosen, exists, and is replaced by a file of the
      // same name just before the item is moved into it: nothing can be placed
      // under a file, so the rename fails, the copy that follows it fails too,
      // and neither is allowed to have consumed the source on the way. (Made
      // this way and not by taking permissions away: a read-only folder only
      // refuses writes where the system honours `chmod`, and NTFS does not.)
      final target = Directory(p.join(workspace.path, 'vanishing'))
        ..createSync();
      SafePath.debugRace = (stage, path) {
        if (stage != 'place' || !p.isWithin(target.path, path)) return;
        target.deleteSync(recursive: true);
        File(target.path).writeAsStringSync('not a folder');
      };
      addTearDown(() => SafePath.debugRace = null);

      final saver = MediaSaver(downloadsHook: () async => target);

      await expectLater(
          saver.saveToDownloads(item), throwsA(isA<SaveFailed>()));
      expect(File(item.cachePath).existsSync(), isTrue);
      expect(File(item.cachePath).readAsStringSync(), 'payload');
      expect(FileSystemEntity.isFileSync(target.path), isTrue,
          reason: 'and nothing was made where the folder had been');
    });

    test('a save into a folder the system will not let it write to leaves the '
        'cache copy untouched', () async {
      final item = cached('report.pdf', 'application/pdf');
      final locked = Directory(p.join(workspace.path, 'locked'))..createSync();
      await Process.run('chmod', ['500', locked.path]);
      addTearDown(() => Process.run('chmod', ['700', locked.path]));

      final saver = MediaSaver(downloadsHook: () async => locked);

      await expectLater(
          saver.saveToDownloads(item), throwsA(isA<SaveFailed>()));
      expect(File(item.cachePath).existsSync(), isTrue);
    },
        // Needs `chmod` to keep writes out, and a user who is not root: NTFS
        // ignores it, and root ignores it everywhere. The test above makes the
        // same failure without either.
        skip: Platform.isWindows || _isRoot
            ? 'this system does not stop a write on a folder\'s mode bits'
            : false);

    test('a folder is moved whole, structure intact', () async {
      final tree = Directory(p.join(cacheDir.path, 'trip'))..createSync();
      File(p.join(tree.path, 'a.txt')).writeAsStringSync('one');
      Directory(p.join(tree.path, 'sub')).createSync();
      File(p.join(tree.path, 'sub', 'b.txt')).writeAsStringSync('two');

      final saved = await saverWith().saveToDownloads(ReceivedItem(
        cachePath: tree.path,
        name: 'trip',
        size: 0,
        mimeType: 'inode/directory',
        isDirectory: true,
      ));

      expect(File(p.join(saved.savedPath!, 'a.txt')).readAsStringSync(),
          equals('one'));
      expect(File(p.join(saved.savedPath!, 'sub', 'b.txt')).readAsStringSync(),
          equals('two'));
      expect(Directory(tree.path).existsSync(), isFalse);
    });

    test('never overwrites a file already there', () async {
      File(p.join(downloads.path, 'report.pdf'))
          .writeAsStringSync('the original');

      final saved =
          await saverWith().saveToDownloads(cached('report.pdf', 'application/pdf'));

      expect(p.basename(saved.savedPath!), equals('report (1).pdf'));
      expect(File(p.join(downloads.path, 'report.pdf')).readAsStringSync(),
          equals('the original'));
    });
  });

  group('saving never goes through a link', () {
    test('a dangling link at the name is a taken name, not a hole', () async {
      final ghost = File(p.join(workspace.path, 'ghost.pdf'));
      Link(p.join(downloads.path, 'report.pdf')).createSync(ghost.path);

      final saved = await saverWith()
          .saveToDownloads(cached('report.pdf', 'application/pdf'));

      expect(ghost.existsSync(), isFalse,
          reason: 'moving "onto" a dangling link would have created its target');
      expect(p.basename(saved.savedPath!), 'report (1).pdf');
      expect(File(saved.savedPath!).readAsStringSync(), 'payload');
    });

    test('a folder is never moved onto a link or an empty folder', () async {
      final folder = Directory(p.join(cacheDir.path, 'Trip'))..createSync();
      File(p.join(folder.path, 'one.jpg')).writeAsStringSync('1');
      final item = ReceivedItem(
        cachePath: folder.path,
        name: 'Trip',
        size: 1,
        mimeType: 'inode/directory',
        isDirectory: true,
      );
      Directory(p.join(downloads.path, 'Trip')).createSync();

      final saved = await saverWith().saveToDownloads(item);

      expect(p.basename(saved.savedPath!), 'Trip (1)');
      expect(Directory(p.join(downloads.path, 'Trip')).listSync(), isEmpty);
      expect(File(p.join(saved.savedPath!, 'one.jpg')).readAsStringSync(), '1');
    });
  });

  group('a name taken while the item is being placed', () {
    // The name is picked, and then the item is moved onto it. In between,
    // another program can put something there — and a plain move would
    // replace it without a word. `debugRace` is how a test is that program.
    tearDown(() => SafePath.debugRace = null);

    test('a file that appeared there is kept, and the item goes beside it',
        () async {
      final target = p.join(downloads.path, 'report.pdf');
      SafePath.debugRace = (stage, path) {
        if (stage == 'place' && path == target) {
          File(target).writeAsStringSync('arrived meanwhile');
        }
      };

      final saved = await saverWith()
          .saveToDownloads(cached('report.pdf', 'application/pdf'));

      expect(File(target).readAsStringSync(), 'arrived meanwhile',
          reason: 'something the user did not know about was replaced');
      expect(p.basename(saved.savedPath!), 'report (1).pdf');
      expect(File(saved.savedPath!).readAsStringSync(), 'payload');
    });

    test('a folder that appeared there is kept, and the item goes beside it',
        () async {
      final folder = Directory(p.join(cacheDir.path, 'Trip'))..createSync();
      File(p.join(folder.path, 'one.jpg')).writeAsStringSync('1');
      final item = ReceivedItem(
        cachePath: folder.path,
        name: 'Trip',
        size: 1,
        mimeType: 'inode/directory',
        isDirectory: true,
      );
      final target = p.join(downloads.path, 'Trip');
      SafePath.debugRace = (stage, path) {
        if (stage == 'place' && path == target) {
          Directory(target).createSync();
        }
      };

      final saved = await saverWith().saveToDownloads(item);

      expect(Directory(target).listSync(), isEmpty,
          reason: 'the empty folder somebody just made is theirs, and a '
              'plain rename replaces an empty folder without a word');
      expect(p.basename(saved.savedPath!), 'Trip (1)');
      expect(File(p.join(saved.savedPath!, 'one.jpg')).readAsStringSync(), '1');
    });
  });

  group('saveToGallery', () {
    test('a photo goes through the image path', () async {
      final images = <String>[];
      final videos = <String>[];
      final item = cached('IMG_1.HEIC', 'image/heic');

      await saverWith(images: images, videos: videos).saveToGallery(item);

      expect(images, equals([item.cachePath]));
      expect(videos, isEmpty);
    });

    test('a video goes through the video path', () async {
      // Photos and videos take different platform calls; guessing wrong fails
      // at the OS level rather than here.
      final images = <String>[];
      final videos = <String>[];
      final item = cached('clip.mp4', 'video/mp4');

      await saverWith(images: images, videos: videos).saveToGallery(item);

      expect(videos, equals([item.cachePath]));
      expect(images, isEmpty);
    });

    test('a video is recognised by extension when the MIME type is generic',
        () async {
      final videos = <String>[];
      await saverWith(videos: videos)
          .saveToGallery(cached('holiday.mov', 'application/octet-stream'));
      expect(videos, hasLength(1));
    });

    test('a failure names the item so a batch can report which one', () async {
      final item = cached('IMG_2.jpg', 'image/jpeg');
      await expectLater(
        saverWith(failGallery: true).saveToGallery(item),
        throwsA(isA<SaveFailed>()
            .having((e) => e.item.name, 'item name', 'IMG_2.jpg')),
      );
    });
  });

  group('saveTo', () {
    test('copies into a directory the user chose, creating it if needed',
        () async {
      final target = p.join(workspace.path, 'chosen', 'nested');
      final saved =
          await saverWith().saveTo(cached('a.bin', 'application/octet-stream'), target);

      expect(File(saved.savedPath!).existsSync(), isTrue);
      expect(p.dirname(saved.savedPath!), equals(target));
    });
  });

  group('folders', () {
    Future<ReceivedItem> cachedFolder(String name) async {
      final folder = Directory(p.join(cacheDir.path, name))
        ..createSync(recursive: true);
      File(p.join(folder.path, 'top.txt')).writeAsStringSync('a');
      final nested = Directory(p.join(folder.path, 'day 2'))..createSync();
      File(p.join(nested.path, 'deep.txt')).writeAsStringSync('bb');
      return ReceivedItem.fromCacheEntity(folder, 'inode/directory');
    }

    test('a received folder is copied whole, structure and all', () async {
      // QHTP sends whatever the sender picked; a folder arrives as a folder
      // and has to leave as one.
      final target = p.join(workspace.path, 'chosen');
      final saved = await saverWith().saveTo(await cachedFolder('Trip'), target);

      expect(Directory(saved.savedPath!).existsSync(), isTrue);
      expect(File(p.join(saved.savedPath!, 'top.txt')).existsSync(), isTrue);
      expect(File(p.join(saved.savedPath!, 'day 2', 'deep.txt')).existsSync(),
          isTrue);
    });

    test('a folder goes to Downloads like anything else', () async {
      final saved = await saverWith().saveToDownloads(await cachedFolder('Trip'));

      expect(Directory(saved.savedPath!).existsSync(), isTrue);
      expect(p.dirname(saved.savedPath!), equals(downloads.path));
    });

    test('an existing folder of the same name is never written into',
        () async {
      Directory(p.join(downloads.path, 'Trip')).createSync();
      File(p.join(downloads.path, 'Trip', 'mine.txt')).writeAsStringSync('!');

      final saved = await saverWith().saveToDownloads(await cachedFolder('Trip'));

      expect(p.basename(saved.savedPath!), equals('Trip (1)'));
      expect(File(p.join(downloads.path, 'Trip', 'mine.txt')).existsSync(),
          isTrue, reason: 'the folder that was already there is untouched');
    });
  });
}

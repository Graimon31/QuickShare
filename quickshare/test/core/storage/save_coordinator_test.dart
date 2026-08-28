import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/media_saver.dart';
import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/storage/save_coordinator.dart';
import 'package:quickshare/core/storage/gallery_formats.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/save_location_bookmark.dart';
import 'package:quickshare/core/storage/save_location_store.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';

/// A stand-in for the native macOS bookmark bridge, which has nothing to
/// answer platform-channel calls under `flutter test`. These tests are about
/// whether the coordinator *uses* a configured location, not about the
/// bookmark mechanics themselves — those have their own test file.
class _FakeBookmark extends SaveLocationBookmark {
  final Map<String, String> _bookmarks = {};

  @override
  Future<String> create(String path) async {
    final token = 'bookmark-for:$path';
    _bookmarks[path] = token;
    return token;
  }

  @override
  Future<BookmarkAccess> startAccessing(String bookmark) async {
    final entry = _bookmarks.entries.firstWhere((e) => e.value == bookmark);
    return BookmarkAccess(path: entry.key, stale: false);
  }

  @override
  Future<void> stopAccessing() async {}
}

void main() {
  late Directory root;
  late Directory downloads;
  late TransferCache cache;
  late List<String> galleryWrites;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_coord_test_');
    downloads = Directory(p.join(root.path, 'downloads'))..createSync();
    cache = TransferCache(overrideRoot: () => root);
    galleryWrites = [];
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<ReceivedItem> cached(String name, String mime) async {
    final dir = await cache.directory();
    final file = File(p.join(dir.path, name))..writeAsStringSync('bytes');
    return ReceivedItem.fromCacheFile(file, mime);
  }

  MediaSaver saver({bool galleryFails = false}) => MediaSaver(
        saveImageHook: (path, {album}) async {
          if (galleryFails) throw Exception('library is full');
          galleryWrites.add(path);
        },
        saveVideoHook: (path, {album}) async {
          if (galleryFails) throw Exception('library is full');
          galleryWrites.add(path);
        },
        downloadsHook: () async => downloads,
      );

  SaveCoordinator coordinator({
    required bool isDesktop,
    bool galleryFails = false,
  }) =>
      SaveCoordinator(
        destination: SaveDestination(
          isDesktop: isDesktop,
          gallery: const GalleryFormats(GalleryPlatform.ios),
        ),
        saver: saver(galleryFails: galleryFails),
        cache: cache,
        // Points at the test's own scratch directory rather than the real
        // path_provider channel `flutter test` has no handler for. These
        // tests are not about the save-location feature — that has its own
        // test file — so a scratch dir with nothing ever set in it is all
        // that is needed to keep this quiet and inert.
        saveLocation: SaveLocationStore(overrideDir: () => root),
      );

  group('on desktop', () {
    test('everything is written out and nothing is asked about', () async {
      final items = [
        await cached('photo.jpg', 'image/jpeg'),
        await cached('report.pdf', 'application/pdf'),
      ];

      final outcomes = await coordinator(isDesktop: true).runAutomatic(items);

      expect(outcomes.every((o) => o.item.isSaved), isTrue);
      expect(outcomes.any((o) => o.awaitingDecision), isFalse);
      expect(galleryWrites, isEmpty, reason: 'desktop has no photo library');
      expect(Directory(downloads.path).listSync(), hasLength(2));
    });
  });

  group('on mobile', () {
    test('photos go to the gallery, documents wait for an answer', () async {
      final items = [
        await cached('IMG_1.HEIC', 'image/heic'),
        await cached('clip.mp4', 'video/mp4'),
        await cached('contract.pdf', 'application/pdf'),
      ];

      final outcomes = await coordinator(isDesktop: false).runAutomatic(items);

      expect(galleryWrites, hasLength(2));
      final pending = outcomes.where((o) => o.awaitingDecision).toList();
      expect(pending, hasLength(1));
      expect(pending.single.item.name, equals('contract.pdf'));
      expect(pending.single.item.isSaved, isFalse);
    });

    test('one failed photo does not stop the rest of the batch', () async {
      // Nineteen of twenty should still arrive.
      final items = [
        for (var i = 0; i < 3; i++) await cached('IMG_$i.jpg', 'image/jpeg'),
      ];

      final outcomes =
          await coordinator(isDesktop: false, galleryFails: true)
              .runAutomatic(items);

      expect(outcomes, hasLength(3));
      expect(outcomes.every((o) => o.failed), isTrue);
      expect(outcomes.map((o) => o.item.name),
          equals(['IMG_0.jpg', 'IMG_1.jpg', 'IMG_2.jpg']),
          reason: 'a failure has to name which item it was');
    });

    test('a photo the gallery refused is still offered somewhere to go',
        () async {
      // Reporting "could not be saved" and then deleting the cache copy on
      // the way out loses the file outright. The library refusing it says
      // nothing about whether the user wants it.
      final items = [await cached('IMG_0.jpg', 'image/jpeg')];

      final outcomes = await coordinator(isDesktop: false, galleryFails: true)
          .runAutomatic(items);

      expect(outcomes.single.failed, isTrue, reason: 'the reason is not hidden');
      expect(outcomes.single.awaitingDecision, isTrue,
          reason: 'and it can still be saved by hand');
    });

    test('a format the gallery would refuse is never handed to it', () async {
      // The gallery is asked only about formats it stores, so this asks
      // instead of failing and recovering.
      final items = [await cached('movie.avi', 'video/x-msvideo')];

      final outcomes = await coordinator(isDesktop: false).runAutomatic(items);

      expect(galleryWrites, isEmpty);
      expect(outcomes.single.failed, isFalse);
      expect(outcomes.single.awaitingDecision, isTrue);
    });
  });

  group('saveChosen', () {
    test('copies into the directory the user picked', () async {
      final target = Directory(p.join(root.path, 'picked'))..createSync();
      final item = await cached('contract.pdf', 'application/pdf');

      final outcomes = await coordinator(isDesktop: false)
          .saveChosen([item], target.path);

      expect(outcomes.single.item.isSaved, isTrue);
      expect(File(p.join(target.path, 'contract.pdf')).existsSync(), isTrue);
    });
  });

  group('discardSession', () {
    test('clears the staging area, saved and abandoned alike', () async {
      final saved = (await cached('photo.jpg', 'image/jpeg'))
          .copyWith(savedPath: '/somewhere/photo.jpg');
      final abandoned = await cached('contract.pdf', 'application/pdf');

      final freed = await coordinator(isDesktop: false).discardSession([
        SaveOutcome(item: saved),
        SaveOutcome(item: abandoned, awaitingDecision: true),
      ]);

      expect(freed, greaterThan(0));
      expect(File(abandoned.cachePath).existsSync(), isFalse,
          reason: 'declined, so nobody wants it');
      expect(File(saved.cachePath).existsSync(), isFalse,
          reason: 'the user has this file somewhere permanent already; a '
              'second copy in the cache is what makes the app grow');
    });

    test('a session with nothing in it frees nothing', () async {
      expect(
        await coordinator(isDesktop: true).discardSession(const []),
        equals(0),
      );
    });

    test('a received folder goes as a whole', () async {
      // QHTP can deliver a tree, and discarding it one leaf at a time would
      // leave the structure behind.
      final folder = Directory(p.join((await cache.directory()).path, 'Trip'))
        ..createSync(recursive: true);
      File(p.join(folder.path, 'a.jpg')).writeAsStringSync('x' * 100);
      Directory(p.join(folder.path, 'nested')).createSync();
      File(p.join(folder.path, 'nested', 'b.jpg')).writeAsStringSync('y' * 50);

      final freed = await coordinator(isDesktop: false).discardSession([
        SaveOutcome(
          item: ReceivedItem.fromCacheEntity(folder, 'inode/directory'),
        ),
      ]);

      expect(freed, equals(150));
      expect(folder.existsSync(), isFalse);
    });
  });

  group('a chosen save location', () {
    test('automatic items land there instead of the platform default',
        () async {
      final chosen = Directory(p.join(root.path, 'chosen_folder'))
        ..createSync();
      final location =
          SaveLocationStore(overrideDir: () => root, bookmark: _FakeBookmark());
      await location.set(chosen.path);

      final items = [await cached('report.pdf', 'application/pdf')];
      final outcomes = await SaveCoordinator(
        destination: const SaveDestination(
          isDesktop: true,
          gallery: GalleryFormats(GalleryPlatform.ios),
        ),
        saver: saver(),
        cache: cache,
        saveLocation: location,
      ).runAutomatic(items);

      expect(outcomes.single.item.isSaved, isTrue);
      expect(p.dirname(outcomes.single.item.savedPath!), equals(chosen.path),
          reason: 'the configured folder, not the downloadsHook default');
      expect(Directory(downloads.path).listSync(), isEmpty,
          reason: 'the platform default was never touched');
    });

    test('gallery items on mobile ignore it — there is no gallery folder to '
        'redirect', () async {
      final chosen = Directory(p.join(root.path, 'chosen_folder'))
        ..createSync();
      final location =
          SaveLocationStore(overrideDir: () => root, bookmark: _FakeBookmark());
      await location.set(chosen.path);

      // isDesktop: false — SaveDestination.intentFor never returns
      // .automatic here, so the location is never even consulted.
      final items = [await cached('clip.mp4', 'video/mp4')];
      await SaveCoordinator(
        destination: const SaveDestination(
          isDesktop: false,
          gallery: GalleryFormats(GalleryPlatform.ios),
        ),
        saver: saver(),
        cache: cache,
        saveLocation: location,
      ).runAutomatic(items);

      expect(galleryWrites, hasLength(1),
          reason: 'still went to the gallery, unaffected by the setting');
    });
  });
}

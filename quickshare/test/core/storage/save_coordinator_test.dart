import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/media_saver.dart';
import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/storage/save_coordinator.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';

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
        destination: SaveDestination(isDesktop: isDesktop),
        saver: saver(galleryFails: galleryFails),
        cache: cache,
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

  group('discardUnsaved', () {
    test('removes what was never saved and keeps what was', () async {
      final saved = (await cached('photo.jpg', 'image/jpeg'))
          .copyWith(savedPath: '/somewhere/photo.jpg');
      final abandoned = await cached('contract.pdf', 'application/pdf');

      final freed = await coordinator(isDesktop: false).discardUnsaved([
        SaveOutcome(item: saved),
        SaveOutcome(item: abandoned, awaitingDecision: true),
      ]);

      expect(freed, greaterThan(0));
      expect(File(abandoned.cachePath).existsSync(), isFalse);
      expect(File(saved.cachePath).existsSync(), isTrue,
          reason: 'a saved item is finished with, not garbage');
    });

    test('a session where everything was saved frees nothing', () async {
      final saved = (await cached('a.jpg', 'image/jpeg'))
          .copyWith(savedPath: '/somewhere/a.jpg');
      expect(
        await coordinator(isDesktop: true).discardUnsaved([SaveOutcome(item: saved)]),
        equals(0),
      );
    });
  });
}

// Does the placement rule actually behave on real hardware?
//
// Everything about where a received file goes is decided from three things
// that a `flutter test` run cannot tell the truth about: which platform this
// is, where the OS puts a cache directory, and whether that directory can be
// written to. Unit tests fake all three. This runs the same code on the real
// device:
//
//     flutter test integration_test/device_storage_placement_test.dart -d macos
//     flutter test integration_test/device_storage_placement_test.dart -d <iphone-id>
//
// One file per invocation on macOS: two integration_test files in a single
// `flutter test` call fail the second app launch with "Unable to start the
// app on the device".
//
// The one thing deliberately not exercised is the actual write into the photo
// library: it would leave a test image in the user's camera roll. The gallery
// call is stubbed, and what is checked is that the rule *asks* for it — which
// is the part that was broken.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/storage/gallery_formats.dart';
import 'package:quickshare/core/storage/media_saver.dart';
import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/storage/save_coordinator.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const cache = TransferCache();
  final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  // Anything this test stages is torn down again, so a run leaves the device
  // exactly as it found it.
  final staged = <String>[];
  tearDown(() async {
    await cache.discard(staged);
    staged.clear();
  });

  Future<Directory> session() async {
    final dir = await cache.sessionDirectory();
    staged.add(dir.path);
    return dir;
  }

  File stage(Directory session, String name, {int bytes = 4096}) {
    final file = File(p.join(session.path, name))
      ..writeAsBytesSync(List<int>.filled(bytes, 0x41));
    return file;
  }

  testWidgets('the cache is a real, writable directory on this device',
      (tester) async {
    final dir = await cache.directory();
    print('cache directory on ${Platform.operatingSystem}: ${dir.path}');

    expect(dir.existsSync(), isTrue);

    final probe = File(p.join(dir.path, 'probe.bin'))
      ..writeAsBytesSync(const [1, 2, 3]);
    expect(probe.readAsBytesSync(), equals([1, 2, 3]),
        reason: 'iOS used to write received files into Documents because the '
            'sandbox has no Downloads; the cache has to be writable there');
    probe.deleteSync();
  });

  testWidgets('session directories are unique, contained, and swept up',
      (tester) async {
    final a = await session();
    final b = await session();

    expect(a.path, isNot(equals(b.path)));
    expect(p.isWithin((await cache.directory()).path, a.path), isTrue);

    final file = stage(a, 'thing.bin');
    await cache.discard([file.path]);
    expect(a.existsSync(), isFalse,
        reason: 'an emptied session folder should not linger in storage');
  });

  testWidgets('itemsIn describes a real session off the filesystem',
      (tester) async {
    final dir = await session();
    stage(dir, 'photo.heic', bytes: 1024);
    final folder = Directory(p.join(dir.path, 'Trip'))..createSync();
    File(p.join(folder.path, 'clip.mov'))
        .writeAsBytesSync(List<int>.filled(2048, 0x42));

    final items = TransferCache.itemsIn(dir);

    expect(items.map((i) => i.name), equals(['photo.heic', 'Trip']),
        reason: 'sorted by name, and the folder counts as one item');
    expect(items.last.isDirectory, isTrue);
    expect(items.last.size, equals(2048), reason: 'the whole tree');
    expect(items.first.size, equals(1024));
  });

  testWidgets('this platform is recognised, and judges formats accordingly',
      (tester) async {
    final gallery = GalleryFormats.forCurrentPlatform();
    print('gallery platform: ${gallery.platform}');

    if (Platform.isIOS) {
      expect(gallery.platform, equals(GalleryPlatform.ios));
    } else if (Platform.isAndroid) {
      expect(gallery.platform, equals(GalleryPlatform.android));
    } else {
      expect(gallery.platform, equals(GalleryPlatform.none),
          reason: 'desktop has no photo library; everything goes to Downloads');
    }
  });

  testWidgets('the placement rule reaches the right verdict here',
      (tester) async {
    final destination = SaveDestination.forCurrentPlatform();
    final dir = await session();

    ReceivedItem item(String name, String mime) =>
        ReceivedItem.fromCacheFile(stage(dir, name), mime);

    final photo = item('IMG_0001.HEIC', 'image/heic');
    final video = item('clip.mov', 'video/quicktime');
    final document = item('contract.pdf', 'application/pdf');
    final oddVideo = item('movie.avi', 'video/x-msvideo');

    if (isDesktop) {
      for (final i in [photo, video, document, oddVideo]) {
        expect(destination.intentFor(i), equals(SaveIntent.automatic),
            reason: '${i.name} should land in Downloads without a prompt');
      }
      expect(destination.anyNeedsAsking([photo, document]), isFalse);
    } else {
      expect(destination.intentFor(photo), equals(SaveIntent.gallery));
      expect(destination.intentFor(video), equals(SaveIntent.gallery));
      expect(destination.intentFor(document), equals(SaveIntent.ask));
      expect(destination.intentFor(oddVideo), equals(SaveIntent.ask),
          reason: 'Photos refuses .avi, so asking beats a write that throws');
      expect(destination.anyNeedsAsking([photo, video]), isFalse,
          reason: 'a phone should never interrupt a pure photo transfer');
    }
  });

  testWidgets('a finished session is placed and then cleared', (tester) async {
    final dir = await session();
    // Outside the cache: a saved copy that lands *inside* it would keep
    // being counted as cache and mask the very thing under test.
    final downloads = Directory.systemTemp.createTempSync('dd_dl_');
    addTearDown(() {
      if (downloads.existsSync()) downloads.deleteSync(recursive: true);
    });
    final galleryWrites = <String>[];

    final coordinator = SaveCoordinator(
      destination: SaveDestination.forCurrentPlatform(),
      cache: cache,
      saver: MediaSaver(
        // Stubbed: a real write would leave a test image in the camera roll.
        saveImageHook: (path, {album}) async => galleryWrites.add(path),
        saveVideoHook: (path, {album}) async => galleryWrites.add(path),
        downloadsHook: () async => downloads,
      ),
    );

    final items = [
      ReceivedItem.fromCacheFile(stage(dir, 'IMG_0002.HEIC'), 'image/heic'),
      ReceivedItem.fromCacheFile(stage(dir, 'notes.pdf'), 'application/pdf'),
    ];
    final before = await cache.size();

    final outcomes = await coordinator.runAutomatic(items);

    if (isDesktop) {
      expect(outcomes.every((o) => o.item.isSaved), isTrue);
      expect(galleryWrites, isEmpty);
      expect(downloads.listSync(), hasLength(2));
    } else {
      expect(galleryWrites, hasLength(1), reason: 'the photo, and only it');
      expect(outcomes.where((o) => o.awaitingDecision).map((o) => o.item.name),
          equals(['notes.pdf']), reason: 'the document is the only question');
    }

    // Walking away has to actually give the space back: this is what the
    // "Clear cache" number in settings is measuring.
    await coordinator.discardSession(outcomes);
    expect(await cache.size(), lessThan(before));
    for (final item in items) {
      expect(File(item.cachePath).existsSync(), isFalse);
    }
  });

  testWidgets('a received folder is saved whole and discarded whole',
      (tester) async {
    final dir = await session();
    final folder = Directory(p.join(dir.path, 'Trip'))..createSync();
    File(p.join(folder.path, 'a.jpg')).writeAsBytesSync([1, 2, 3]);
    Directory(p.join(folder.path, 'day 2')).createSync();
    File(p.join(folder.path, 'day 2', 'b.jpg')).writeAsBytesSync([4, 5]);

    final item = ReceivedItem.fromCacheEntity(folder, 'inode/directory');
    expect(GalleryFormats.forCurrentPlatform().accepts(item), isFalse,
        reason: 'no photo library takes a directory');

    final target = Directory(p.join(dir.path, '_picked'))..createSync();
    final saved = await const MediaSaver().saveTo(item, target.path);

    expect(File(p.join(saved.savedPath!, 'a.jpg')).existsSync(), isTrue);
    expect(File(p.join(saved.savedPath!, 'day 2', 'b.jpg')).existsSync(),
        isTrue, reason: 'the structure the sender chose survives the save');

    await cache.discard([folder.path]);
    expect(folder.existsSync(), isFalse);
  });

  testWidgets('clearing the cache frees what settings said it would',
      (tester) async {
    final dir = await session();
    stage(dir, 'big.bin', bytes: 512 * 1024);

    final measured = await cache.size();
    expect(measured, greaterThanOrEqualTo(512 * 1024));

    final freed = await cache.clear();
    expect(freed, equals(measured),
        reason: 'the number shown to the user has to be the number freed');
    expect(await cache.size(), equals(0));

    // clear() removed the tree; nothing left for teardown to discard.
    staged.clear();
  });

  testWidgets('the desktop download directory resolves on this platform',
      (tester) async {
    if (!isDesktop) {
      // iOS has no Downloads inside the sandbox, which is the whole reason
      // the phone asks instead of writing.
      return;
    }
    final downloads = await getDownloadsDirectory();
    print('downloads directory: ${downloads?.path}');
    expect(downloads, isNotNull);
    expect(downloads!.existsSync(), isTrue);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:quickshare/core/storage/gallery_formats.dart';
import 'package:quickshare/core/storage/receive_destination.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/save_location_bookmark.dart';
import 'package:quickshare/core/storage/save_location_store.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';

class _FakeBookmark extends SaveLocationBookmark {
  final Map<String, String> _bookmarks = {};
  bool stopCalled = false;
  bool failStart = false;

  @override
  Future<String> create(String path) async {
    final token = 'bm:$path';
    _bookmarks[path] = token;
    return token;
  }

  @override
  Future<BookmarkAccess> startAccessing(String bookmark) async {
    if (failStart) throw const SaveLocationBookmarkException('unavailable');
    final entry = _bookmarks.entries.firstWhere((e) => e.value == bookmark);
    return BookmarkAccess(path: entry.key, stale: false);
  }

  @override
  Future<void> stopAccessing() async {
    stopCalled = true;
  }
}

class _ScratchPaths extends PathProviderPlatform {
  _ScratchPaths(this.root);
  final Directory root;

  Future<String> _dir(String name) async =>
      (Directory(p.join(root.path, name))..createSync(recursive: true)).path;

  @override
  Future<String?> getDownloadsPath() => _dir('downloads');
  @override
  Future<String?> getApplicationSupportPath() => _dir('support');
  @override
  Future<String?> getApplicationDocumentsPath() => _dir('documents');
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('dd_recvdest_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a phone lands in a fresh transfer-cache session, not placed', () async {
    final cache = TransferCache(overrideRoot: () => root);
    final dest = await ReceiveDestination.resolve(
      destination: const SaveDestination(
          isDesktop: false, gallery: GalleryFormats(GalleryPlatform.ios)),
      cache: cache,
    );

    expect(dest.placed, isFalse);
    expect(p.isWithin(root.path, dest.path), isTrue);
    expect(Directory(dest.path).existsSync(), isTrue);
    await dest.release(); // no-op, must not throw
  });

  test('desktop with a chosen folder writes straight into it, placed', () async {
    final chosen = Directory(p.join(root.path, 'MyDrop'))..createSync();
    final bookmark = _FakeBookmark();
    final store = SaveLocationStore(
        overrideDir: () => Directory(p.join(root.path, 'support')),
        bookmark: bookmark);
    await store.set(chosen.path);

    final dest = await ReceiveDestination.resolve(
      destination: const SaveDestination(
          isDesktop: true, gallery: GalleryFormats(GalleryPlatform.none)),
      saveLocation: store,
    );

    expect(dest.placed, isTrue);
    expect(dest.path, chosen.path);

    await dest.release();
    // On a platform with bookmark support the scope is closed; elsewhere the
    // release is simply a no-op. Either way it must not throw.
    if (SaveLocationBookmark.isSupported) {
      expect(bookmark.stopCalled, isTrue);
    }
  });

  test('an unavailable bookmark falls back for this receive and keeps the choice',
      () async {
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _ScratchPaths(root);
    addTearDown(() => PathProviderPlatform.instance = paths);
    final chosen = Directory(p.join(root.path, 'chosen'))..createSync();
    final bookmark = _FakeBookmark();
    final store = SaveLocationStore(
      overrideDir: () => Directory(p.join(root.path, 'settings')),
      bookmark: bookmark,
    );
    await store.set(chosen.path);
    final saved = await store.read();
    expect(saved!.bookmark, isNotEmpty);
    bookmark.failStart = true;

    final dest = await ReceiveDestination.resolve(
      destination: const SaveDestination(
          isDesktop: true, gallery: GalleryFormats(GalleryPlatform.none)),
      saveLocation: store,
    );

    expect(dest.path, p.join(root.path, 'downloads'));
    expect(dest.placed, isTrue);
    File(p.join(dest.path, 'received.txt')).writeAsStringSync('received');
    expect(File(p.join(dest.path, 'received.txt')).readAsStringSync(), 'received');
    final after = await store.read();
    expect(after?.path, saved.path);
    expect(after?.bookmark, saved.bookmark);
    await dest.release();
    expect(bookmark.stopCalled, isFalse);
  }, skip: !SaveLocationBookmark.isSupported);
}

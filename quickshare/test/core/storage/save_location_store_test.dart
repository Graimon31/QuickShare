// The macOS branch matters most here: a plain path survives a restart on
// Windows and Linux with no help at all, but on macOS "remember this folder"
// means nothing without a security-scoped bookmark behind it — the native
// side this fakes out, since flutter test has no platform channel to answer
// it for real.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/storage/save_location_bookmark.dart';
import 'package:quickshare/core/storage/save_location_store.dart';

class _FakeBookmark extends SaveLocationBookmark {
  final Map<String, String> _bookmarks = {};
  bool startCalled = false;
  bool stopCalled = false;
  bool staleOnNextStart = false;
  bool failCreate = false;
  bool failStart = false;

  _FakeBookmark();

  @override
  Future<String> create(String path) async {
    if (failCreate) {
      throw const SaveLocationBookmarkException('picker access already gone');
    }
    final token = 'bookmark-for:$path';
    _bookmarks[path] = token;
    return token;
  }

  @override
  Future<BookmarkAccess> startAccessing(String bookmark) async {
    startCalled = true;
    if (failStart) {
      throw const SaveLocationBookmarkException('bookmark no longer resolves');
    }
    final entry = _bookmarks.entries.firstWhere((e) => e.value == bookmark,
        orElse: () => throw const SaveLocationBookmarkException('unknown bookmark'));
    return BookmarkAccess(path: entry.key, stale: staleOnNextStart);
  }

  @override
  Future<void> stopAccessing() async {
    stopCalled = true;
  }
}

void main() {
  late Directory root;
  late _FakeBookmark bookmark;
  late SaveLocationStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_savelocation_');
    bookmark = _FakeBookmark();
    store = SaveLocationStore(overrideDir: () => root, bookmark: bookmark);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('nothing chosen yet', () {
    test('read is null before anything is set', () async {
      expect(await store.read(), isNull);
    });

    test('resolveForWriting is null, meaning "use the platform default"',
        () async {
      expect(await store.resolveForWriting(), isNull);
    });
  });

  group('choosing a folder', () {
    test('round-trips through read after set', () async {
      await store.set('/Users/someone/Desktop');
      final saved = await store.read();
      expect(saved?.path, equals('/Users/someone/Desktop'));
    });

    test('survives being read by a fresh store instance', () async {
      await store.set('/Users/someone/Desktop');

      final reopened =
          SaveLocationStore(overrideDir: () => root, bookmark: bookmark);
      final saved = await reopened.read();

      expect(saved?.path, equals('/Users/someone/Desktop'),
          reason: 'the whole point is that this survives a restart');
    });

    test('clear reverts to the default', () async {
      await store.set('/Users/someone/Desktop');
      await store.clear();
      expect(await store.read(), isNull);
    });
  });

  group('resolveForWriting on the platform bookmarks actually matter on',
      () {
    test('opens the bookmark rather than trusting the raw path', () async {
      await store.set('/Users/someone/Desktop');

      final dir = await store.resolveForWriting();

      expect(bookmark.startCalled, isTrue,
          reason: 'a stored path alone is not enough on this platform; the '
              'bookmark is what actually still grants access');
      expect(dir?.path, equals('/Users/someone/Desktop'));
    });

    test('release stops the security scope that was opened', () async {
      await store.set('/Users/someone/Desktop');
      await store.resolveForWriting();
      await store.release();

      expect(bookmark.stopCalled, isTrue);
    });

    test('a stale bookmark still hands back a working path', () async {
      await store.set('/Users/someone/Desktop');
      bookmark.staleOnNextStart = true;

      final dir = await store.resolveForWriting();

      expect(dir, isNotNull,
          reason: 'stale means the folder moved, not that access failed');
    });

    test('a bookmark that no longer resolves falls back to the default',
        () async {
      await store.set('/Users/someone/Desktop');
      bookmark.failStart = true;

      // Must not throw: null is the "use the platform default" signal, and
      // a dead bookmark — the folder was deleted, the drive is unplugged —
      // must not wedge the save that is waiting on this answer.
      expect(await store.resolveForWriting(), isNull);

      expect(await store.read(), isNotNull,
          reason: 'the choice is kept: a disconnected drive is transient, '
              'and once the folder is back transfers should head there again');
    });
  }, skip: SaveLocationBookmark.isSupported ? false : 'macOS-only behaviour');

  group('a folder picker whose grant already lapsed', () {
    test('set surfaces the failure rather than saving a broken choice',
        () async {
      bookmark.failCreate = true;

      await expectLater(
        store.set('/Users/someone/Desktop'),
        throwsA(isA<SaveLocationBookmarkException>()),
      );
      expect(await store.read(), isNull,
          reason: 'a failed bookmark must not leave a half-saved choice '
              'behind');
    }, skip: SaveLocationBookmark.isSupported ? false : 'macOS-only behaviour');
  });
}

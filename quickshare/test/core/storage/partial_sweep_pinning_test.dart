// The sweep that starts every receive must not eat what a receive may still
// come back for.
//
// `ReceiveDestination.resolve` clears `*.qs.partial` debris older than ten
// minutes from the folder it hands out, on every receive. That is right for
// the leftovers of a crashed WebRTC or Bluetooth transfer, which have no way
// back. It is wrong for two things:
//
//  * a QHTP partial. The QHTP client tells the user a cut transfer can be
//    resumed (after freeing disk space, say), and its session record is kept
//    for a day for exactly that. A single-file session writes its partial
//    straight into the folder the sweep reads, so coming back an hour later
//    meant the next receive's sweep had already deleted it;
//  * a folder that was received in full and could not be renamed to its real
//    name. It is marked `.qs.kept`, and it is the only copy.
//
// Driven through `ReceiveDestination.resolve` itself, with path_provider
// pointed at a scratch directory so the session store it consults is the one
// the QHTP client would have written.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/storage/gallery_formats.dart';
import 'package:quickshare/core/storage/receive_destination.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/save_location_bookmark.dart';
import 'package:quickshare/core/storage/save_location_store.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';

class _ScratchPaths extends PathProviderPlatform {
  _ScratchPaths(this.root);
  final Directory root;

  Future<String> _dir(String name) async =>
      (Directory(p.join(root.path, name))..createSync(recursive: true)).path;

  @override
  Future<String?> getApplicationSupportPath() => _dir('support');
  @override
  Future<String?> getTemporaryPath() => _dir('tmp');
  @override
  Future<String?> getApplicationDocumentsPath() => _dir('documents');
  @override
  Future<String?> getDownloadsPath() => _dir('downloads');
}

class _NoBookmark extends SaveLocationBookmark {
  @override
  Future<String> create(String path) async => 'bm:$path';
  @override
  Future<BookmarkAccess> startAccessing(String bookmark) async =>
      BookmarkAccess(path: bookmark.substring(3), stale: false);
  @override
  Future<void> stopAccessing() async {}
}

void main() {
  late Directory root;
  late Directory downloads;
  late PathProviderPlatform originalPaths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_sweep_pin_');
    downloads = Directory(p.join(root.path, 'Downloads'))..createSync();
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _ScratchPaths(root);
  });
  tearDown(() {
    PathProviderPlatform.instance = originalPaths;
    root.deleteSync(recursive: true);
  });

  const desktop = SaveDestination(
      isDesktop: true, gallery: GalleryFormats(GalleryPlatform.none));

  /// A `.qs.partial` last touched three hours ago.
  File partial(String name, {int bytes = 100, Duration age = const Duration(hours: 3)}) {
    final file = File(p.join(downloads.path, '$name$kPartialSuffix'))
      ..writeAsBytesSync(List.filled(bytes, 7));
    file.setLastModifiedSync(DateTime.now().subtract(age));
    return file;
  }

  /// What the QHTP client records for a session it has not finished.
  Future<void> recordSession(String id, List<QhtpItemState> items,
      {Duration age = Duration.zero}) async {
    final store = SessionStateStore();
    await store.saveState(
      sessionId: id,
      host: '127.0.0.1',
      port: 1,
      token: 't',
      baseDir: downloads.path,
      items: {for (final i in items) i.id: i},
    );
    if (age > Duration.zero) {
      final file = Directory(p.join(root.path, 'support', 'qhtp_sessions'))
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.json'));
      file.setLastModifiedSync(DateTime.now().subtract(age));
    }
  }

  /// A receive starting: the sweep is fired off by `resolve` and finishes on
  /// its own time, so wait for the debris that must go to be gone.
  Future<void> receiveStarts(List<File> mustBeSwept) async {
    final store = SaveLocationStore(
        overrideDir: () => Directory(p.join(root.path, 'support')),
        bookmark: _NoBookmark());
    await store.set(downloads.path);
    final dest = await ReceiveDestination.resolve(
        destination: desktop, saveLocation: store);
    expect(dest.path, downloads.path);
    for (var i = 0; i < 300; i++) {
      if (mustBeSwept.every((f) => !f.existsSync())) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('the sweep never removed ${mustBeSwept.where((f) => f.existsSync()).map((f) => p.basename(f.path)).toList()}');
  }

  test('a partial a live QHTP session can resume survives the sweep',
      () async {
    final resumable = partial('video.bin', bytes: 300);
    final debris = partial('crashed.bin');
    final young = partial('now.bin', age: const Duration(minutes: 1));
    await recordSession('s1', [
      QhtpItemState(
        id: '1',
        path: 'video.bin',
        size: 1000,
        status: 'partial',
        partialBytes: 300,
        finalPath: p.join(downloads.path, 'video.bin'),
      ),
    ]);

    await receiveStarts([debris]);

    expect(resumable.existsSync(), isTrue,
        reason: 'the sweep deleted a partial the client says can be resumed');
    expect(resumable.lengthSync(), 300);
    expect(young.existsSync(), isTrue);
  });

  test('the pinned name is derived from the manifest path when no name was '
      'recorded', () async {
    final resumable = partial('notes.txt');
    final debris = partial('crashed.bin');
    await recordSession('s2', [
      const QhtpItemState(
          id: '1', path: 'notes.txt', size: 10, status: 'pending'),
    ]);

    await receiveStarts([debris]);

    expect(resumable.existsSync(), isTrue);
  });

  test('a session past its expiry no longer protects its partial', () async {
    final stale = partial('old.bin');
    await recordSession(
      's3',
      [
        QhtpItemState(
          id: '1',
          path: 'old.bin',
          size: 1000,
          status: 'partial',
          finalPath: p.join(downloads.path, 'old.bin'),
        ),
      ],
      age: const Duration(days: 2),
    );

    await receiveStarts([stale]);

    expect(stale.existsSync(), isFalse);
  });

  test('an item that is already complete pins nothing', () async {
    final leftover = partial('done.bin');
    await recordSession('s4', [
      QhtpItemState(
        id: '1',
        path: 'done.bin',
        size: 100,
        status: 'completed',
        finalPath: p.join(downloads.path, 'done.bin'),
      ),
    ]);

    await receiveStarts([leftover]);

    expect(leftover.existsSync(), isFalse);
  });

  test('a received folder that could not be renamed is kept; ordinary staging '
      'debris is not', () async {
    final kept = Directory(p.join(downloads.path, 'Trip$kPartialSuffix'))
      ..createSync();
    File(p.join(kept.path, 'a.bin')).writeAsBytesSync([1, 2, 3]);
    File(p.join(kept.path, kKeptMarker)).writeAsStringSync('kept');
    final debris = Directory(p.join(downloads.path, 'Half$kPartialSuffix'))
      ..createSync();
    File(p.join(debris.path, 'a.bin')).writeAsBytesSync([1]);

    // Everything is stale as far as the age test goes.
    final freed = await sweepPartials(downloads.path,
        before: DateTime.now().add(const Duration(hours: 1)));

    expect(debris.existsSync(), isFalse);
    expect(freed, 1);
    expect(File(p.join(kept.path, 'a.bin')).readAsBytesSync(), [1, 2, 3],
        reason: 'the only copy of a complete folder was swept away');
  });
}

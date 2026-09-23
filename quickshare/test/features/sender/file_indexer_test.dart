import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';

void main() {
  group('FileIndexer', () {
    late Directory tempDir;
    late FileIndexer indexer;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('qhtp_index_test_');
      indexer = FileIndexer();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('indexes files and subdirectories with relative paths and skips .DS_Store', () async {
      final file1 = File(p.join(tempDir.path, 'doc.pdf'));
      await file1.writeAsString('hello pdf');

      final dsStore = File(p.join(tempDir.path, '.DS_Store'));
      await dsStore.writeAsString('junk');

      final subDir = Directory(p.join(tempDir.path, 'photos'));
      await subDir.create();

      final img = File(p.join(subDir.path, 'pic.png'));
      await img.writeAsString('image bytes');

      final manifest = await indexer.buildManifest(
        sessionId: 'test_session_1',
        paths: [tempDir.path],
      );

      expect(manifest.itemCount, equals(2));
      expect(manifest.items.any((i) => i.path.endsWith('.DS_Store')), isFalse);
      expect(manifest.items[0].id, equals('000001'));
      expect(manifest.items[1].id, equals('000002'));
    });

    test('does not descend into node_modules or .git', () async {
      File(p.join(tempDir.path, 'src.txt'))
        ..createSync()
        ..writeAsStringSync('keep');
      Directory(p.join(tempDir.path, 'node_modules', 'pkg')).createSync(recursive: true);
      File(p.join(tempDir.path, 'node_modules', 'pkg', 'lib.js'))
        ..createSync(recursive: true)
        ..writeAsStringSync('skip');
      Directory(p.join(tempDir.path, '.git', 'objects')).createSync(recursive: true);
      File(p.join(tempDir.path, '.git', 'objects', 'ab'))
        ..createSync(recursive: true)
        ..writeAsStringSync('skip');

      final manifest = await indexer.buildManifest(
        sessionId: 'skip_dirs',
        paths: [tempDir.path],
      );

      expect(manifest.itemCount, equals(1));
      expect(manifest.items.single.path.endsWith('src.txt'), isTrue);
    });

    test('indexes hundreds of nested files in one walk', () async {
      for (var i = 0; i < 8; i++) {
        final dir = Directory(p.join(tempDir.path, 'b$i'))..createSync();
        for (var j = 0; j < 40; j++) {
          File(p.join(dir.path, 'f$j.txt')).writeAsStringSync('x');
        }
      }

      final sw = Stopwatch()..start();
      final result = await indexer.buildResult(
        sessionId: 'bulk',
        paths: [tempDir.path],
        includeChecksums: false,
      );
      sw.stop();

      expect(result.manifest.itemCount, equals(320));
      expect(sw.elapsedMilliseconds, lessThan(2000),
          reason: 'a local tree of hundreds of files must not sit on per-file awaits');
    });

    test('walks even when onProgress carries an unsendable context', () async {
      File(p.join(tempDir.path, 'a.txt'))
        ..createSync()
        ..writeAsStringSync('a');

      // The send path hands the indexer a callback that lives in a bloc
      // handler, and a Dart closure carries its whole enclosing context --
      // not only the variables it names. A Completer or an Emitter sitting
      // in that same scope is enough to make the context unsendable, and if
      // the walk's own Isolate.run closure shares a context with the
      // callback, the spawn is refused before a single directory is read:
      // "Illegal argument in isolate message: object is unsendable".
      final unsendable = Completer<void>();
      var reports = 0;

      final result = await indexer.buildResult(
        sessionId: 'progress_capture',
        paths: [tempDir.path],
        includeChecksums: false,
        onProgress: (items, bytes) {
          if (unsendable.isCompleted) return;
          reports++;
        },
      );

      expect(result.manifest.itemCount, equals(1));
      expect(reports, greaterThan(0));
    });

    test('throws FileIndexerException on empty selection', () async {
      final emptySubDir = Directory(p.join(tempDir.path, 'empty_folder'));
      await emptySubDir.create();

      expect(
        () => indexer.buildManifest(sessionId: 'empty_sess', paths: [emptySubDir.path]),
        throwsA(isA<FileIndexerException>()),
      );
    });
  });
}

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

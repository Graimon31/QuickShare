import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';

void main() {
  group('QhtpReceiverClient Path Safety', () {
    late QhtpReceiverClient client;
    late Directory tempBaseDir;

    setUp(() async {
      client = QhtpReceiverClient();
      tempBaseDir = await Directory.systemTemp.createTemp('qhtp_recv_test_');
    });

    tearDown(() async {
      if (await tempBaseDir.exists()) {
        await tempBaseDir.delete(recursive: true);
      }
    });

    test('sanitizeSegment strips invalid characters and control chars', () {
      expect(client.sanitizeSegment('hello:world?.txt'),
          equals('hello_world_.txt'));
      expect(
          client.sanitizeSegment('../../evil.txt'), equals('.._.._evil.txt'));
      expect(client.sanitizeSegment(''), equals('item'));
    });

    test('materializePath builds valid path within base directory', () {
      final res =
          client.materializePath('photos/2024/vacation.jpg', tempBaseDir.path);
      expect(p.isWithin(tempBaseDir.path, res), isTrue);
      expect(res.endsWith('photos/2024/vacation.jpg'), isTrue);
    });

    test('materializePath strips path traversal dot segments', () {
      final res =
          client.materializePath('../../evil/../etc/passwd', tempBaseDir.path);
      expect(p.isWithin(tempBaseDir.path, res), isTrue);
      expect(res.contains('..'), isFalse);
    });

    test('uses the single manifest root as the result name and path', () {
      final result = client.deriveReceiveResult(
        const QhtpManifest(
          sessionId: 'session',
          createdAt: 0,
          itemCount: 2,
          totalBytes: 3,
          items: [
            QhtpItem(id: '1', path: 'Vacation/photo.jpg', size: 1),
            QhtpItem(id: '2', path: 'Vacation/videos/clip.mp4', size: 2),
          ],
        ),
        tempBaseDir.path,
      );

      expect(result.displayName, equals('Vacation'));
      expect(result.preferredResultPath,
          equals(p.join(tempBaseDir.path, 'Vacation')));
    });

    test('uses the base directory and a stable name for multiple roots', () {
      final result = client.deriveReceiveResult(
        const QhtpManifest(
          sessionId: 'session',
          createdAt: 0,
          itemCount: 2,
          totalBytes: 3,
          items: [
            QhtpItem(id: '1', path: 'zebra.txt', size: 1),
            QhtpItem(id: '2', path: 'Albums/photo.jpg', size: 2),
          ],
        ),
        tempBaseDir.path,
      );

      expect(result.displayName, equals('2 items'));
      expect(result.preferredResultPath, equals(tempBaseDir.path));
    });

    // Writing straight into the user's own Downloads folder is what saves a
    // gigabyte from being copied a second time after the transfer — but it
    // means the destination is full of files this session did not put there,
    // so the completion screen cannot simply list the directory.
    test('collapses what was written into its top-level entries', () {
      final entries = QhtpReceiverClient.topLevelEntries(
        [
          p.join(tempBaseDir.path, 'Vacation', 'photo.jpg'),
          p.join(tempBaseDir.path, 'Vacation', 'videos', 'clip.mp4'),
          p.join(tempBaseDir.path, 'notes.txt'),
        ],
        tempBaseDir.path,
      );

      expect(
          entries,
          equals([
            p.join(tempBaseDir.path, 'Vacation'),
            p.join(tempBaseDir.path, 'notes.txt'),
          ]),
          reason: 'a folder is one entry however many files are inside it');
    });

    test('reports the name a file actually landed under, not the sent one', () {
      // `report.pdf` was taken, so the transfer wrote `report (1).pdf`. The
      // manifest still says `report.pdf`; only the transfer's own record of
      // where each item went is true.
      final result = client.deriveReceiveResult(
        const QhtpManifest(
          sessionId: 'session',
          createdAt: 0,
          itemCount: 1,
          totalBytes: 1,
          items: [QhtpItem(id: '1', path: 'report.pdf', size: 1)],
        ),
        tempBaseDir.path,
        placedPaths: [p.join(tempBaseDir.path, 'report (1).pdf')],
      );

      expect(result.displayName, equals('report (1).pdf'));
      expect(result.preferredResultPath,
          equals(p.join(tempBaseDir.path, 'report (1).pdf')));
    });
  });
}

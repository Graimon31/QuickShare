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
  });
}

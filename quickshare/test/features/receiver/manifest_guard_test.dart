// The receiver holds a hostile manifest to the same limits the sender's
// indexer holds an ordinary selection to.
//
// DD-21. Path traversal was already caught. Everything else — a tree
// thousands deep, a path no filesystem accepts, a JSON document sized to
// exhaust memory before it parses — was checked only by the indexer, on the
// sending side, where the sender is the one thing you cannot trust. A sender
// that skipped the real indexer reached the loop that creates directories
// with none of it.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/features/receiver/data/manifest_guard.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';

void main() {
  const guard = ManifestGuard();

  QhtpManifest withItems(List<String> paths) => QhtpManifest(
        sessionId: 's',
        createdAt: 0,
        itemCount: paths.length,
        totalBytes: paths.length,
        items: [
          for (var i = 0; i < paths.length; i++)
            QhtpItem(id: '$i'.padLeft(6, '0'), path: paths[i], size: 1),
        ],
      );

  group('the manifest body size', () {
    test('a body at the limit is accepted', () {
      expect(
        () => guard.checkSize(AppConstants.qhtpManifestMaxBytes),
        returnsNormally,
      );
    });

    test('one byte over is refused, before anything parses it', () {
      expect(
        () => guard.checkSize(AppConstants.qhtpManifestMaxBytes + 1),
        throwsA(isA<ManifestRejected>()),
      );
    });

    test('the refusal names the size and the limit', () {
      // So a person can see it is the sender that is unreasonable, not their
      // device that is broken.
      try {
        guard.checkSize(64 * 1024 * 1024);
        fail('expected a rejection');
      } on ManifestRejected catch (e) {
        expect(e.message, contains('64.0 MB'));
        expect(e.message, contains('32 MB'));
      }
    });
  });

  group('the paths inside it', () {
    test('an ordinary folder tree passes', () {
      expect(
        () => guard.checkPaths(withItems([
          'Trip/Day 1/IMG_0042.HEIC',
          'Trip/Day 2/clip.mov',
          'notes.txt',
        ])),
        returnsNormally,
      );
    });

    test('a tree deeper than the limit is refused', () {
      final deep = List.filled(AppConstants.qhtpMaxPathDepth + 1, 'x').join('/');
      expect(
        () => guard.checkPaths(withItems([deep])),
        throwsA(isA<ManifestRejected>()),
      );
    });

    test('a path longer than the limit is refused', () {
      final long = 'a' * (AppConstants.qhtpMaxRelPathChars + 1);
      expect(
        () => guard.checkPaths(withItems([long])),
        throwsA(isA<ManifestRejected>()),
      );
    });

    test('a traversal segment is refused here, not only at materialize time',
        () {
      // `materializePath` catches it too, but this refuses the whole transfer
      // before the first directory is created rather than one item into it.
      for (final path in ['../secrets', 'a/../../b', 'a//b', './x']) {
        expect(
          () => guard.checkPaths(withItems([path])),
          throwsA(isA<ManifestRejected>()),
          reason: path,
        );
      }
    });

    test('a backslash or a null in a segment is refused', () {
      for (final path in [r'a\b', 'a\x00b']) {
        expect(
          () => guard.checkPaths(withItems([path])),
          throwsA(isA<ManifestRejected>()),
          reason: path,
        );
      }
    });

    test('an item with no path at all is refused', () {
      expect(
        () => guard.checkPaths(withItems([''])),
        throwsA(isA<ManifestRejected>()),
      );
    });

    test('a Cyrillic path near the byte limit is measured in bytes', () {
      // The limit is bytes, and a Cyrillic character is two of them. A path
      // that is legal by character count but over by byte count must be
      // refused, or it fails later at create() with ENAMETOOLONG.
      final justOver = 'д' * (AppConstants.qhtpMaxRelPathChars ~/ 2 + 1);
      expect(
        () => guard.checkPaths(withItems([justOver])),
        throwsA(isA<ManifestRejected>()),
      );
    });
  });

  group('the item count and size limits', () {
    test('a manifest within limits passes', () {
      final manifest = QhtpManifest(
        sessionId: 's',
        createdAt: 0,
        itemCount: 2,
        totalBytes: 200,
        items: [
          QhtpItem(id: '01', path: 'a.txt', size: 100),
          QhtpItem(id: '02', path: 'b.txt', size: 100),
        ],
      );
      expect(() => guard.checkLimits(manifest), returnsNormally);
    });

    test('a manifest with too many items is rejected', () {
      final items = List.generate(
        AppConstants.qhtpMaxFileCount + 1,
        (i) => QhtpItem(id: '$i', path: '$i.txt', size: 1),
      );
      final manifest = QhtpManifest(
        sessionId: 's',
        createdAt: 0,
        itemCount: items.length,
        totalBytes: items.length,
        items: items,
      );
      expect(() => guard.checkLimits(manifest), throwsA(isA<ManifestRejected>()));
    });

    test('a manifest with negative item size is rejected', () {
      final manifest = QhtpManifest(
        sessionId: 's',
        createdAt: 0,
        itemCount: 1,
        totalBytes: -1,
        items: [
          QhtpItem(id: '01', path: 'a.txt', size: -1),
        ],
      );
      expect(() => guard.checkLimits(manifest), throwsA(isA<ManifestRejected>()));
    });

    test('a manifest with aggregate size over session limit is rejected', () {
      final manifest = QhtpManifest(
        sessionId: 's',
        createdAt: 0,
        itemCount: 2,
        totalBytes: AppConstants.qhtpMaxSessionBytes + 1,
        items: [
          QhtpItem(id: '01', path: 'a.txt', size: AppConstants.qhtpMaxSessionBytes),
          QhtpItem(id: '02', path: 'b.txt', size: 1),
        ],
      );
      expect(() => guard.checkLimits(manifest), throwsA(isA<ManifestRejected>()));
    });
  });
}

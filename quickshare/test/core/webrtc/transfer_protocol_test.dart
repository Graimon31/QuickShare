import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/webrtc/transfer_protocol.dart';

void main() {
  const photo = TransferItem(
    name: 'IMG_0042.HEIC',
    size: 4200000,
    mimeType: 'image/heic',
    compressed: false,
  );
  const doc = TransferItem(
    name: 'report.txt',
    size: 1200,
    mimeType: 'text/plain',
    compressed: true,
  );

  group('manifest', () {
    test('round-trips every field', () {
      final encoded = TransferProtocol.buildManifest([photo, doc]);
      final decoded = TransferProtocol.parseManifest(
          jsonDecode(encoded) as Map<String, dynamic>);

      expect(decoded, hasLength(2));
      expect(decoded[0].name, equals('IMG_0042.HEIC'));
      expect(decoded[0].size, equals(4200000));
      expect(decoded[0].mimeType, equals('image/heic'));
      expect(decoded[0].compressed, isFalse);
      expect(decoded[1].compressed, isTrue);
    });

    test('carries the session total so the receiver can show real progress',
        () {
      final json = jsonDecode(TransferProtocol.buildManifest([photo, doc]))
          as Map<String, dynamic>;
      expect(json['totalBytes'], equals(4200000 + 1200));
    });

    test('compression is decided per item, not per session', () {
      // A folder of photos and documents should compress the documents and
      // leave the photos alone; a single session-wide flag cannot express that.
      final decoded = TransferProtocol.parseManifest(
          jsonDecode(TransferProtocol.buildManifest([photo, doc]))
              as Map<String, dynamic>);
      expect(decoded.map((i) => i.compressed), equals([false, true]));
    });

    test('an empty or missing file list is rejected outright', () {
      expect(() => TransferProtocol.parseManifest({'files': []}),
          throwsA(isA<FormatException>()));
      expect(() => TransferProtocol.parseManifest({}),
          throwsA(isA<FormatException>()));
    });

    test('an item without a usable name or size is rejected', () {
      expect(
        () => TransferProtocol.parseManifest({
          'files': [
            {'size': 10}
          ]
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => TransferProtocol.parseManifest({
          'files': [
            {'name': 'x', 'size': -1}
          ]
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('a missing mime type falls back rather than failing the session', () {
      final decoded = TransferProtocol.parseManifest({
        'files': [
          {'name': 'unknown.bin', 'size': 5}
        ]
      });
      expect(decoded.single.mimeType, equals('application/octet-stream'));
      expect(decoded.single.compressed, isFalse);
    });
  });

  group('folder paths', () {
    const inFolder = TransferItem(
      name: 'IMG_0042.HEIC',
      size: 4200000,
      mimeType: 'image/heic',
      compressed: false,
      path: 'Trip/Day 1/IMG_0042.HEIC',
    );

    test('an item keeps the path it has to be rebuilt at', () {
      final decoded = TransferProtocol.parseManifest(
          jsonDecode(TransferProtocol.buildManifest([inFolder]))
              as Map<String, dynamic>);
      expect(decoded.single.path, equals('Trip/Day 1/IMG_0042.HEIC'));
      expect(decoded.single.name, equals('IMG_0042.HEIC'));
    });

    test('a file picked directly puts no path on the wire', () {
      // A manifest of ten thousand loose files would otherwise pay ten
      // thousand times for a field that repeats the name beside it.
      final json = jsonDecode(TransferProtocol.buildManifest([photo]))
          as Map<String, dynamic>;
      expect((json['files'] as List).single, isNot(contains('path')));
      expect(photo.path, equals(photo.name));
      expect(photo.hasFolderPath, isFalse);
      expect(inFolder.hasFolderPath, isTrue);
    });

    test('a sender that knows nothing about folders is not a broken one', () {
      // No path field at all is a session with no folders in it, which is
      // every session older builds could express.
      final decoded = TransferProtocol.parseManifest({
        'files': [
          {'name': 'holiday.mov', 'size': 10}
        ]
      });
      expect(decoded.single.path, equals('holiday.mov'));
    });
  });

  group('large manifests', () {
    /// Enough items that the list cannot be announced in one frame.
    List<TransferItem> folderOf(int count) => [
          for (var i = 0; i < count; i++)
            TransferItem(
              name: 'IMG_${i.toString().padLeft(5, '0')}.HEIC',
              size: 4200000,
              mimeType: 'image/heic',
              compressed: false,
              path: 'Trip/Day ${i % 7}/IMG_${i.toString().padLeft(5, '0')}.HEIC',
            ),
        ];

    test('a session that fits still goes out as one frame', () {
      final frames = TransferProtocol.buildManifestFrames([photo, doc]);
      expect(frames, hasLength(1));
      expect(jsonDecode(frames.single)['type'], equals('manifest'));
    });

    test('a folder too big for one frame is split into parts', () {
      // Not a slow send but a refused one: past roughly a quarter megabyte a
      // data channel will not carry the message at all, and the session dies
      // on its opening frame.
      final frames = TransferProtocol.buildManifestFrames(folderOf(4000));

      expect(frames.length, greaterThan(1));
      final begin = jsonDecode(frames.first) as Map<String, dynamic>;
      expect(begin['type'], equals('manifest-begin'));
      expect(begin['count'], equals(4000));
      expect(begin['parts'], equals(frames.length - 1));
      expect(begin['totalBytes'], equals(4000 * 4200000));
    });

    test('no frame is larger than the limit it was given', () {
      for (final frame in TransferProtocol.buildManifestFrames(folderOf(4000))) {
        expect(utf8.encode(frame).length,
            lessThanOrEqualTo(TransferProtocol.maxManifestFrameBytes));
      }
    });

    test('the parts put the whole folder back together, in order', () {
      final items = folderOf(4000);
      final frames = TransferProtocol.buildManifestFrames(items);

      final rebuilt = <TransferItem>[];
      for (final frame in frames.skip(1)) {
        rebuilt.addAll(TransferProtocol.parseManifest(
            jsonDecode(frame) as Map<String, dynamic>));
      }

      expect(rebuilt, hasLength(items.length));
      expect(rebuilt.map((i) => i.path).toList(),
          equals(items.map((i) => i.path).toList()));
    });

    test('the parts are numbered so a gap is noticeable', () {
      final frames = TransferProtocol.buildManifestFrames(folderOf(4000));
      final indexes = [
        for (final frame in frames.skip(1)) jsonDecode(frame)['index'] as int,
      ];
      expect(indexes, equals(List.generate(indexes.length, (i) => i)));
    });

    test('a single item larger than the frame budget still gets sent', () {
      // Nothing can split one entry, so the part it lands in is allowed to
      // overshoot rather than being dropped from the manifest.
      final huge = TransferItem(
        name: 'x.bin',
        size: 1,
        mimeType: 'application/octet-stream',
        compressed: false,
        path: 'Deep/${'nested/' * 60}x.bin',
      );
      final frames =
          TransferProtocol.buildManifestFrames([huge, huge], maxFrameBytes: 64);
      final rebuilt = [
        for (final frame in frames.skip(1))
          ...TransferProtocol.parseManifest(
              jsonDecode(frame) as Map<String, dynamic>),
      ];
      expect(rebuilt, hasLength(2));
    });
  });

  group('framing', () {
    test('file-start and file-end carry the index they refer to', () {
      expect(jsonDecode(TransferProtocol.buildFileStart(3)),
          equals({'type': 'file-start', 'index': 3}));
      expect(jsonDecode(TransferProtocol.buildFileEnd(3)),
          equals({'type': 'file-end', 'index': 3}));
    });

    test('cancellation is its own message, not a silent disconnect', () {
      // The receiver has to be able to tell a deliberate stop from a dropped
      // network, and to react at once rather than after a grace period.
      expect(jsonDecode(TransferProtocol.buildCancelled()),
          equals({'type': 'cancelled'}));
      expect(TransferProtocol.cancelled, isNot(equals(TransferProtocol.complete)));
    });

    test('complete needs no payload', () {
      expect(jsonDecode(TransferProtocol.buildComplete()),
          equals({'type': 'complete'}));
    });
  });

  group('backward compatibility', () {
    test('both legacy single-file openers are still recognised', () {
      // A peer on an older build is not a corrupt peer.
      expect(TransferProtocol.isLegacySingleFile('file-meta'), isTrue);
      expect(TransferProtocol.isLegacySingleFile('metadata'), isTrue);
    });

    test('the new manifest opener is not mistaken for a legacy one', () {
      expect(TransferProtocol.isLegacySingleFile('manifest'), isFalse);
      expect(TransferProtocol.isLegacySingleFile(null), isFalse);
    });
  });
}

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

  group('framing', () {
    test('file-start and file-end carry the index they refer to', () {
      expect(jsonDecode(TransferProtocol.buildFileStart(3)),
          equals({'type': 'file-start', 'index': 3}));
      expect(jsonDecode(TransferProtocol.buildFileEnd(3)),
          equals({'type': 'file-end', 'index': 3}));
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

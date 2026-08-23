import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/utils/mime_compression.dart';

void main() {
  group('already-compressed payloads are sent as they are', () {
    test('photos and videos', () {
      expect(shouldCompressForTransfer('image/jpeg', 'shot.jpg'), isFalse);
      expect(shouldCompressForTransfer('image/heic', 'IMG.HEIC'), isFalse);
      expect(shouldCompressForTransfer('video/mp4', 'clip.mp4'), isFalse);
      expect(shouldCompressForTransfer('video/quicktime', 'clip.mov'), isFalse);
    });

    test('camera RAW, which no MIME type identifies', () {
      // These arrive as application/octet-stream, so only the extension can
      // save them from a pointless gzip pass over tens of megabytes.
      for (final name in [
        'a.dng', 'a.cr2', 'a.cr3', 'a.nef', 'a.arw',
        'a.orf', 'a.raf', 'a.rw2', 'a.mrw', 'a.srf',
      ]) {
        expect(shouldCompressForTransfer('application/octet-stream', name),
            isFalse,
            reason: '$name is already compressed inside');
      }
    });

    test('video containers the MIME lookup does not know', () {
      for (final name in [
        'v.3gp', 'v.mpg', 'v.mpeg', 'v.vob', 'v.m2ts',
        'v.mxf', 'v.asf', 'v.ogv', 'v.f4v', 'v.divx', 'v.rmvb',
      ]) {
        expect(shouldCompressForTransfer(null, name), isFalse, reason: name);
      }
    });

    test('archives and office documents', () {
      expect(shouldCompressForTransfer('application/zip', 'a.zip'), isFalse);
      expect(shouldCompressForTransfer(null, 'report.docx'), isFalse);
      expect(shouldCompressForTransfer('application/pdf', 'a.pdf'), isFalse);
    });
  });

  group('compressible payloads still get the pass', () {
    test('text and structured data', () {
      expect(shouldCompressForTransfer('text/plain', 'notes.txt'), isTrue);
      expect(shouldCompressForTransfer('application/json', 'log.json'), isTrue);
      expect(shouldCompressForTransfer(null, 'dump.csv'), isTrue);
    });

    test('uncompressed TIFF, which genuinely shrinks', () {
      // Sat next to the RAW formats in the format list and behaves nothing
      // like them: a scanner TIFF is often plain uncompressed pixels.
      expect(shouldCompressForTransfer('image/tiff', 'scan.tiff'), isTrue);
    });

    test('an unknown type is assumed compressible', () {
      // A useless gzip pass is cheap; skipping a compressible format is not.
      expect(shouldCompressForTransfer(null, 'sensor.bin'), isTrue);
      expect(shouldCompressForTransfer('', 'noextension'), isTrue);
    });
  });

  test('case never matters', () {
    expect(shouldCompressForTransfer('IMAGE/JPEG', 'SHOT.JPG'), isFalse);
    expect(shouldCompressForTransfer(null, 'A.CR2'), isFalse);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/storage/gallery_formats.dart';
import 'package:quickshare/core/storage/received_item.dart';

void main() {
  ReceivedItem item(String name, [String mime = 'application/octet-stream']) =>
      ReceivedItem(
        cachePath: '/cache/incoming/$name',
        name: name,
        size: 1000,
        mimeType: mime,
      );

  const ios = GalleryFormats(GalleryPlatform.ios);
  const android = GalleryFormats(GalleryPlatform.android);

  group('iOS Photos', () {
    test('takes the formats Apple lists', () {
      for (final name in [
        'IMG_0042.HEIC',
        'IMG_0042.heif',
        'shot.jpg',
        'shot.jpeg',
        'screen.png',
        'anim.gif',
        'scan.tiff',
        'scan.tif',
        'clip.mov',
        'clip.mp4',
        'clip.m4v',
        'clip.3gp',
      ]) {
        expect(ios.accepts(item(name)), isTrue, reason: '$name should go to Photos');
      }
    });

    test('takes camera RAW, which no MIME type would have identified', () {
      // The `mime` package resolves none of these, so they arrive as
      // application/octet-stream. Before the extension list knew them they
      // were treated as documents and the user was asked where to put their
      // own photos.
      for (final name in [
        'a.dng',
        'a.cr2',
        'a.cr3',
        'a.nef',
        'a.arw',
        'a.orf',
        'a.raf',
        'a.rw2',
        'a.mrw',
        'a.srf',
      ]) {
        expect(ios.accepts(item(name)), isTrue, reason: '$name is RAW');
      }
    });

    test('refuses the video containers Photos will not store', () {
      // Every one of these is unmistakably a video, and every one of them
      // used to be handed to the gallery, fail, and then be deleted.
      for (final name in [
        'movie.avi',
        'movie.mkv',
        'movie.webm',
        'movie.wmv',
        'movie.flv',
        'movie.vob',
        'movie.mpg',
        'movie.ts',
        'movie.m2ts',
        'movie.mxf',
        'movie.asf',
        'movie.ogv',
        'movie.rmvb',
      ]) {
        expect(ios.accepts(item(name)), isFalse, reason: '$name is not a Photos format');
      }
    });

    test('refuses the image formats Photos will not store', () {
      for (final name in ['sticker.webp', 'old.bmp', 'new.avif', 'logo.svg', 'art.psd']) {
        expect(ios.accepts(item(name)), isFalse, reason: '$name is not a Photos format');
      }
    });
  });

  group('Android gallery', () {
    test('takes what MediaStore indexes, including WebP, BMP and AVIF', () {
      for (final name in [
        'shot.jpg',
        'screen.png',
        'anim.gif',
        'old.bmp',
        'sticker.webp',
        'IMG.heic',
        'new.avif',
        'raw.dng',
        'clip.mp4',
        'clip.3gp',
        'clip.webm',
        'clip.mkv',
      ]) {
        expect(android.accepts(item(name)), isTrue, reason: '$name should go to the gallery');
      }
    });

    test('takes .mov, because that is what an iPhone sends', () {
      // Google's format documentation lists only MP4/3GP/WebM/Matroska, but
      // that document is about codec support; MediaStore indexes
      // video/quicktime and every gallery shows it.
      expect(android.accepts(item('clip.mov')), isTrue);
    });

    test('refuses what Android will not index', () {
      for (final name in ['movie.avi', 'movie.wmv', 'movie.flv', 'movie.vob', 'scan.tiff']) {
        expect(android.accepts(item(name)), isFalse, reason: '$name is not a gallery format');
      }
    });
  });

  group('the two platforms genuinely disagree', () {
    test('WebP, BMP and AVIF are Android-only', () {
      for (final name in ['sticker.webp', 'old.bmp', 'new.avif']) {
        expect(ios.accepts(item(name)), isFalse);
        expect(android.accepts(item(name)), isTrue);
      }
    });

    test('TIFF and camera RAW are iOS-only', () {
      for (final name in ['scan.tiff', 'a.cr2', 'a.nef']) {
        expect(ios.accepts(item(name)), isTrue);
        expect(android.accepts(item(name)), isFalse);
      }
    });

    test('WebM and Matroska are Android-only', () {
      for (final name in ['clip.webm', 'clip.mkv']) {
        expect(ios.accepts(item(name)), isFalse);
        expect(android.accepts(item(name)), isTrue);
      }
    });
  });

  group('falling back to the MIME type', () {
    test('a name with no extension is judged on what the sender said', () {
      expect(ios.accepts(item('IMG_0042', 'image/heic')), isTrue);
      expect(ios.accepts(item('IMG_0042', 'video/quicktime')), isTrue);
      expect(ios.accepts(item('IMG_0042', 'video/x-msvideo')), isFalse);
      expect(android.accepts(item('IMG_0042', 'image/webp')), isTrue);
    });

    test('an unknown extension is not second-guessed by the MIME type', () {
      // A sender claiming image/jpeg for something named .bin is either
      // wrong or up to something; the gallery would refuse it anyway.
      expect(ios.accepts(item('payload.bin', 'image/jpeg')), isFalse);
    });

    test('case never matters', () {
      expect(ios.accepts(item('IMG.JPG')), isTrue);
      expect(ios.accepts(item('CLIP.MOV', 'VIDEO/QUICKTIME')), isTrue);
    });
  });

  test('desktop has no gallery and accepts nothing', () {
    const none = GalleryFormats(GalleryPlatform.none);
    for (final name in ['shot.jpg', 'clip.mp4', 'notes.txt']) {
      expect(none.accepts(item(name)), isFalse);
    }
  });
}

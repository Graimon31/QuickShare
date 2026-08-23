import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/storage/gallery_formats.dart';
import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/storage/save_destination.dart';

void main() {
  ReceivedItem item(String name, String mime) => ReceivedItem(
        cachePath: '/cache/incoming/$name',
        name: name,
        size: 1000,
        mimeType: mime,
      );

  final photo = item('IMG_0042.HEIC', 'image/heic');
  final video = item('clip.mp4', 'video/mp4');
  final document = item('contract.pdf', 'application/pdf');
  final archive = item('bundle.zip', 'application/zip');

  group('on desktop', () {
    const desktop = SaveDestination(
      isDesktop: true,
      gallery: GalleryFormats(GalleryPlatform.none),
    );

    test('everything is written out without asking', () {
      // There is an obvious, non-shared Downloads folder, and putting a file
      // there is what the user already expects.
      for (final i in [photo, video, document, archive]) {
        expect(desktop.intentFor(i), equals(SaveIntent.automatic),
            reason: '${i.name} should not prompt on desktop');
      }
    });

    test('nothing ever blocks the session on a question', () {
      expect(desktop.anyNeedsAsking([photo, document]), isFalse);
    });
  });

  group('on iOS', () {
    const mobile = SaveDestination(
      isDesktop: false,
      gallery: GalleryFormats(GalleryPlatform.ios),
    );

    test('photos and videos go straight to the gallery', () {
      expect(mobile.intentFor(photo), equals(SaveIntent.gallery));
      expect(mobile.intentFor(video), equals(SaveIntent.gallery));
    });

    test('other files ask first', () {
      // Writing a document into shared storage uninvited is not ours to
      // decide.
      expect(mobile.intentFor(document), equals(SaveIntent.ask));
      expect(mobile.intentFor(archive), equals(SaveIntent.ask));
    });

    test('a video Photos will not store asks instead of failing', () {
      // The whole point of asking the gallery first is that it says yes. An
      // .avi is a video and iOS Photos refuses it, so the honest thing is to
      // ask where it should go rather than to attempt a write that throws.
      expect(mobile.intentFor(item('movie.avi', 'video/x-msvideo')),
          equals(SaveIntent.ask));
      expect(mobile.intentFor(item('movie.mkv', 'video/x-matroska')),
          equals(SaveIntent.ask));
      expect(mobile.intentFor(item('sticker.webp', 'image/webp')),
          equals(SaveIntent.ask));
    });

    test('camera RAW goes to the gallery like any other photo', () {
      expect(mobile.intentFor(item('DSC_0001.NEF', 'application/octet-stream')),
          equals(SaveIntent.gallery));
    });

    test('a session with only media needs no question', () {
      expect(mobile.anyNeedsAsking([photo, video]), isFalse);
    });

    test('a mixed session needs a question for the file half', () {
      expect(mobile.anyNeedsAsking([photo, document]), isTrue);
    });

    test('an item already saved is not asked about again', () {
      final saved = document.copyWith(savedPath: '/Documents/contract.pdf');
      expect(mobile.anyNeedsAsking([saved]), isFalse);
    });
  });

  group('on Android', () {
    const mobile = SaveDestination(
      isDesktop: false,
      gallery: GalleryFormats(GalleryPlatform.android),
    );

    test('the same photo and video still go to the gallery', () {
      expect(mobile.intentFor(photo), equals(SaveIntent.gallery));
      expect(mobile.intentFor(video), equals(SaveIntent.gallery));
    });

    test('formats only Android stores are not asked about here', () {
      expect(mobile.intentFor(item('sticker.webp', 'image/webp')),
          equals(SaveIntent.gallery));
      expect(mobile.intentFor(item('clip.webm', 'video/webm')),
          equals(SaveIntent.gallery));
    });

    test('formats only iOS stores are asked about here', () {
      expect(mobile.intentFor(item('scan.tiff', 'image/tiff')),
          equals(SaveIntent.ask));
      expect(mobile.intentFor(item('DSC_0001.NEF', 'application/octet-stream')),
          equals(SaveIntent.ask));
    });
  });
}

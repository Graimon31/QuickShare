import 'package:flutter_test/flutter_test.dart';

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

  group('ReceivedItem.kind', () {
    test('photos and videos are media', () {
      expect(photo.kind, equals(ReceivedKind.media));
      expect(video.kind, equals(ReceivedKind.media));
      expect(item('shot.jpg', 'image/jpeg').kind, equals(ReceivedKind.media));
      expect(item('anim.gif', 'image/gif').kind, equals(ReceivedKind.media));
    });

    test('documents and archives are files', () {
      expect(document.kind, equals(ReceivedKind.file));
      expect(archive.kind, equals(ReceivedKind.file));
    });

    test('an image MIME type no gallery accepts is still a file', () {
      // An SVG is image/* but no photo library will take it, and a failed
      // gallery write is worse than an honest "save as file".
      expect(item('logo.svg', 'image/svg+xml').kind, equals(ReceivedKind.file));
    });

    test('the extension decides when the sender gave no usable MIME type', () {
      expect(item('holiday.mov', 'application/octet-stream').kind,
          equals(ReceivedKind.media));
      expect(item('notes.txt', 'application/octet-stream').kind,
          equals(ReceivedKind.file));
    });
  });

  group('on desktop', () {
    const desktop = SaveDestination(isDesktop: true);

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

  group('on mobile', () {
    const mobile = SaveDestination(isDesktop: false);

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
}

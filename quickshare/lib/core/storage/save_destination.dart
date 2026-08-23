import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:quickshare/core/storage/gallery_formats.dart';
import 'package:quickshare/core/storage/received_item.dart';

/// What should happen to an item once it has finished arriving.
enum SaveIntent {
  /// Write it out without asking. Desktop has an obvious, non-shared place for
  /// downloads, and putting a file there is what the user already expects.
  automatic,

  /// Put it in the photo library without asking — that is where a phone user
  /// looks for a photo somebody sent them.
  gallery,

  /// Ask first. On a phone, a document has no obvious home and writing into
  /// shared storage uninvited is not ours to decide.
  ask,
}

/// Decides where each received item goes, per platform and per kind.
///
/// Split out from the UI so the rule is stated once and can be tested without
/// a device: the same decision has to be made by the completion screen, by
/// the "save" button, and by the cleanup that runs when a session is
/// abandoned.
class SaveDestination {
  /// Overridable so the rule can be tested for every platform from one
  /// machine, rather than only for the one the tests happen to run on.
  final bool isDesktop;

  /// Which photo library, if any, is on the other side. On a phone this is
  /// what actually separates "goes to the gallery" from "ask the user": iOS
  /// and Android accept different formats, and neither accepts everything
  /// that is recognisably a photo or a video.
  final GalleryFormats gallery;

  const SaveDestination({required this.isDesktop, required this.gallery});

  factory SaveDestination.forCurrentPlatform() => SaveDestination(
        isDesktop: !kIsWeb &&
            (Platform.isMacOS || Platform.isWindows || Platform.isLinux),
        gallery: GalleryFormats.forCurrentPlatform(),
      );

  SaveIntent intentFor(ReceivedItem item) {
    if (isDesktop) return SaveIntent.automatic;
    return gallery.accepts(item) ? SaveIntent.gallery : SaveIntent.ask;
  }

  /// Whether anything in [items] needs the user to answer a question before
  /// the session can be considered finished.
  bool anyNeedsAsking(Iterable<ReceivedItem> items) =>
      items.any((i) => !i.isSaved && intentFor(i) == SaveIntent.ask);
}

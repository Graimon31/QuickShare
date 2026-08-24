import 'package:quickshare/core/storage/media_saver.dart';
import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// What became of one item after the automatic pass.
class SaveOutcome {
  final ReceivedItem item;

  /// Null when the item was saved, or is still waiting to be asked about.
  final String? error;

  /// Whether the user still has to answer a question about this one.
  final bool awaitingDecision;

  const SaveOutcome({
    required this.item,
    this.error,
    this.awaitingDecision = false,
  });

  bool get failed => error != null;
}

/// Runs the placement rule over a finished transfer.
///
/// Separate from the screen because the same sequence has to happen whether
/// the user is looking at it or not, and because a batch where item seven of
/// twenty fails needs testing without a photo library.
class SaveCoordinator {
  final SaveDestination destination;
  final MediaSaver saver;
  final TransferCache cache;

  const SaveCoordinator({
    required this.destination,
    this.saver = const MediaSaver(),
    this.cache = const TransferCache(),
  });

  /// Saves everything that needs no question, and reports the rest.
  ///
  /// One item failing never stops the others: a batch of twenty photos where
  /// the gallery rejects one should still deliver nineteen.
  Future<List<SaveOutcome>> runAutomatic(List<ReceivedItem> items) async {
    final outcomes = <SaveOutcome>[];

    for (final item in items) {
      switch (destination.intentFor(item)) {
        case SaveIntent.automatic:
          outcomes.add(await _attempt(item, () => saver.saveToDownloads(item)));
        case SaveIntent.gallery:
          outcomes.add(_survivable(
              await _attempt(item, () => saver.saveToGallery(item))));
        case SaveIntent.ask:
          outcomes.add(SaveOutcome(item: item, awaitingDecision: true));
      }
    }
    return outcomes;
  }

  /// A gallery that refuses the file is not the end of it.
  ///
  /// [GalleryFormats] keeps the obvious refusals from being attempted at all,
  /// but it cannot be exhaustive — Matroska on Android depends on the codecs
  /// inside it, and a library can also refuse for reasons that have nothing to
  /// do with the format, such as a permission the user has since revoked.
  /// Whatever the reason, the file is sitting in the cache and can still be
  /// put somewhere the user picks, so a failed gallery write becomes the same
  /// question a document would have asked. Without this the item was reported
  /// as failed, offered no way to save it, and had its cache copy deleted on
  /// the way out of the screen.
  SaveOutcome _survivable(SaveOutcome outcome) => outcome.failed
      ? SaveOutcome(
          item: outcome.item, error: outcome.error, awaitingDecision: true)
      : outcome;

  Future<SaveOutcome> _attempt(
      ReceivedItem item, Future<ReceivedItem> Function() save) async {
    try {
      return SaveOutcome(item: await save());
    } on SaveFailed catch (e) {
      AppLogger.warning('Automatic save failed: $e', tag: 'SAVE');
      return SaveOutcome(item: item, error: e.reason);
    } catch (e) {
      AppLogger.warning('Automatic save failed for ${item.name}: $e',
          tag: 'SAVE');
      return SaveOutcome(item: item, error: '$e');
    }
  }

  /// Saves the items the user was asked about into [directory].
  Future<List<SaveOutcome>> saveChosen(
      List<ReceivedItem> items, String directory) async {
    final outcomes = <SaveOutcome>[];
    for (final item in items) {
      outcomes.add(await _attempt(item, () => saver.saveTo(item, directory)));
    }
    return outcomes;
  }

  /// Empties the session's staging area, once the user is done with it.
  ///
  /// Everything goes, saved and unsaved alike. The unsaved ones were declined
  /// — that is the "left without saving" case, and keeping them would be
  /// keeping files nobody asked for. The saved ones already exist somewhere
  /// permanent, so their cache copy is a second copy of a file the user has;
  /// leaving it behind is how an app quietly grows to hold a gigabyte of
  /// duplicates that only a restart clears.
  ///
  /// Saved means verified, which is what makes this safe to do: a gallery
  /// write that failed throws, and a copy that failed throws, so nothing gets
  /// here with [ReceivedItem.savedPath] set unless the write came back clean.
  Future<int> discardSession(Iterable<SaveOutcome> outcomes) {
    final paths = [for (final o in outcomes) o.item.cachePath];
    if (paths.isEmpty) return Future.value(0);
    return cache.discard(paths);
  }
}

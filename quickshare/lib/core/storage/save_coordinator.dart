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
          outcomes.add(await _attempt(item, () => saver.saveToGallery(item)));
        case SaveIntent.ask:
          outcomes.add(SaveOutcome(item: item, awaitingDecision: true));
      }
    }
    return outcomes;
  }

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

  /// Drops whatever was never saved, when a session is walked away from.
  ///
  /// Only the unsaved ones: an item already copied to Downloads or handed to
  /// the gallery is finished with, and its cache copy is dead weight either
  /// way — but deleting a *saved* item's cache copy here would be indistinguishable
  /// from deleting the item itself if the save had silently failed.
  Future<int> discardUnsaved(Iterable<SaveOutcome> outcomes) {
    final orphans = [
      for (final o in outcomes)
        if (!o.item.isSaved) o.item.cachePath,
    ];
    if (orphans.isEmpty) return Future.value(0);
    return cache.discard(orphans);
  }
}

import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Raised when an item could not be written to its destination.
///
/// Carries the item so the UI can name what failed — a batch of twenty photos
/// where one fails should say which one.
class SaveFailed implements Exception {
  final ReceivedItem item;
  final String reason;
  const SaveFailed(this.item, this.reason);

  @override
  String toString() => 'could not save ${item.name}: $reason';
}

/// Moves items out of the transfer cache and into somewhere permanent.
///
/// The cache copy is deliberately left in place: the caller decides when a
/// session is finished with, and deleting here would make a partially-failed
/// batch unrecoverable.
class MediaSaver {
  /// Overridable for tests, which cannot write to a real photo library.
  final Future<void> Function(String path, {String? album})? saveImageHook;
  final Future<void> Function(String path, {String? album})? saveVideoHook;
  final Future<Directory?> Function()? downloadsHook;

  const MediaSaver({
    this.saveImageHook,
    this.saveVideoHook,
    this.downloadsHook,
  });

  /// Same saver, a different downloads folder.
  ///
  /// Used to plug the user's chosen save location in for one batch without
  /// disturbing whatever the caller already set for [saveImageHook] /
  /// [saveVideoHook] — a test's gallery stand-ins, most often.
  MediaSaver withDownloadsHook(Future<Directory?> Function() hook) =>
      MediaSaver(
        saveImageHook: saveImageHook,
        saveVideoHook: saveVideoHook,
        downloadsHook: hook,
      );

  /// Writes [item] into the device photo library.
  ///
  /// Photos and videos take different platform calls, so the kind is decided
  /// from the MIME type rather than left to the plugin to guess.
  Future<ReceivedItem> saveToGallery(ReceivedItem item) async {
    final isVideo = item.mimeType.toLowerCase().startsWith('video/') ||
        const {'.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm', '.3gp'}
            .contains(p.extension(item.name).toLowerCase());

    try {
      if (isVideo) {
        final save = saveVideoHook ?? Gal.putVideo;
        await save(item.cachePath);
      } else {
        final save = saveImageHook ?? Gal.putImage;
        await save(item.cachePath);
      }
      AppLogger.info('Saved ${item.name} to the gallery', tag: 'SAVE');
      // The gallery owns the copy now and does not hand back a path.
      return item.copyWith(savedPath: 'gallery');
    } on GalException catch (e) {
      throw SaveFailed(item, _describe(e));
    } catch (e) {
      throw SaveFailed(item, '$e');
    }
  }

  /// Copies [item] into the platform Downloads directory.
  Future<ReceivedItem> saveToDownloads(ReceivedItem item) async {
    final resolve = downloadsHook ?? getDownloadsDirectory;
    final target = await resolve() ?? await getApplicationDocumentsDirectory();
    if (!await target.exists()) await target.create(recursive: true);

    final destination = _uniquePath(p.join(target.path, item.name));
    await _place(item, destination);
    AppLogger.info('Saved ${item.name} to $destination', tag: 'SAVE');
    return item.copyWith(savedPath: destination);
  }

  /// Copies [item] into a directory the user chose.
  Future<ReceivedItem> saveTo(ReceivedItem item, String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) await dir.create(recursive: true);
    final destination = _uniquePath(p.join(directory, item.name));
    await _place(item, destination);
    return item.copyWith(savedPath: destination);
  }

  /// Moves one item to [destination], folder and all if that is what it is.
  ///
  /// A rename first, and a copy only if that fails. Both land the same file
  /// in the same place, but a rename is a change of name in a directory
  /// entry — instant, whatever the size — while a copy reads and writes
  /// every byte a second time. The transfer cache and the destination are
  /// usually the same volume, so the fast path is the ordinary one: a
  /// gigabyte that took a minute to copy out of the cache now takes no
  /// measurable time at all.
  ///
  /// The copy fallback is not an error path so much as the other half of the
  /// rule: a rename cannot cross a filesystem, and a phone saving into a
  /// user-picked folder, or a desktop pointed at an external disk, crosses
  /// one every time. Any failure falls through to it — if the reason was not
  /// the boundary but something real, the copy raises it just the same.
  Future<void> _place(ReceivedItem item, String destination) async {
    try {
      try {
        if (item.isDirectory) {
          await Directory(item.cachePath).rename(destination);
        } else {
          await File(item.cachePath).rename(destination);
        }
        return;
      } on FileSystemException {
        // Not the same filesystem, most likely. Copy instead.
      }

      if (item.isDirectory) {
        await _copyTree(Directory(item.cachePath), Directory(destination));
      } else {
        await File(item.cachePath).copy(destination);
      }
    } on FileSystemException catch (e) {
      throw SaveFailed(item, e.message);
    }
  }

  /// Recreates [source] under [target], keeping the structure the sender
  /// chose to send.
  static Future<void> _copyTree(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final destination = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyTree(entity, Directory(destination));
      } else if (entity is File) {
        await entity.copy(destination);
      }
      // Links are skipped: a link into the cache would dangle the moment the
      // cache is cleared, which is worse than not copying it.
    }
  }

  /// Never silently overwrites something already there.
  static String _uniquePath(String path) {
    var candidate = path;
    var counter = 1;
    while (File(candidate).existsSync() || Directory(candidate).existsSync()) {
      final ext = p.extension(path);
      final stem = p.basenameWithoutExtension(path);
      candidate = p.join(p.dirname(path), '$stem ($counter)$ext');
      counter++;
    }
    return candidate;
  }

  /// Turns a plugin error into something worth showing a person.
  static String _describe(GalException e) => switch (e.type) {
        GalExceptionType.accessDenied =>
          'permission to the photo library was denied',
        GalExceptionType.notEnoughSpace => 'there is not enough free space',
        GalExceptionType.notSupportedFormat =>
          'the gallery does not accept this format',
        GalExceptionType.unexpected => 'an unexpected error occurred',
      };
}

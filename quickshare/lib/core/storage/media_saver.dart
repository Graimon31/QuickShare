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
    try {
      await File(item.cachePath).copy(destination);
    } on FileSystemException catch (e) {
      throw SaveFailed(item, e.message);
    }
    AppLogger.info('Saved ${item.name} to $destination', tag: 'SAVE');
    return item.copyWith(savedPath: destination);
  }

  /// Copies [item] into a directory the user chose.
  Future<ReceivedItem> saveTo(ReceivedItem item, String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) await dir.create(recursive: true);
    final destination = _uniquePath(p.join(directory, item.name));
    try {
      await File(item.cachePath).copy(destination);
    } on FileSystemException catch (e) {
      throw SaveFailed(item, e.message);
    }
    return item.copyWith(savedPath: destination);
  }

  /// Never silently overwrites something already there.
  static String _uniquePath(String path) {
    var candidate = path;
    var counter = 1;
    while (File(candidate).existsSync()) {
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

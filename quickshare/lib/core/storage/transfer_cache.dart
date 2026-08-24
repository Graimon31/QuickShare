import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Where an incoming transfer lands before the user decides to keep it.
///
/// Everything arrives here first, on every platform. Nothing is written
/// straight to Downloads or the photo library any more, for two reasons: on
/// iOS and Android the app has no business putting files in shared storage
/// without being asked, and a transfer that is abandoned half-way should not
/// leave anything behind.
///
/// The directory is the OS cache directory rather than documents, so the
/// system may also reclaim it under storage pressure — which is exactly the
/// right semantics for "not saved yet".
class TransferCache {
  /// Named so it is recognisable in a file manager or a storage breakdown.
  static const _folderName = 'incoming';

  final Directory Function()? _overrideRoot;

  const TransferCache({Directory Function()? overrideRoot})
      : _overrideRoot = overrideRoot;

  /// The cache directory, created if missing.
  Future<Directory> directory() async {
    final root = _overrideRoot?.call() ??
        await getApplicationCacheDirectory().catchError(
          // Not every platform implements the cache directory; a temp
          // directory has the same "safe to delete" contract.
          (_) async => await getTemporaryDirectory(),
        );
    final dir = Directory(p.join(root.path, _folderName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// A directory of its own for one incoming session.
  ///
  /// The transports that deliver a *set* of things — a QHTP folder, a
  /// multi-file Bluetooth batch — need to know afterwards which entries were
  /// theirs, and the only honest way to answer that is to have given them
  /// somewhere nobody else was writing. Listing the shared cache root instead
  /// would sweep up another transfer's files that are still waiting for their
  /// own decision, and then offer to save or delete them.
  Future<Directory> sessionDirectory() async {
    final root = await directory();
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final dir = Directory(p.join(root.path, 's_$stamp'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Whatever a session left behind in its own directory, as items to decide
  /// about.
  ///
  /// Read from the filesystem rather than from a transport's own bookkeeping,
  /// because the transports disagree about what they can report: QHTP
  /// delivers whatever the sender picked — a flat set of files, or a folder
  /// with a thousand things under it — and the native Bluetooth channel hands
  /// back one path. The directory listing is the one description all of them
  /// agree on.
  ///
  /// Top level only, sorted by name: a folder is one item to decide about,
  /// not a thousand.
  static List<ReceivedItem> itemsIn(Directory session) {
    try {
      final entries = session.listSync(followLinks: false)
        ..sort((a, b) => p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase()));
      return [
        for (final entity in entries)
          ReceivedItem.fromCacheEntity(
            entity,
            lookupMimeType(entity.path) ?? 'application/octet-stream',
          ),
      ];
    } on FileSystemException catch (e) {
      AppLogger.warning('Could not list a received session: $e', tag: 'CACHE');
      return const [];
    }
  }

  /// Total bytes currently held, for the settings screen.
  ///
  /// Walks the tree rather than trusting a running total: the OS can evict
  /// cache contents on its own, and a counter we maintain would drift into
  /// claiming space that is no longer used.
  Future<int> size() async {
    final dir = await directory();
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } on FileSystemException {
            // Vanished between listing and measuring; it occupies nothing.
          }
        }
      }
    } on FileSystemException catch (e) {
      AppLogger.warning('Could not measure the transfer cache: $e',
          tag: 'CACHE');
    }
    return total;
  }

  /// Deletes everything in the cache and reports how much was freed.
  ///
  /// Measures first so the caller can tell the user what actually happened —
  /// "Cache cleared" with no number is indistinguishable from a no-op.
  Future<int> clear() async {
    final freed = await size();
    final dir = await directory();
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await dir.create(recursive: true);
      AppLogger.info('Transfer cache cleared, $freed bytes freed', tag: 'CACHE');
    } on FileSystemException catch (e) {
      AppLogger.warning('Could not clear the transfer cache: $e', tag: 'CACHE');
      return 0;
    }
    return freed;
  }

  /// Removes exactly [paths], for a session the user walked away from.
  ///
  /// Scoped to the paths a session produced rather than clearing everything,
  /// because another transfer's files may be sitting in the cache waiting for
  /// their own decision.
  Future<int> discard(Iterable<String> paths) async {
    final dir = await directory();
    var freed = 0;
    for (final path in paths) {
      // Never delete outside the cache, whatever the caller passes.
      if (!p.isWithin(dir.path, path)) {
        AppLogger.warning(
            'Refusing to discard $path: outside the transfer cache',
            tag: 'CACHE');
        continue;
      }
      try {
        // A QHTP session can deliver a folder, so what is being discarded is
        // not always a single file.
        final directory = Directory(path);
        if (await directory.exists()) {
          freed += await _measure(directory);
          await directory.delete(recursive: true);
          continue;
        }
        final file = File(path);
        if (await file.exists()) {
          freed += await file.length();
          await file.delete();
        }
      } on FileSystemException catch (e) {
        AppLogger.warning('Could not discard $path: $e', tag: 'CACHE');
      }
    }
    await _pruneEmptySessions(dir);
    if (freed > 0) {
      AppLogger.info('Discarded ${paths.length} item(s), $freed bytes',
          tag: 'CACHE');
    }
    return freed;
  }

  /// Removes session directories that have nothing left in them.
  ///
  /// They cost no space to speak of, but a cache root filling up with empty
  /// folders is the kind of thing a user finds in a storage breakdown and
  /// reasonably reads as a leak.
  static Future<void> _pruneEmptySessions(Directory root) async {
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        if (!p.basename(entity.path).startsWith('s_')) continue;
        if (await entity.list(followLinks: false).isEmpty) {
          await entity.delete();
        }
      }
    } on FileSystemException {
      // Housekeeping; never worth failing a discard over.
    }
  }

  /// Bytes held under [directory], following the tree.
  static Future<int> _measure(Directory directory) async {
    var total = 0;
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // Vanished between listing and measuring; it occupies nothing.
        }
      }
    }
    return total;
  }

  /// Human-readable size for the settings screen.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
  }
}

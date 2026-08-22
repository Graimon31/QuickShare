import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
      final file = File(path);
      try {
        if (await file.exists()) {
          freed += await file.length();
          await file.delete();
        }
      } on FileSystemException catch (e) {
        AppLogger.warning('Could not discard $path: $e', tag: 'CACHE');
      }
    }
    if (freed > 0) {
      AppLogger.info('Discarded ${paths.length} unsaved item(s), $freed bytes',
          tag: 'CACHE');
    }
    return freed;
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

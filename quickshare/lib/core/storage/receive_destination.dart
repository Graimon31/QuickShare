import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/save_location_store.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Where an incoming transfer is written, and what happens to it there.
///
/// On desktop the bytes go straight into the folder the user keeps things in —
/// Downloads, or a location they picked — with no staging copy: a crash-safe
/// `.qs.partial` is renamed into place and that is the file. [placed] is true,
/// and the completion screen only has to report what landed.
///
/// On a phone there is no folder outside the sandbox to write into, so the
/// transfer still lands in the transfer cache and [SaveDestination] decides
/// afterwards whether it goes to the gallery or waits for the user. [placed]
/// is false.
class ReceiveDestination {
  const ReceiveDestination._(this.path, {required this.placed, Future<void> Function()? release})
      : _release = release;

  /// The directory the transport writes into.
  final String path;

  /// True when [path] is the file's real home; false when it is the cache and
  /// the completion screen still has to place what arrived.
  final bool placed;

  final Future<void> Function()? _release;

  /// Closes whatever [resolve] opened — the macOS security scope for a custom
  /// folder. Call it once the transfer is done, success or fail. A no-op
  /// otherwise.
  Future<void> release() async {
    try {
      await _release?.call();
    } catch (e) {
      AppLogger.warning('ReceiveDestination.release failed: $e', tag: 'SAVE');
    }
  }

  static Future<ReceiveDestination> resolve({
    SaveDestination? destination,
    SaveLocationStore saveLocation = const SaveLocationStore(),
    TransferCache cache = const TransferCache(),
  }) async {
    final dest = destination ?? SaveDestination.forCurrentPlatform();

    if (!dest.isDesktop) {
      final dir = await cache.sessionDirectory();
      return ReceiveDestination._(dir.path, placed: false);
    }

    // A folder the user chose. On macOS resolveForWriting() opens the security
    // scope, which has to stay open for the whole transfer, not just the
    // rename — hence release() rather than a scope around one copy.
    final custom = await saveLocation.resolveForWriting();
    if (custom != null) {
      if (!await custom.exists()) await custom.create(recursive: true);
      _sweepInBackground(custom.path);
      return ReceiveDestination._(custom.path,
          placed: true, release: saveLocation.release);
    }

    final downloads = await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    if (!await downloads.exists()) await downloads.create(recursive: true);
    _sweepInBackground(downloads.path);
    return ReceiveDestination._(downloads.path, placed: true);
  }

  /// Clears `.qs.partial` debris a crashed transfer left in the destination.
  ///
  /// Fire-and-forget at the top of a transfer rather than at startup: it is
  /// the moment the folder is known and, on macOS, already inside an open
  /// scope. The cutoff keeps it well clear of anything a second running copy
  /// of the app might be writing right now.
  static void _sweepInBackground(String path) {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
    sweepPartials(path, before: cutoff).catchError((Object e) {
      AppLogger.warning('Partial sweep of $path failed: $e', tag: 'DISK');
      return 0;
    });
  }
}

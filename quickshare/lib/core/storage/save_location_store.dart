import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/storage/save_location_bookmark.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// A custom save folder the user picked, or nothing — meaning "use this
/// platform's default", which the caller already knows how to do.
class SaveLocation {
  final String path;

  /// macOS only. Empty on every other platform, where a plain path is
  /// writable forever with no further ceremony.
  final String bookmark;

  const SaveLocation({required this.path, this.bookmark = ''});

  Map<String, dynamic> toJson() => {'path': path, 'bookmark': bookmark};

  static SaveLocation fromJson(Map<String, dynamic> json) => SaveLocation(
        path: json['path'] as String? ?? '',
        bookmark: json['bookmark'] as String? ?? '',
      );
}

/// Persists the desktop "where do received files go" choice.
///
/// Deliberately separate from [SaveDestination], which decides *whether* a
/// question needs asking at all (gallery on a phone, a prompt for a document)
/// — this only holds the one fact a desktop user can override: which folder
/// "automatic" actually means. Nothing here runs on iOS or Android; neither
/// platform lets an app write into a folder of the user's choosing outside
/// its own sandbox, so there is no setting to offer there.
class SaveLocationStore {
  static const _fileName = 'save_location.json';

  final Directory Function()? _overrideDir;
  final SaveLocationBookmark _bookmark;

  const SaveLocationStore({
    Directory Function()? overrideDir,
    SaveLocationBookmark bookmark = const SaveLocationBookmark(),
  })  : _overrideDir = overrideDir,
        _bookmark = bookmark;

  Future<File> _file() async {
    final dir = _overrideDir?.call() ?? await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, _fileName));
  }

  /// The saved choice, or null if the user never set one (use the default).
  Future<SaveLocation?> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return null;
      final location = SaveLocation.fromJson(json);
      return location.path.isEmpty ? null : location;
    } catch (e) {
      AppLogger.warning('Could not read the saved location: $e', tag: 'SAVE');
      return null;
    }
  }

  /// Records [directoryPath] as the chosen folder.
  ///
  /// On macOS this must run right after the folder picker returns — creating
  /// the bookmark needs the sandbox's transient grant for the folder, which
  /// does not survive much delay. Everywhere else it is a plain string with
  /// nothing further to capture.
  Future<void> set(String directoryPath) async {
    final bookmark = SaveLocationBookmark.isSupported
        ? await _bookmark.create(directoryPath)
        : '';
    final file = await _file();
    await file.writeAsString(
        jsonEncode(SaveLocation(path: directoryPath, bookmark: bookmark).toJson()));
  }

  /// Clears the choice, reverting to this platform's default folder.
  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }

  /// Refreshes a bookmark that resolved as stale, so the next launch does
  /// not have to pay the same staleness warning again.
  Future<void> _refresh(SaveLocation location, String freshPath) async {
    try {
      await set(freshPath);
    } catch (e) {
      // Not worth failing the save over; the stale bookmark still worked
      // this once, and the next save will just try to refresh it again.
      AppLogger.warning('Could not refresh a stale bookmark: $e', tag: 'SAVE');
    }
    if (freshPath != location.path) {
      AppLogger.info(
          'Saved folder moved from ${location.path} to $freshPath',
          tag: 'SAVE');
    }
  }

  /// Resolves the chosen folder into a directory that is genuinely writable
  /// right now, or null if nothing was ever chosen.
  ///
  /// On macOS this opens the security scope; [release] must be called once
  /// the caller is done writing to it. Everywhere else the scope concept
  /// does not exist and this is just the stored path.
  Future<Directory?> resolveForWriting() async {
    final location = await read();
    if (location == null) return null;

    if (!SaveLocationBookmark.isSupported) {
      return Directory(location.path);
    }

    if (location.bookmark.isEmpty) {
      // Set on a different platform, or before this store existed. Nothing
      // to resolve; the plain path is what there is.
      return Directory(location.path);
    }

    final access = await _bookmark.startAccessing(location.bookmark);
    if (access.stale) await _refresh(location, access.path);
    return Directory(access.path);
  }

  /// Releases whatever [resolveForWriting] opened. A no-op off macOS.
  Future<void> release() => _bookmark.stopAccessing();
}

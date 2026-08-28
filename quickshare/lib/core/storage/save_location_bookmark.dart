import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper over the native security-scoped-bookmark bridge.
///
/// A no-op that answers "unsupported" everywhere except macOS: on Windows
/// and Linux a plain absolute path is writable forever with no OS ceremony
/// at all, and this class exists only for the one platform where "remember
/// this folder" needs more than a string.
class SaveLocationBookmark {
  static const _channel = MethodChannel('quickshare/save_location');

  const SaveLocationBookmark();

  static bool get isSupported => !kIsWeb && Platform.isMacOS;

  /// Turns a path the user just picked into bookmark data, while the
  /// sandbox's transient grant for it is still live.
  ///
  /// Must be called right after the folder picker returns — any delay risks
  /// the grant having already lapsed, and a bookmark cannot be created for a
  /// folder this process cannot currently reach.
  Future<String> create(String path) async {
    if (!isSupported) {
      throw const SaveLocationBookmarkException(
          'security-scoped bookmarks only exist on macOS');
    }
    try {
      final result =
          await _channel.invokeMethod<String>('createBookmark', {'path': path});
      if (result == null || result.isEmpty) {
        throw const SaveLocationBookmarkException('the bookmark came back empty');
      }
      return result;
    } on PlatformException catch (e) {
      throw SaveLocationBookmarkException(e.message ?? 'could not bookmark $path');
    }
  }

  /// Resolves [bookmark] and opens its security scope, returning the path
  /// that is now genuinely writable — until the matching [stopAccessing].
  ///
  /// [BookmarkAccess.stale] is true when the folder moved or was renamed
  /// since the bookmark was made. Access is still granted this once; the
  /// caller should mint a fresh bookmark from the returned path afterwards
  /// rather than fail a save that would otherwise succeed.
  Future<BookmarkAccess> startAccessing(String bookmark) async {
    if (!isSupported) {
      throw const SaveLocationBookmarkException(
          'security-scoped bookmarks only exist on macOS');
    }
    try {
      final result = await _channel
          .invokeMethod<Map<Object?, Object?>>('startAccessing', {'bookmark': bookmark});
      final path = result?['path'] as String?;
      if (path == null) {
        throw const SaveLocationBookmarkException('resolved with no path');
      }
      return BookmarkAccess(path: path, stale: result?['stale'] as bool? ?? false);
    } on PlatformException catch (e) {
      throw SaveLocationBookmarkException(
          e.message ?? 'could not resolve the saved folder');
    }
  }

  /// Closes whatever scope [startAccessing] opened. Safe to call even if
  /// nothing is open.
  Future<void> stopAccessing() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stopAccessing');
    } on PlatformException {
      // Nothing meaningful to do with a failed cleanup call.
    }
  }
}

class BookmarkAccess {
  final String path;
  final bool stale;
  const BookmarkAccess({required this.path, required this.stale});
}

class SaveLocationBookmarkException implements Exception {
  final String message;
  const SaveLocationBookmarkException(this.message);
  @override
  String toString() => message;
}

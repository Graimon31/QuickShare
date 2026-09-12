import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:quickshare/core/constants/app_constants.dart';

/// Unified path and filename sanitizer protecting all transfer transports
/// (QHTP, WebRTC, Bluetooth) against path traversal, invalid characters,
/// and DOS/Windows reserved device names.
class PathSanitizer {
  const PathSanitizer._();

  static final _windowsReservedPattern = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
    caseSensitive: false,
  );

  /// Checks if [name] matches DOS/Windows reserved device names
  /// (e.g., CON, PRN, AUX, NUL, COM1..COM9, LPT1..LPT9).
  static bool isWindowsReserved(String name) {
    return _windowsReservedPattern.hasMatch(name.trim());
  }

  /// Sanitizes a single filename or directory segment.
  ///
  /// Replaces control characters and filesystem-illegal characters with '_',
  /// falls back to [defaultName] if empty or only dots, prepends '_' if matching
  /// a Windows reserved device name, and truncates to [AppConstants.qhtpMaxNameBytes]
  /// UTF-8 bytes keeping the file extension.
  static String sanitizeSegment(
    String segment, {
    String defaultName = 'item',
    int maxBytes = AppConstants.qhtpMaxNameBytes,
  }) {
    var clean = segment
        .replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_')
        .trim();

    if (clean.isEmpty || clean.replaceAll('.', '').isEmpty) {
      clean = defaultName;
    }

    if (isWindowsReserved(clean)) {
      clean = '_$clean';
    }

    return fitToByteLimit(clean, maxBytes: maxBytes, defaultName: defaultName);
  }

  /// Shortens a name that exceeds [maxBytes] in UTF-8, keeping its extension.
  static String fitToByteLimit(
    String name, {
    int maxBytes = AppConstants.qhtpMaxNameBytes,
    String defaultName = 'item',
  }) {
    if (utf8.encode(name).length <= maxBytes) return name;

    final extension = p.extension(name);
    // An "extension" longer than a quarter of the budget is not an extension,
    // it is a name with a dot in it.
    final keptExtension =
        utf8.encode(extension).length <= maxBytes ~/ 4 ? extension : '';
    final stem = name.substring(0, name.length - extension.length);
    final stemBudget = maxBytes - utf8.encode(keptExtension).length;

    final buffer = StringBuffer();
    var used = 0;
    for (final rune in stem.runes) {
      final encoded = utf8.encode(String.fromCharCode(rune)).length;
      if (used + encoded > stemBudget) break;
      buffer.writeCharCode(rune);
      used += encoded;
    }
    final shortened = '$buffer$keptExtension';
    return shortened.isEmpty ? defaultName : shortened;
  }

  /// Cleans a relative path segment by segment. Traversal segments ('.' and '..')
  /// are stripped.
  static String sanitizeRelativePath(
    String rawPath, {
    String defaultName = 'item',
    int maxBytes = AppConstants.qhtpMaxNameBytes,
  }) {
    final segments = rawPath
        .replaceAll(r'\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .map((s) =>
            sanitizeSegment(s, defaultName: defaultName, maxBytes: maxBytes))
        .toList();

    if (segments.isEmpty) return defaultName;
    return p.joinAll(segments);
  }

  /// Safely resolves [relativePath] inside [baseDir], preventing path traversal.
  static String resolveSafePath(
    String relativePath,
    String baseDir, {
    String defaultName = 'item',
    int maxBytes = AppConstants.qhtpMaxNameBytes,
  }) {
    if (baseDir.isEmpty) {
      throw Exception('Target base directory cannot be empty');
    }
    final cleanRel = sanitizeRelativePath(relativePath,
        defaultName: defaultName, maxBytes: maxBytes);
    final resolvedPath = p.normalize(p.join(baseDir, cleanRel));
    if (!p.isWithin(baseDir, resolvedPath) && resolvedPath != baseDir) {
      throw Exception('Path traversal detected: $relativePath');
    }
    return resolvedPath;
  }
}

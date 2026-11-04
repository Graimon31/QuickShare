import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:quickshare/core/constants/app_constants.dart';

/// Unified path and filename sanitizer protecting all transfer transports
/// (QHTP, WebRTC, Bluetooth) against path traversal, invalid characters,
/// and DOS/Windows reserved device names.
class PathSanitizer {
  const PathSanitizer._();

  /// How many UTF-8 bytes one cleaned name may have.
  ///
  /// The protocol allows 255 ([AppConstants.qhtpMaxNameBytes], the filesystem's
  /// own limit), and a name of 255 is a name the filesystem takes — but every
  /// received file is first written as `<name>.qs.partial` (11 bytes more) and
  /// may be numbered `<name> (n)` when its name is taken. A name cut to exactly
  /// 255 failed at the partial with "File name too long", after three retries.
  /// So the name leaves room for both: 255 − 11 − 7 (` (9999)`).
  static const int maxSegmentBytes = AppConstants.qhtpMaxNameBytes - 18;

  /// The device names Windows reserves in every folder, whatever follows them:
  /// `CON`, `PRN`, `AUX`, `NUL`, `COM1`..`COM9`, `LPT1`..`LPT9` (the
  /// superscript digits `COM¹ COM² COM³ LPT¹ LPT² LPT³` too — Windows treats
  /// those as the same devices), and the console buffers `CONIN$` and
  /// `CONOUT$`. A name is reserved with an extension (`con.txt`), with spaces
  /// before it (`con .txt`), or with a dot and nothing after (`nul.`).
  static final _windowsReservedPattern = RegExp(
    r'^(con|prn|aux|nul|com[1-9\u00B9\u00B2\u00B3]|lpt[1-9\u00B9\u00B2\u00B3]|conin\$|conout\$)\s*(\..*)?$',
    caseSensitive: false,
  );

  /// Checks if [name] matches DOS/Windows reserved device names
  /// (e.g., CON, PRN, AUX, NUL, COM1..COM9, LPT1..LPT9, CONIN$, CONOUT$).
  static bool isWindowsReserved(String name) {
    return _windowsReservedPattern.hasMatch(name.trim());
  }

  /// Sanitizes a single filename or directory segment.
  ///
  /// Replaces control characters and filesystem-illegal characters with '_',
  /// falls back to [defaultName] if empty or only dots, prepends '_' if matching
  /// a Windows reserved device name, and truncates to [maxSegmentBytes] UTF-8
  /// bytes keeping the file extension.
  static String sanitizeSegment(
    String segment, {
    String defaultName = 'item',
    int maxBytes = maxSegmentBytes,
  }) {
    final clean = segment
        .replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_')
        .trim();

    // Tidied, cut to fit, and tidied again, until nothing changes. The cut can
    // land anywhere: right after a space or a dot, or just after `com1` with
    // only spaces behind it, and the name that is left would then be changed
    // by Windows behind the program's back.
    var name = _tidy(clean, defaultName);
    for (var pass = 0; pass < 8; pass++) {
      final next = _tidy(
          fitToByteLimit(name, maxBytes: maxBytes, defaultName: defaultName),
          defaultName);
      if (next == name) break;
      name = next;
    }
    return name;
  }

  /// What every cleaned name must be, whatever length it has.
  static String _tidy(String name, String defaultName) {
    // Windows silently drops trailing dots and spaces, so `report.pdf.` and
    // `report.pdf` are one name there and two here — two files fighting over
    // one, and a name Explorer cannot always open. Dropped on every platform
    // so a file is called the same wherever it lands.
    var clean = name.replaceFirst(RegExp(r'[. ]+$'), '');

    if (clean.isEmpty || clean.replaceAll('.', '').isEmpty) {
      clean = defaultName;
    }

    if (isWindowsReserved(clean)) {
      clean = '_$clean';
    }

    return clean;
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
    int maxBytes = maxSegmentBytes,
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
    int maxBytes = maxSegmentBytes,
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

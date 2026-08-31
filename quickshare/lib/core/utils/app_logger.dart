import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

enum LogLevel { debug, info, warning, error }

class AppLogger {
  static const int _maxInMemoryLogs = 1000;

  /// How far back the on-disk log reaches. Anything older is dropped at
  /// launch, so the journal the user can copy from Settings stays a
  /// rolling window rather than a file that only ever grows.
  static const Duration _retention = Duration(days: 7);
  static final List<String> _inMemoryLogs = [];
  static File? _logFile;
  static final StreamController<String> _logStreamController =
      StreamController<String>.broadcast();

  static Stream<String> get logStream => _logStreamController.stream;

  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File(p.join(dir.path, 'directdrop.log'));
      await _pruneToRetention();
      info('AppLogger initialized at ${_logFile?.path}');
    } catch (e) {
      debugPrint('AppLogger init error: $e');
    }
  }

  static void debug(String message, {String tag = 'APP'}) {
    _log(LogLevel.debug, tag, message);
  }

  static void info(String message, {String tag = 'APP'}) {
    _log(LogLevel.info, tag, message);
  }

  static void warning(String message, {String tag = 'APP'}) {
    _log(LogLevel.warning, tag, message);
  }

  static void error(String message, {dynamic error, StackTrace? stackTrace, String tag = 'APP'}) {
    final fullMsg = error != null ? '$message | Error: $error' : message;
    _log(LogLevel.error, tag, fullMsg);
    if (stackTrace != null) {
      _log(LogLevel.error, tag, stackTrace.toString());
    }
  }

  static void _log(LogLevel level, String tag, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final levelStr = level.name.toUpperCase().padRight(5);
    final logLine = '[$timestamp] [$levelStr] [$tag] $message';

    debugPrint(logLine);

    _inMemoryLogs.add(logLine);
    if (_inMemoryLogs.length > _maxInMemoryLogs) {
      _inMemoryLogs.removeAt(0);
    }

    _logStreamController.add(logLine);

    if (_logFile != null) {
      try {
        _logFile!.writeAsStringSync('$logLine\n', mode: FileMode.append, flush: true);
      } catch (_) {}
    }
  }

  static List<String> getInMemoryLogs() => List.unmodifiable(_inMemoryLogs);

  static Future<String> getLogFileContent() async {
    if (_logFile != null && await _logFile!.exists()) {
      try {
        return await _logFile!.readAsString();
      } catch (e) {
        return 'Error reading log file: $e';
      }
    }
    return _inMemoryLogs.join('\n');
  }

  static Future<File?> getLogFile() async {
    if (_logFile != null && await _logFile!.exists()) {
      return _logFile;
    }
    return null;
  }

  /// Drops every log entry older than [_retention] and rewrites the file.
  ///
  /// Works line by line off the `[ISO-8601]` stamp each entry opens with; a
  /// line without one (a wrapped stack trace) keeps whatever verdict its
  /// entry's first line got, so a kept error keeps its trace and a dropped
  /// one takes its trace with it.
  static Future<void> _pruneToRetention() async {
    final file = _logFile;
    if (file == null || !await file.exists()) return;
    try {
      final lines = (await file.readAsString()).split('\n');
      final kept = retainSince(
          lines, DateTime.now().subtract(_retention));
      if (kept.length != lines.length) {
        await file.writeAsString(kept.join('\n'));
      }
    } catch (_) {
      // Housekeeping only — never let it get in the way of logging.
    }
  }

  /// The lines of a log at or after [cutoff].
  ///
  /// Each entry opens with an `[ISO-8601]` stamp; a line without one (a
  /// wrapped stack trace) inherits its entry's verdict, so a kept error keeps
  /// its trace and a dropped one takes its trace with it.
  @visibleForTesting
  static List<String> retainSince(List<String> lines, DateTime cutoff) {
    final kept = <String>[];
    var keeping = true;
    for (final line in lines) {
      final at = _entryTime(line);
      if (at != null) keeping = !at.isBefore(cutoff);
      if (keeping) kept.add(line);
    }
    return kept;
  }

  /// The timestamp a log line opens with, or null if it does not open with one.
  static DateTime? _entryTime(String line) {
    if (!line.startsWith('[')) return null;
    final end = line.indexOf(']');
    if (end < 2) return null;
    return DateTime.tryParse(line.substring(1, end));
  }

  static Future<void> clearLogs() async {
    _inMemoryLogs.clear();
    if (_logFile != null && await _logFile!.exists()) {
      try {
        await _logFile!.writeAsString('');
      } catch (_) {}
    }
  }
}

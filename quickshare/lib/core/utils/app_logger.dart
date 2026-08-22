import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

enum LogLevel { debug, info, warning, error }

class AppLogger {
  static const int _maxInMemoryLogs = 1000;
  static final List<String> _inMemoryLogs = [];
  static File? _logFile;
  static final StreamController<String> _logStreamController =
      StreamController<String>.broadcast();

  static Stream<String> get logStream => _logStreamController.stream;

  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File(p.join(dir.path, 'directdrop.log'));
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

  static Future<void> clearLogs() async {
    _inMemoryLogs.clear();
    if (_logFile != null && await _logFile!.exists()) {
      try {
        await _logFile!.writeAsString('');
      } catch (_) {}
    }
  }
}

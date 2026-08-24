import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// What happened on one transfer, in terms a person can read out loud.
///
/// Everything here was already being written to the log, and the log is the
/// problem: getting one line out of it meant walking somebody through the
/// Terminal on a machine three cities away, twice, and still not having the
/// answer. The facts that decide whether a transfer was slow because of us or
/// because of somebody's uplink belong on screen.
class TransferReport {
  final DateTime at;

  /// 'sent' or 'received'.
  final String role;

  /// How it travelled, in the app's own terms: 'Direct Wi-Fi link',
  /// 'Local network', 'Internet (peer to peer)', 'Internet (relayed)',
  /// 'Bluetooth'.
  final String route;

  final int bytes;
  final Duration took;

  /// Empty when it finished; the reason when it did not.
  final String failure;

  const TransferReport({
    required this.at,
    required this.role,
    required this.route,
    required this.bytes,
    required this.took,
    this.failure = '',
  });

  bool get succeeded => failure.isEmpty;

  /// Bytes per second, or null when the transfer was too brief to divide by.
  double? get bytesPerSecond {
    final seconds = took.inMilliseconds / 1000;
    if (seconds <= 0 || bytes <= 0) return null;
    return bytes / seconds;
  }

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'role': role,
        'route': route,
        'bytes': bytes,
        'ms': took.inMilliseconds,
        'failure': failure,
      };

  static TransferReport fromJson(Map<String, dynamic> json) => TransferReport(
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
        role: json['role'] as String? ?? '',
        route: json['route'] as String? ?? '',
        bytes: json['bytes'] as int? ?? 0,
        took: Duration(milliseconds: json['ms'] as int? ?? 0),
        failure: json['failure'] as String? ?? '',
      );

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

  static String formatRate(double? bytesPerSecond) {
    if (bytesPerSecond == null) return '—';
    return '${formatBytes(bytesPerSecond.round())}/s';
  }

  /// One block of text to hand to somebody who is helping.
  String get summary {
    final buffer = StringBuffer()
      ..writeln('DirectDrop — ${succeeded ? role : '$role, failed'}')
      ..writeln('When:  ${at.toLocal()}')
      ..writeln('Route: $route')
      ..writeln('Size:  ${formatBytes(bytes)}')
      ..writeln('Took:  ${took.inSeconds}s')
      ..writeln('Speed: ${formatRate(bytesPerSecond)}');
    if (!succeeded) buffer.writeln('Failed: $failure');
    return buffer.toString();
  }
}

/// Keeps the last few transfers so the app can answer "why was that slow?"
/// without anybody opening a Terminal.
class TransferDiagnostics {
  /// Enough to see a pattern, few enough that nobody scrolls.
  static const _keep = 5;
  static const _fileName = 'transfers.json';

  final Directory Function()? _overrideDir;

  const TransferDiagnostics({Directory Function()? overrideDir})
      : _overrideDir = overrideDir;

  Future<File> _file() async {
    final dir = _overrideDir?.call() ?? await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  Future<List<TransferReport>> recent() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>) TransferReport.fromJson(entry),
      ];
    } catch (e) {
      AppLogger.warning('Could not read transfer diagnostics: $e',
          tag: 'DIAG');
      return const [];
    }
  }

  Future<void> record(TransferReport report) async {
    try {
      final kept = [report, ...await recent()].take(_keep).toList();
      final file = await _file();
      await file.writeAsString(
          jsonEncode([for (final r in kept) r.toJson()]));
      AppLogger.info(
          '${report.role} ${TransferReport.formatBytes(report.bytes)} over '
          '${report.route} at ${TransferReport.formatRate(report.bytesPerSecond)}',
          tag: 'DIAG');
    } catch (e) {
      // Diagnostics failing must never affect a transfer.
      AppLogger.warning('Could not record transfer diagnostics: $e',
          tag: 'DIAG');
    }
  }

  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Nothing to do; it is a cache of facts, not the facts themselves.
    }
  }
}

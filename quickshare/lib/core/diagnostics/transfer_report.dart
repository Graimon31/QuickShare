import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/byte_format.dart';

/// Which way the bytes went.
///
/// A value, not a sentence. The journal is read on screen in whatever
/// language the app is set to, and a phrase composed by the bloc that
/// recorded the transfer can only ever be in one of them — which is how a
/// Russian settings screen ended up listing "Local network" five times.
/// [label] is the English the *diagnostics* keep saying: the log line and
/// the block somebody copies to ask for help, whose reader is not
/// necessarily using this app in this language.
enum TransferRoute {
  directWifiLink('directWifiLink', 'Direct Wi-Fi link'),
  localNetwork('localNetwork', 'Local network'),
  internetDirect('internetDirect', 'Internet (direct, same network)'),
  internetPeerToPeer('internetPeerToPeer', 'Internet (peer to peer)'),
  internetRelayed('internetRelayed', 'Internet (relayed)'),
  bluetooth('bluetooth', 'Bluetooth'),
  unknown('unknown', 'Unknown');

  const TransferRoute(this.wire, this.label);

  /// What goes in `transfers.json`, stable across releases.
  final String wire;

  /// English, always. See the class comment.
  final String label;

  /// Journals written before this was an enum stored [label] itself, and
  /// there is one on every device that has ever completed a transfer.
  /// Reading those back as [unknown] would blank the history for the exact
  /// people who have one, so both spellings are accepted.
  static TransferRoute fromJson(String? value) {
    if (value == null || value.isEmpty) return TransferRoute.unknown;
    for (final route in values) {
      if (route.wire == value || route.label == value) return route;
    }
    return TransferRoute.unknown;
  }
}

/// Which end of the transfer this device was. Same reasoning as
/// [TransferRoute]: a value on disk, a translation on screen, English in the
/// diagnostics.
enum TransferRole {
  sent('sent', 'sent'),
  received('received', 'received');

  const TransferRole(this.wire, this.label);

  final String wire;
  final String label;

  static TransferRole fromJson(String? value) =>
      value == TransferRole.received.wire
          ? TransferRole.received
          : TransferRole.sent;
}

/// What happened on one transfer, in terms a person can read out loud.
///
/// Everything here was already being written to the log, and the log is the
/// problem: getting one line out of it meant walking somebody through the
/// Terminal on a machine three cities away, twice, and still not having the
/// answer. The facts that decide whether a transfer was slow because of us or
/// because of somebody's uplink belong on screen.
class TransferReport {
  final DateTime at;

  /// Which end this device was.
  final TransferRole role;

  /// How it travelled.
  final TransferRoute route;

  final int bytes;
  final Duration took;

  /// Empty when it finished; the reason, in English, when it did not.
  ///
  /// This is the diagnostics' copy — what [summary] and the log line carry.
  /// The screen shows [failureCode] translated where there is one, and only
  /// falls back to this when the reason was a caught exception's own text.
  final String failure;

  /// A `FailureCode` for the reason in [failure], where the app authored it
  /// rather than caught it. Null on a transfer that finished.
  final String? failureCode;

  /// This device's own address for the session, if known — what a QR or a
  /// direct-link offer named, whether or not anything ended up using it.
  final String? localAddress;

  /// The address that actually carried the bytes, if one is known: the
  /// far side's socket address on the sender, or the host this device
  /// connected to on the receiver. This is the fact that answers "did this
  /// really go over the LAN" or "was that actually the direct link" —
  /// [route] is a label chosen from it, this is the evidence for the label.
  final String? peerAddress;

  const TransferReport({
    required this.at,
    required this.role,
    required this.route,
    required this.bytes,
    required this.took,
    this.failure = '',
    this.failureCode,
    this.localAddress,
    this.peerAddress,
  });

  bool get succeeded => failure.isEmpty && failureCode == null;

  /// Bytes per second, or null when the transfer was too brief to divide by.
  double? get bytesPerSecond {
    final seconds = took.inMilliseconds / 1000;
    if (seconds <= 0 || bytes <= 0) return null;
    return bytes / seconds;
  }

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'role': role.wire,
        'route': route.wire,
        'bytes': bytes,
        'ms': took.inMilliseconds,
        'failure': failure,
        if (failureCode != null) 'failureCode': failureCode,
        if (localAddress != null) 'localAddress': localAddress,
        if (peerAddress != null) 'peerAddress': peerAddress,
      };

  static TransferReport fromJson(Map<String, dynamic> json) => TransferReport(
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
        role: TransferRole.fromJson(json['role'] as String?),
        route: TransferRoute.fromJson(json['route'] as String?),
        bytes: json['bytes'] as int? ?? 0,
        took: Duration(milliseconds: json['ms'] as int? ?? 0),
        failure: json['failure'] as String? ?? '',
        failureCode: json['failureCode'] as String?,
        localAddress: json['localAddress'] as String?,
        peerAddress: json['peerAddress'] as String?,
      );

  static String formatBytes(int bytes) => ByteFormat.size(bytes);

  static String formatRate(double? bytesPerSecond) {
    if (bytesPerSecond == null) return '—';
    return ByteFormat.rate(bytesPerSecond);
  }

  /// One block of text to hand to somebody who is helping.
  ///
  /// Stays English while the screen above it does not. Whoever is being
  /// asked for help is being handed a paste from a stranger's machine, and a
  /// route label they cannot read is one more thing to translate before the
  /// question can be answered.
  String get summary {
    final buffer = StringBuffer()
      ..writeln(
          'DirectDrop — ${succeeded ? role.label : '${role.label}, failed'}')
      ..writeln('When:  ${at.toLocal()}')
      ..writeln('Route: ${route.label}')
      ..writeln('Size:  ${formatBytes(bytes)}')
      ..writeln('Took:  ${took.inSeconds}s')
      ..writeln('Speed: ${formatRate(bytesPerSecond)}');
    if (localAddress != null) buffer.writeln('This device: $localAddress');
    if (peerAddress != null) buffer.writeln('Peer:        $peerAddress');
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
      // The one line in the whole journal that is supposed to say "here is
      // what actually happened to the user's files" — everything else
      // around it is plumbing (sessions starting, radios toggling). It has
      // to say so plainly even when nothing failed, and it has to say why
      // when something did; a silent success reads exactly like a session
      // nobody is sure ever ran.
      final addr = [
        if (report.localAddress != null) 'this device ${report.localAddress}',
        if (report.peerAddress != null) 'peer ${report.peerAddress}',
      ].join(', ');
      AppLogger.info(
          '${report.succeeded ? 'OK' : 'FAILED'}: ${report.role.label} '
          '${TransferReport.formatBytes(report.bytes)} over '
          '${report.route.label} '
          'at ${TransferReport.formatRate(report.bytesPerSecond)}'
          '${addr.isEmpty ? '' : ' ($addr)'}'
          '${report.succeeded ? '' : ' — ${report.failure}'}',
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

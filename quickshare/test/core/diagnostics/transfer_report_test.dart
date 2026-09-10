// Getting one fact out of a transfer used to mean walking somebody through the
// Terminal on a machine in another city — twice, and still without the answer.
// These are the facts that decide whether a transfer was slow because of us or
// because of somebody's uplink.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/diagnostics/transfer_report.dart';

void main() {
  late Directory root;
  late TransferDiagnostics diagnostics;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_diag_');
    diagnostics = TransferDiagnostics(overrideDir: () => root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  TransferReport report({
    TransferRole role = TransferRole.sent,
    TransferRoute route = TransferRoute.directWifiLink,
    int bytes = 64 * 1000 * 1000,
    int seconds = 8,
    String failure = '',
    String? failureCode,
  }) =>
      TransferReport(
        at: DateTime(2026, 8, 24, 19, 30),
        role: role,
        route: route,
        bytes: bytes,
        took: Duration(seconds: seconds),
        failure: failure,
        failureCode: failureCode,
      );

  test('speed is derived rather than stored', () {
    final rate = report(bytes: 64 * 1024 * 1024, seconds: 8).bytesPerSecond;
    expect(rate, closeTo(8 * 1024 * 1024, 1));
  });

  test('a transfer too brief to divide by reports no speed', () {
    expect(report(seconds: 0).bytesPerSecond, isNull);
    expect(TransferReport.formatRate(null), equals('—'));
  });

  test('the summary carries the one fact that explains the speed', () {
    final text = report(route: TransferRoute.internetRelayed).summary;
    expect(text, contains('Internet (relayed)'),
        reason: 'a relayed session and a direct one differ by an order of '
            'magnitude and look identical on screen');
    expect(text, contains('64 MB'));
    expect(text, contains('8s'));
  });

  test('a failure says so instead of pretending', () {
    final failed = report(failure: 'Connection lost');
    expect(failed.succeeded, isFalse);
    expect(failed.summary, contains('Failed: Connection lost'));
  });

  test('reports survive a restart', () async {
    await diagnostics.record(report(route: TransferRoute.bluetooth));
    final reloaded = await TransferDiagnostics(overrideDir: () => root).recent();
    expect(reloaded.single.route, equals(TransferRoute.bluetooth));
  });

  test('the newest is first and the list does not grow forever', () async {
    for (var i = 0; i < 8; i++) {
      await diagnostics.record(report(bytes: i));
    }
    final kept = await diagnostics.recent();
    expect(kept, hasLength(5), reason: 'enough to see a pattern, few enough '
        'that nobody scrolls');
    expect(kept.first.bytes, equals(7));
  });

  test('unreadable diagnostics are not an error worth surfacing', () async {
    File('${root.path}/transfers.json').writeAsStringSync('{ not json');
    expect(await diagnostics.recent(), isEmpty);
  });
}

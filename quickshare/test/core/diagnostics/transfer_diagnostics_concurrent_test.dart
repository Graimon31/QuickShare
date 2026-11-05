// Two transfers that end together must both be on record.
//
// `record` read the file, put the new report in front and wrote the file back.
// Two calls that overlap each read the same file and each write it back with
// only their own addition, so one report disappears — and the write itself
// truncated the file before filling it, so a reader at the wrong moment saw
// half a document. Writes now take turns, and each goes to a scratch file that
// is renamed over the real one.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/diagnostics/transfer_report.dart';

void main() {
  late Directory root;
  late TransferDiagnostics diagnostics;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_diag_concurrent_');
    diagnostics = TransferDiagnostics(overrideDir: () => root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  TransferReport report(int n) => TransferReport(
        at: DateTime(2026, 11, 5, 12, n % 60),
        role: TransferRole.received,
        route: TransferRoute.directWifiLink,
        bytes: n,
        took: const Duration(seconds: 1),
      );

  File file() => File(p.join(root.path, 'transfers.json'));

  test('reports recorded at the same moment are all kept', () async {
    await Future.wait([for (var n = 1; n <= 5; n++) diagnostics.record(report(n))]);

    final kept = await diagnostics.recent();
    expect(kept.map((r) => r.bytes).toSet(), {1, 2, 3, 4, 5},
        reason: 'one report overwrote another');
  });

  test('and in the order they were asked for, newest first', () async {
    await Future.wait([for (var n = 1; n <= 5; n++) diagnostics.record(report(n))]);

    expect((await diagnostics.recent()).map((r) => r.bytes), [5, 4, 3, 2, 1]);
  });

  test('only the last few are kept, however many arrive together', () async {
    await Future.wait(
        [for (var n = 1; n <= 40; n++) diagnostics.record(report(n))]);

    expect((await diagnostics.recent()).map((r) => r.bytes),
        [40, 39, 38, 37, 36]);
  });

  test('two instances over one file take turns too', () async {
    final other = TransferDiagnostics(overrideDir: () => root);
    await Future.wait([
      for (var n = 1; n <= 6; n++)
        (n.isEven ? other : diagnostics).record(report(n)),
    ]);

    expect((await diagnostics.recent()).map((r) => r.bytes).toSet(),
        {2, 3, 4, 5, 6});
  });

  test('a report recorded after another has finished is kept as before',
      () async {
    await diagnostics.record(report(1));
    await diagnostics.record(report(2));

    expect((await diagnostics.recent()).map((r) => r.bytes), [2, 1]);
  });

  test('the file is never seen half-written', () async {
    // A reader that looks at the file all the while it is being rewritten:
    // every look is a whole JSON document, never an empty file or half of one.
    var writing = true;
    var looks = 0;
    final broken = <String>[];
    final reader = () async {
      while (writing) {
        if (file().existsSync()) {
          looks++;
          try {
            final text = file().readAsStringSync();
            jsonDecode(text);
          } on FormatException catch (e) {
            broken.add(e.message);
          } on FileSystemException {
            // Renamed over between existsSync and the read; the next look sees
            // the new one.
          }
        }
        await Future<void>.delayed(Duration.zero);
      }
    }();

    for (var n = 1; n <= 150; n++) {
      await diagnostics.record(report(n));
    }
    writing = false;
    await reader;

    expect(looks, greaterThan(20), reason: 'the reader has to have looked');
    expect(broken, isEmpty,
        reason: 'the file was read while it was only partly written');
  });

  test('no scratch file is left behind', () async {
    await Future.wait([for (var n = 1; n <= 8; n++) diagnostics.record(report(n))]);

    expect(root.listSync().map((e) => p.basename(e.path)), ['transfers.json']);
  });

  test('a write that cannot happen leaves the earlier record alone', () async {
    await diagnostics.record(report(1));
    final before = file().readAsStringSync();
    // The scratch name is taken by a folder: the new write cannot be made.
    Directory(p.join(root.path, 'transfers.json.$pid.tmp')).createSync();

    await diagnostics.record(report(2));

    expect(file().readAsStringSync(), before,
        reason: 'a failed write must not damage what was there');
  });

  test('clear waits for writes already asked for, and a record asked for '
      'after it starts a new file', () async {
    final before = diagnostics.record(report(1));
    final clearing = diagnostics.clear();
    final after = diagnostics.record(report(2));
    await Future.wait([before, clearing, after]);

    expect((await diagnostics.recent()).map((r) => r.bytes), [2]);
  });
}

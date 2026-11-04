// Names that differ only in case, on a destination that folds it.
//
// The WebRTC receiver's folder mode skipped its "is this name taken?" step, so
// `Photo.jpg` and `photo.jpg` wrote to one file on a case-insensitive volume
// (macOS and Windows defaults) and the second erased the first. QHTP chooses
// every item's name with the lookup that folder mode lacked — right before the
// item is written, and again at the final rename — so the same pair cannot
// collide there. This pins that, with a real sender and a real receiver: the
// user already has `A.BIN`; the sender sends `a.bin`.
//
// On a case-sensitive volume the two are different files and simply sit side by
// side, which is also asserted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'qhtp_receive_harness.dart';

void main() {
  setUpAll(installFakeWakelock);

  late QhtpHarness h;
  setUp(() async => h = await QhtpHarness.create());
  tearDown(() => h.dispose());

  bool volumeFoldsCase() {
    final probe = Directory.systemTemp.createTempSync('dd_case_probe_');
    try {
      File(p.join(probe.path, 'probe.txt')).writeAsStringSync('x');
      return File(p.join(probe.path, 'PROBE.TXT')).existsSync();
    } finally {
      probe.deleteSync(recursive: true);
    }
  }

  test('a file whose name differs only in case from one the user has never '
      'replaces it', () async {
    await h.serve({'a.bin': [1, 2, 3, 4]});
    File(h.received('A.BIN'))
      ..createSync(recursive: true)
      ..writeAsStringSync('the user\'s own file');

    expectReceived(await h
        .client()
        .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

    expect(File(h.received('A.BIN')).readAsStringSync(), 'the user\'s own file',
        reason: 'the user\'s file was replaced');
    final folder = Directory(p.dirname(h.received('a.bin')));
    final names = folder.listSync().map((e) => p.basename(e.path)).toSet();
    if (volumeFoldsCase()) {
      expect(names, {'A.BIN', 'a (1).bin'},
          reason: 'on a volume that folds case a.bin IS A.BIN, so the '
              'newcomer must be numbered');
      expect(File(h.received('a (1).bin')).readAsBytesSync(), [1, 2, 3, 4]);
    } else {
      expect(names, {'A.BIN', 'a.bin'});
      expect(File(h.received('a.bin')).readAsBytesSync(), [1, 2, 3, 4]);
    }
  });
}

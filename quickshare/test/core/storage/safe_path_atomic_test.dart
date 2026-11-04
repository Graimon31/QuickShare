// The no-replace rename has an atomic form (link/unlink, mkdir) and a fallback
// (look, then rename). Every behavioural test passes by either, which is what a
// fallback is for — and also means they cannot tell whether the atomic form
// ever runs. This file does: the fallback announces itself in the log, once per
// run, and a test file gets a run of its own.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/safe_path.dart';
import 'package:quickshare/core/utils/app_logger.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('dd_atomic_'));
  tearDown(() => dir.deleteSync(recursive: true));

  bool fellBack() => AppLogger.getInMemoryLogs()
      .any((line) => line.contains('No atomic no-replace rename'));

  test('on a volume that hard-links, files are moved by link and unlink', () {
    final from = File(p.join(dir.path, 'a.partial'))..writeAsStringSync('x');
    SafePath.renameNoClobber(from.path, p.join(dir.path, 'a.txt'));
    expect(File(p.join(dir.path, 'a.txt')).readAsStringSync(), 'x');
    expect(fellBack(), isFalse,
        reason: 'link(2) failed here, so the look-then-rename fallback ran');
  }, skip: Platform.isWindows ? 'Windows has only the fallback' : false);

  test('and folders are claimed with mkdir and renamed onto the claim', () {
    final staged = Directory(p.join(dir.path, 'Trip.qs.partial'))..createSync();
    File(p.join(staged.path, 'one')).writeAsStringSync('1');
    SafePath.renameDirectoryNoClobber(staged.path, p.join(dir.path, 'Trip'));
    expect(File(p.join(dir.path, 'Trip', 'one')).readAsStringSync(), '1');
    expect(fellBack(), isFalse,
        reason: 'mkdir(2) failed here, so the fallback ran');
  }, skip: Platform.isWindows ? 'Windows has only the fallback' : false);
}

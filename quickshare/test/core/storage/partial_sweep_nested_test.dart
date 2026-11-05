// The startup sweep also reaches the subfolders of the destination.
//
// A folder received over QHTP lands as `Trip/clip.bin`, and while it is
// arriving as `Trip/clip.bin.qs.partial`. The sweep looked at the top level of
// the destination only, so what an abandoned folder session left one level
// down stayed for ever.
//
// Going down is only worth it if nothing that is still wanted can be taken, so
// most of what is checked here is what the sweep must not touch: a partial a
// live session record can resume, one written a moment ago, a folder marked as
// the only copy, anything behind a link, and anything that is not ours.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';

import '../../support/links.dart';

void main() {
  late Directory root;
  late Directory outside;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_sweep_nested_');
    outside = Directory.systemTemp.createTempSync('dd_sweep_nested_out_');
  });
  tearDown(() {
    root.deleteSync(recursive: true);
    outside.deleteSync(recursive: true);
  });

  /// "Now" for a sweep: everything written before this instant is old enough.
  DateTime later() => DateTime.now().add(const Duration(minutes: 1));

  File partial(String relative, {int bytes = 10}) {
    final file = File(p.join(root.path, '$relative$kPartialSuffix'));
    file.parent.createSync(recursive: true);
    return file..writeAsBytesSync(List.filled(bytes, 1));
  }

  group('what it now finds', () {
    test('a stale partial one folder down', () async {
      final left = partial('Trip/clip.bin');

      final freed = await sweepPartials(root.path, before: later());

      expect(left.existsSync(), isFalse);
      expect(freed, 10);
    });

    test('several folders down, and counts all of it', () async {
      final a = partial('Trip/2026/June/clip.bin', bytes: 7);
      final b = partial('Trip/2026/photo.jpg', bytes: 5);
      final c = partial('Trip/notes.txt', bytes: 3);
      final top = partial('loose.mp4', bytes: 11);

      final freed = await sweepPartials(root.path, before: later());

      for (final f in [a, b, c, top]) {
        expect(f.existsSync(), isFalse, reason: f.path);
      }
      expect(freed, 7 + 5 + 3 + 11);
    });

    test('a stale staged folder one folder down, whole', () async {
      final staged = Directory(p.join(root.path, 'Trip', 'Half$kPartialSuffix'))
        ..createSync(recursive: true);
      File(p.join(staged.path, 'a.bin')).writeAsBytesSync([1, 2, 3]);

      final freed = await sweepPartials(root.path, before: later());

      expect(staged.existsSync(), isFalse);
      expect(freed, 3);
    });

    test('and leaves the folder that held them', () async {
      partial('Trip/clip.bin');

      await sweepPartials(root.path, before: later());

      expect(Directory(p.join(root.path, 'Trip')).existsSync(), isTrue,
          reason: 'it may hold files the person wants');
    });
  });

  group('what it must not touch', () {
    test('a partial written a moment ago: a live transfer\'s', () async {
      final live = partial('Trip/clip.bin');
      final old = partial('Trip/old.bin');
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));

      await sweepPartials(root.path,
          before: DateTime.now().subtract(const Duration(minutes: 10)));

      expect(live.existsSync(), isTrue,
          reason: 'written inside the last ten minutes');
      expect(old.existsSync(), isFalse);
    });

    test('a partial a session on record may resume, however old', () async {
      final left = partial('Trip/clip.bin');
      final other = partial('Trip/other.bin');

      await sweepPartials(root.path,
          before: later(), pinned: {left.path});

      expect(left.existsSync(), isTrue);
      expect(other.existsSync(), isFalse);
    });

    test('and the real session store is what says which', () async {
      // Driven the way a receive drives it: the paths come from the record the
      // QHTP client wrote, not from the test.
      final store = Directory.systemTemp.createTempSync('dd_sweep_store_');
      addTearDown(() => store.deleteSync(recursive: true));
      final sessions = SessionStateStore(storeDirectory: store.path);
      await sessions.saveState(
        sessionId: 'trip',
        host: '127.0.0.1',
        port: 1,
        token: 't',
        baseDir: root.path,
        items: {
          'a': const QhtpItemState(
              id: 'a', path: 'Trip/clip.bin', size: 100, status: 'partial'),
          'b': const QhtpItemState(
              id: 'b', path: 'Trip/done.bin', size: 100, status: 'completed'),
        },
      );
      final resumable = partial('Trip/clip.bin');
      final abandoned = partial('Trip/never-recorded.bin');

      await sweepPartials(root.path,
          before: later(), pinned: await sessions.pinnedPartials());

      expect(resumable.existsSync(), isTrue,
          reason: 'the client told the person this one can be picked up');
      expect(abandoned.existsSync(), isFalse);
    });

    test('a folder marked as the only copy, nor what is inside it', () async {
      final kept = Directory(p.join(root.path, 'Trip', 'All$kPartialSuffix'))
        ..createSync(recursive: true);
      final inside = File(p.join(kept.path, 'a.bin$kPartialSuffix'))
        ..writeAsBytesSync([1, 2, 3]);
      File(p.join(kept.path, kKeptMarker)).writeAsStringSync('kept');

      await sweepPartials(root.path, before: later());

      expect(inside.existsSync(), isTrue,
          reason: 'the only copy of a folder that was received in full');
    });

    test('anything that is not named like a partial', () async {
      final files = [
        File(p.join(root.path, 'Trip', 'clip.bin')),
        File(p.join(root.path, 'Trip', 'clip.bin.qs.partial.txt')),
        File(p.join(root.path, 'Trip', 'clip.qs.partial.bin')),
        File(p.join(root.path, 'Trip', 'x.tmp')),
        File(p.join(root.path, 'Trip', 'x.part')),
      ];
      for (final f in files) {
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync([1]);
      }

      await sweepPartials(root.path, before: later());

      for (final f in files) {
        expect(f.existsSync(), isTrue, reason: f.path);
      }
    });

    test('a folder that is a link, however it is named, is not entered',
        () async {
      final stranger = File(p.join(outside.path, 'clip.bin$kPartialSuffix'))
        ..writeAsBytesSync(List.filled(40, 3));
      if (!linkOrSkip(p.join(root.path, 'Trip'), outside.path)) return;

      await sweepPartials(root.path, before: later());

      expect(stranger.existsSync(), isTrue,
          reason: 'a link out of the destination was followed');
    });

    test('a link named like a partial is neither entered nor deleted into',
        () async {
      final precious = File(p.join(outside.path, 'precious.bin'))
        ..writeAsBytesSync(List.filled(64, 1));
      Directory(p.join(root.path, 'Trip')).createSync();
      if (!linkOrSkip(
          p.join(root.path, 'Trip', 'x$kPartialSuffix'), outside.path)) {
        return;
      }
      Link(p.join(root.path, 'Trip', 'y$kPartialSuffix'))
          .createSync(precious.path);

      await sweepPartials(root.path, before: later());

      expect(precious.existsSync(), isTrue);
      expect(outside.listSync().map((e) => p.basename(e.path)),
          ['precious.bin']);
    });

    test('a partial a link points a folder at is still the other side\'s',
        () async {
      // The file is reachable as root/Trip/clip.bin.qs.partial only through the
      // link, so a sweep that went through it would delete outside the
      // destination.
      Directory(p.join(root.path, 'Real')).createSync();
      final inReal = File(p.join(root.path, 'Real', 'clip.bin$kPartialSuffix'))
        ..writeAsBytesSync([1, 2]);
      if (!linkOrSkip(p.join(root.path, 'Alias'), p.join(root.path, 'Real'))) {
        return;
      }

      final freed = await sweepPartials(root.path, before: later());

      expect(inReal.existsSync(), isFalse, reason: 'found once, by its own path');
      expect(freed, 2, reason: 'counted once, not once per name it has');
    });
  });

  group('how far it goes', () {
    test('a tree deeper than the limit is not walked to the bottom', () async {
      final shallow = partial('a/b/shallow.bin');
      final deep = partial('a/b/c/d/e/f/deep.bin');

      await sweepPartials(root.path, before: later(), maxDepth: 3);

      expect(shallow.existsSync(), isFalse);
      expect(deep.existsSync(), isTrue,
          reason: 'past the depth it was told to stop at');
    });

    test('a folder with more in it than the budget stops the walk, not the '
        'sweep of the top level', () async {
      for (var i = 0; i < 30; i++) {
        File(p.join(root.path, 'many', 'f$i.txt'))
          ..createSync(recursive: true)
          ..writeAsBytesSync([1]);
      }
      final far = partial('many/zzz.bin');
      final top = partial('loose.mp4');

      await sweepPartials(root.path, before: later(), maxEntries: 10);

      expect(top.existsSync(), isFalse,
          reason: 'the top level is always done, as it always was');
      expect(far.existsSync(), isTrue,
          reason: 'the budget ran out before the walk got there');
    });

    test('an unreadable folder is passed over', () async {
      if (Platform.isWindows) return; // permissions work differently
      final sealed = Directory(p.join(root.path, 'sealed'))..createSync();
      partial('sealed/inside.bin');
      final ok = partial('open/ok.bin');
      Process.runSync('chmod', ['000', sealed.path]);
      addTearDown(() => Process.runSync('chmod', ['755', sealed.path]));

      await sweepPartials(root.path, before: later());

      expect(ok.existsSync(), isFalse, reason: 'the rest was swept');
    });
  });

  test('the top level behaves exactly as it did', () async {
    final oldFile = partial('a.mp4', bytes: 100);
    final oldDir = Directory(p.join(root.path, 'B$kPartialSuffix'))..createSync();
    File(p.join(oldDir.path, 'inner.bin')).writeAsBytesSync(List.filled(40, 0));
    final keeper = File(p.join(root.path, 'real.mp4'))
      ..writeAsBytesSync(List.filled(10, 0));

    final freed = await sweepPartials(root.path, before: later());

    expect(freed, 140);
    expect(oldFile.existsSync(), isFalse);
    expect(oldDir.existsSync(), isFalse);
    expect(keeper.existsSync(), isTrue);
  });
}

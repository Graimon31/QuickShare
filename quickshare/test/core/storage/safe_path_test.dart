// FS-01 at the bottom: the helper every receive path writes through.
//
// Every test builds its own tree in a temp directory, including the "outside"
// the receiver must never reach, and checks that outside afterwards.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/storage/safe_path.dart';

import '../../support/links.dart';

void main() {
  late Directory root;
  late Directory base;
  late Directory outside;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_safepath_');
    base = Directory(p.join(root.path, 'dest'))..createSync();
    outside = Directory(p.join(root.path, 'outside'))..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Map<String, String> snapshot(Directory d) => {
        for (final e in d.listSync(recursive: true, followLinks: false))
          p.relative(e.path, from: d.path): e is File
              ? e.readAsStringSync()
              : e is Link
                  ? 'link:${e.targetSync()}'
                  : 'dir',
      };

  group('assertNoLinksBelow', () {
    test('passes for a nested path that does not exist yet', () {
      SafePath.assertNoLinksBelow(
          base.path, p.join(base.path, 'a', 'b', 'c.txt'));
    });

    test('passes through real folders', () {
      Directory(p.join(base.path, 'a', 'b')).createSync(recursive: true);
      SafePath.assertNoLinksBelow(
          base.path, p.join(base.path, 'a', 'b', 'c.txt'));
    });

    test('refuses a link to somewhere outside', () {
      Link(p.join(base.path, 'trip')).createSync(outside.path);
      expect(
          () => SafePath.assertNoLinksBelow(
              base.path, p.join(base.path, 'trip', 'c.txt')),
          throwsA(isA<UnsafePathException>()));
    });

    test('refuses a link to somewhere inside, too', () {
      Directory(p.join(base.path, 'real')).createSync();
      Link(p.join(base.path, 'alias')).createSync(p.join(base.path, 'real'));
      expect(
          () => SafePath.assertNoLinksBelow(
              base.path, p.join(base.path, 'alias', 'c.txt')),
          throwsA(isA<UnsafePathException>()));
    });

    test('refuses a link deep in the chain', () {
      Directory(p.join(base.path, 'a')).createSync();
      Link(p.join(base.path, 'a', 'b')).createSync(outside.path);
      expect(
          () => SafePath.assertNoLinksBelow(
              base.path, p.join(base.path, 'a', 'b', 'c', 'd.txt')),
          throwsA(isA<UnsafePathException>()));
    });

    test('refuses a file where a folder is needed', () {
      File(p.join(base.path, 'a')).writeAsStringSync('x');
      expect(
          () => SafePath.assertNoLinksBelow(
              base.path, p.join(base.path, 'a', 'c.txt')),
          throwsA(isA<UnsafePathException>()));
    });

    test('refuses a target that is not below the base', () {
      expect(
          () => SafePath.assertNoLinksBelow(
              base.path, p.join(outside.path, 'c.txt')),
          throwsA(isA<UnsafePathException>()));
    });

    test('an existing outside file is refused and remains untouched', () {
      final victim = File(p.join(outside.path, 'existing.qs.partial'))
        ..writeAsStringSync('precious');
      final before = snapshot(outside);

      expect(
          () => SafePath.assertNoLinksBelow(base.path, victim.path,
              includeTarget: true),
          throwsA(isA<UnsafePathException>()));
      expect(() => SafePath.ensureParents(base.path, victim.path),
          throwsA(isA<UnsafePathException>()));
      expect(
          () => SafePath.openPartial(base.path, victim.path, truncate: true),
          throwsA(isA<UnsafePathException>()));
      expect(snapshot(outside), before);
      expect(victim.readAsStringSync(), 'precious');
    });

    test('refuses a target outside the base even when nothing there exists '
        'yet', () {
      // Nothing under `outside/` has to be there for the answer to be no: the
      // walk stops at the first folder that does not exist, and the answer
      // must not depend on how far it got.
      expect(
          () => SafePath.assertNoLinksBelow(
              base.path, p.join(outside.path, 'not-yet', 'c.txt')),
          throwsA(isA<UnsafePathException>()));
      expect(
          () => SafePath.assertNoLinksBelow(
              base.path, p.join(base.path, '..', 'outside', 'nope', 'c.txt')),
          throwsA(isA<UnsafePathException>()));
    });

    test('a base that is itself reached through a link is fine', () {
      // /tmp and /var are links on macOS; a user may also have pointed the
      // destination at a link. The base is the user\'s choice.
      final alias = Link(p.join(root.path, 'alias'))..createSync(base.path);
      SafePath.assertNoLinksBelow(
          alias.path, p.join(alias.path, 'a', 'c.txt'));
    });

    test('the final name is only looked at when asked', () {
      Link(p.join(base.path, 'f.txt')).createSync(p.join(outside.path, 'x'));
      SafePath.assertNoLinksBelow(base.path, p.join(base.path, 'f.txt'));
      expect(
          () => SafePath.assertNoLinksBelow(
              base.path, p.join(base.path, 'f.txt'),
              includeTarget: true),
          throwsA(isA<UnsafePathException>()));
    });
  });

  group('names', () {
    test('a dangling link counts as an occupied name', () {
      final ghost = p.join(outside.path, 'ghost');
      Link(p.join(base.path, 'a.txt')).createSync(ghost);
      expect(SafePath.exists(p.join(base.path, 'a.txt')), isTrue);
      expect(SafePath.uniquePath(p.join(base.path, 'a.txt')),
          p.join(base.path, 'a (1).txt'));
    });

    test('uniquePath keeps the name(n).ext convention and skips taken ones',
        () {
      File(p.join(base.path, 'a.txt')).writeAsStringSync('1');
      File(p.join(base.path, 'a (1).txt')).writeAsStringSync('2');
      Directory(p.join(base.path, 'a (2).txt')).createSync();
      expect(SafePath.uniquePath(p.join(base.path, 'a.txt')),
          p.join(base.path, 'a (3).txt'));
      expect(SafePath.uniquePath(p.join(base.path, 'free.txt')),
          p.join(base.path, 'free.txt'));
    });
  });

  group('resolve', () {
    test('keeps an absolute base and a hostile name inside', () {
      final resolved =
          SafePath.resolve('../../etc/passwd', base.path, defaultName: 'f');
      expect(p.isWithin(base.path, resolved), isTrue);
    });

    test('refuses a relative or empty base', () {
      expect(() => SafePath.resolve('a.txt', '', defaultName: 'f'),
          throwsA(isA<Exception>()));
      expect(() => SafePath.resolve('a.txt', 'downloads', defaultName: 'f'),
          throwsA(isA<Exception>()));
    });

    test('refuses a name that passes through a link', () {
      Link(p.join(base.path, 'Trip')).createSync(outside.path);
      expect(() => SafePath.resolve('Trip/a.txt', base.path, defaultName: 'f'),
          throwsA(isA<UnsafePathException>()));
    });
  });

  group('ensureParents', () {
    test('creates what is missing, one real folder at a time', () {
      final target = p.join(base.path, 'x', 'y', 'f.txt');
      SafePath.ensureParents(base.path, target);
      expect(Directory(p.join(base.path, 'x', 'y')).existsSync(), isTrue);
    });

    test('creates a base that does not exist yet', () {
      final fresh = p.join(root.path, 'fresh', 'downloads');
      SafePath.ensureParents(fresh, p.join(fresh, 'f.txt'));
      expect(Directory(fresh).existsSync(), isTrue);
    });

    test('writes nothing outside when a link is in the way', () {
      Link(p.join(base.path, 'x')).createSync(outside.path);
      final before = snapshot(outside);
      expect(
          () => SafePath.ensureParents(
              base.path, p.join(base.path, 'x', 'y', 'f.txt')),
          throwsA(isA<UnsafePathException>()));
      expect(snapshot(outside), before);
    });
  });

  group('someone acts between a check and the next call', () {
    // `SafePath.debugRace` is how a test does what a racing process would, at
    // the exact moment: nothing else can be timed to the microsecond.
    tearDown(() => SafePath.debugRace = null);

    String partialIn(Directory d) => p.join(d.path, 'f.txt.qs.partial');

    test('a link in the place of a folder about to be made is not followed',
        () {
      final before = snapshot(outside);
      SafePath.debugRace = (stage, path) {
        if (stage == 'mkdir') Link(path).createSync(outside.path);
      };

      expect(
          () => SafePath.ensureParents(
              base.path, p.join(base.path, 'sub', 'deeper', 'f.txt')),
          throwsA(isA<UnsafePathException>()));
      expect(snapshot(outside), before,
          reason: 'nothing was made through the link');
    });

    for (final truncate in [true, false]) {
      test('a link put where the partial is, just before it is opened, is '
          'neither written to nor emptied (truncate: $truncate)', () {
        final victim = File(p.join(outside.path, 'victim.txt'))
          ..writeAsStringSync('precious');
        if (!truncate) File(partialIn(base)).writeAsBytesSync([1, 2]);
        SafePath.debugRace = (stage, path) {
          if (stage != 'open') return;
          File(path).deleteSync();
          Link(path).createSync(victim.path);
        };

        expect(
            () => SafePath.openPartial(base.path, partialIn(base),
                truncate: truncate),
            throwsA(isA<UnsafePathException>()),
            reason: 'the file that was opened is not the one that was checked');
        expect(victim.readAsStringSync(), 'precious',
            reason: 'opening must not empty what the link leads to');
      });
    }

    // The two ways a new file is made. POSIX has one call that refuses
    // anything at the name; Windows' equivalent follows a link standing there
    // and creates its target, so on Windows (and, through the hook, here) the
    // file is made under a name nobody can have prepared and moved into place.
    for (final viaScratch in [false, true]) {
      group('a new file is made ${viaScratch ? 'under a scratch name' : 'in one call'}',
          () {
        setUp(() => SafePath.debugCreateViaScratch = viaScratch);
        tearDown(() => SafePath.debugCreateViaScratch = false);

        test('a link put where the partial is about to be created does not '
            'make its target', () {
          final ghost = File(p.join(outside.path, 'ghost.txt'));
          SafePath.debugRace = (stage, path) {
            if (stage == 'create') Link(path).createSync(ghost.path);
          };

          expect(
              () => SafePath.openPartial(base.path, partialIn(base),
                  truncate: true),
              throwsA(isA<UnsafePathException>()));
          expect(ghost.existsSync(), isFalse,
              reason: 'creation is exclusive: a link there, even a dangling '
                  'one, is a refusal and not a file to be made through');
          expect(Directory(base.path).listSync(followLinks: false)
              .whereType<File>(), isEmpty,
              reason: 'and the scratch file is not left behind');
        });

        test('a link to a file that exists is a refusal as well, and the file '
            'is untouched', () {
          final victim = File(p.join(outside.path, 'victim.txt'))
            ..writeAsStringSync('precious');
          SafePath.debugRace = (stage, path) {
            if (stage == 'create') Link(path).createSync(victim.path);
          };

          expect(
              () => SafePath.openPartial(base.path, partialIn(base),
                  truncate: true),
              throwsA(isA<UnsafePathException>()));
          expect(victim.readAsStringSync(), 'precious');
        });

        test('a file that turns up at the name first is not replaced', () {
          SafePath.debugRace = (stage, path) {
            if (stage == 'create') File(path).writeAsStringSync('theirs');
          };

          expect(
              () => SafePath.openPartial(base.path, partialIn(base),
                  truncate: true),
              throwsA(isA<UnsafePathException>()));
          expect(File(partialIn(base)).readAsStringSync(), 'theirs');
        });

        test('createExclusive refuses a dangling link that is already there',
            () {
          // No race to time: the link is simply at the name. What Windows'
          // own create call does with it is what this exists to avoid.
          final ghost = File(p.join(outside.path, 'ghost.txt'));
          final name = p.join(base.path, 'taken');
          Link(name).createSync(ghost.path);

          expect(() => SafePath.createExclusive(name),
              throwsA(isA<PathTakenException>()));
          expect(ghost.existsSync(), isFalse);
          expect(FileSystemEntity.isLinkSync(name), isTrue,
              reason: 'the link is left as it was');
        });

        test('createExclusive makes an empty file where there is nothing', () {
          final name = p.join(base.path, 'fresh.bin');

          SafePath.createExclusive(name);

          expect(File(name).existsSync(), isTrue);
          expect(File(name).lengthSync(), 0);
          expect(base.listSync().map((e) => p.basename(e.path)), ['fresh.bin'],
              reason: 'no scratch file is left beside it');
        });

        test('createExclusive refuses a name that is a file or a folder', () {
          File(p.join(base.path, 'file')).writeAsStringSync('mine');
          Directory(p.join(base.path, 'folder')).createSync();

          expect(() => SafePath.createExclusive(p.join(base.path, 'file')),
              throwsA(isA<PathTakenException>()));
          expect(() => SafePath.createExclusive(p.join(base.path, 'folder')),
              throwsA(isA<PathTakenException>()));
          expect(File(p.join(base.path, 'file')).readAsStringSync(), 'mine');
        });
      });
    }

    test('a folder swapped for a link just before the partial is opened is '
        'refused', () {
      final sub = Directory(p.join(base.path, 'sub'))..createSync();
      SafePath.debugRace = (stage, path) {
        if (stage != 'open') return;
        // The partial (made a moment ago) goes with the folder, and the link
        // stands where the folder was.
        final moved = p.join(outside.path, 'moved');
        sub.renameSync(moved);
        Link(sub.path).createSync(moved);
      };

      expect(
          () => SafePath.openPartial(
              base.path, p.join(sub.path, 'f.txt.qs.partial'),
              truncate: true),
          throwsA(isA<UnsafePathException>()));
      expect(
          File(p.join(outside.path, 'moved', 'f.txt.qs.partial'))
              .readAsBytesSync(),
          isEmpty,
          reason: 'nothing was written through the link');
    });
  });

  group('openPartial', () {
    String partialIn(Directory d) => p.join(d.path, 'f.txt.qs.partial');

    test('creates the file and takes writes from the start', () {
      final raf = SafePath.openPartial(base.path, partialIn(base),
          truncate: true);
      raf.writeFromSync([1, 2, 3]);
      raf.closeSync();
      expect(File(partialIn(base)).readAsBytesSync(), [1, 2, 3]);
    });

    test('truncates a stale partial and writes from byte zero, not past it',
        () {
      File(partialIn(base)).writeAsBytesSync(List.filled(500, 9));
      final raf = SafePath.openPartial(base.path, partialIn(base),
          truncate: true);
      raf.writeFromSync([1, 2, 3]);
      raf.closeSync();
      expect(File(partialIn(base)).readAsBytesSync(), [1, 2, 3],
          reason: 'no hole of stale bytes or zeros before the new ones');
    });

    test('resuming appends after what is there', () {
      File(partialIn(base)).writeAsBytesSync([1, 2]);
      final raf = SafePath.openPartial(base.path, partialIn(base),
          truncate: false);
      raf.writeFromSync([3, 4]);
      raf.closeSync();
      expect(File(partialIn(base)).readAsBytesSync(), [1, 2, 3, 4]);
    });

    test('a link at the partial is replaced by a file; its target is untouched',
        () {
      final victim = File(p.join(outside.path, 'victim.txt'))
        ..writeAsStringSync('precious');
      Link(partialIn(base)).createSync(victim.path);

      final raf = SafePath.openPartial(base.path, partialIn(base),
          truncate: true);
      raf.writeFromSync([7]);
      raf.closeSync();

      expect(victim.readAsStringSync(), 'precious');
      expect(FileSystemEntity.isLinkSync(partialIn(base)), isFalse);
      expect(File(partialIn(base)).readAsBytesSync(), [7]);
    });

    test('a dangling link at the partial does not create its target', () {
      final ghost = File(p.join(outside.path, 'ghost'));
      Link(partialIn(base)).createSync(ghost.path);

      SafePath.openPartial(base.path, partialIn(base), truncate: true)
          .closeSync();

      expect(ghost.existsSync(), isFalse);
    });

    test('a link in the folder chain is refused and nothing is created', () {
      Link(p.join(base.path, 'sub')).createSync(outside.path);
      final before = snapshot(outside);
      expect(
          () => SafePath.openPartial(
              base.path, p.join(base.path, 'sub', 'f.txt.qs.partial'),
              truncate: true),
          throwsA(isA<UnsafePathException>()));
      expect(snapshot(outside), before);
    });

    test('a folder in the way is refused, not deleted', () {
      Directory(partialIn(base)).createSync();
      File(p.join(partialIn(base), 'mine')).writeAsStringSync('mine');
      expect(
          () => SafePath.openPartial(base.path, partialIn(base),
              truncate: true),
          throwsA(isA<UnsafePathException>()));
      expect(File(p.join(partialIn(base), 'mine')).existsSync(), isTrue);
    });

    test('partialLength reports a regular file and drops a link', () {
      expect(SafePath.partialLength(base.path, partialIn(base)), 0);
      File(partialIn(base)).writeAsBytesSync([1, 2, 3]);
      expect(SafePath.partialLength(base.path, partialIn(base)), 3);

      File(partialIn(base)).deleteSync();
      final victim = File(p.join(outside.path, 'v'))..writeAsStringSync('vvv');
      Link(partialIn(base)).createSync(victim.path);
      expect(SafePath.partialLength(base.path, partialIn(base)), 0,
          reason: 'a link is not a partial: its target\'s length is not ours');
      expect(victim.readAsStringSync(), 'vvv');
    });
  });

  group('renameNoClobber', () {
    test('moves a file onto a free name', () {
      final from = File(p.join(base.path, 'a.partial'))
        ..writeAsStringSync('data');
      final to = p.join(base.path, 'a.txt');
      SafePath.renameNoClobber(from.path, to);
      expect(File(to).readAsStringSync(), 'data');
      expect(from.existsSync(), isFalse);
    });

    test('refuses a name a file already has, and changes nothing', () {
      final from = File(p.join(base.path, 'a.partial'))
        ..writeAsStringSync('new');
      final to = File(p.join(base.path, 'a.txt'))..writeAsStringSync('mine');
      expect(() => SafePath.renameNoClobber(from.path, to.path),
          throwsA(isA<PathTakenException>()));
      expect(to.readAsStringSync(), 'mine');
      expect(from.readAsStringSync(), 'new');
    });

    test('refuses a name a dangling link has', () {
      final from = File(p.join(base.path, 'a.partial'))
        ..writeAsStringSync('new');
      final ghost = p.join(outside.path, 'ghost');
      Link(p.join(base.path, 'a.txt')).createSync(ghost);
      expect(() => SafePath.renameNoClobber(from.path, p.join(base.path, 'a.txt')),
          throwsA(isA<PathTakenException>()));
      expect(File(ghost).existsSync(), isFalse);
    });

    test('refuses a name a folder has', () {
      final from = File(p.join(base.path, 'a.partial'))
        ..writeAsStringSync('new');
      Directory(p.join(base.path, 'a.txt')).createSync();
      expect(() => SafePath.renameNoClobber(from.path, p.join(base.path, 'a.txt')),
          throwsA(isA<PathTakenException>()));
    });

    test('the atomic path is really there on this platform', () {
      // Every other test here passes by the fallback too; this is the one that
      // fails if the libc lookups do not work.
      expect(SafePath.debugAtomicRenameAvailable, isTrue);
    }, skip: Platform.isWindows ? 'Windows has only the fallback' : false);

    test('moving onto a free name leaves exactly one name behind', () {
      final from = File(p.join(base.path, 'a.partial'))
        ..writeAsStringSync('data');
      SafePath.renameNoClobber(from.path, p.join(base.path, 'a.txt'));
      expect(base.listSync().map((e) => p.basename(e.path)), ['a.txt']);
    });

    test('without hard links (exFAT, SMB, some Android volumes) it still '
        'refuses to replace', () {
      SafePath.debugDisableHardLinks = true;
      addTearDown(() => SafePath.debugDisableHardLinks = false);

      final from = File(p.join(base.path, 'a.partial'))
        ..writeAsStringSync('new');
      final to = File(p.join(base.path, 'a.txt'))..writeAsStringSync('mine');
      expect(() => SafePath.renameNoClobber(from.path, to.path),
          throwsA(isA<PathTakenException>()));
      expect(to.readAsStringSync(), 'mine');

      to.deleteSync();
      SafePath.renameNoClobber(from.path, to.path);
      expect(to.readAsStringSync(), 'new');
    });
  });

  group('commitFile', () {
    test('lands on the name when it is free', () {
      final partial = File(p.join(base.path, 'a.txt.qs.partial'))
        ..writeAsStringSync('data');
      final used = SafePath.commitFile(
          base.path, partial.path, p.join(base.path, 'a.txt'));
      expect(used, p.join(base.path, 'a.txt'));
      expect(File(used).readAsStringSync(), 'data');
    });

    test('takes the next free name when the chosen one was taken meanwhile',
        () {
      final partial = File(p.join(base.path, 'a.txt.qs.partial'))
        ..writeAsStringSync('data');
      final taken = File(p.join(base.path, 'a.txt'))..writeAsStringSync('mine');
      final used = SafePath.commitFile(base.path, partial.path, taken.path);
      expect(used, p.join(base.path, 'a (1).txt'));
      expect(taken.readAsStringSync(), 'mine');
      expect(File(used).readAsStringSync(), 'data');
    });

    test('a folder swapped for a link since the file was opened is caught', () {
      final sub = Directory(p.join(base.path, 'sub'))..createSync();
      final partial = File(p.join(sub.path, 'a.txt.qs.partial'))
        ..writeAsStringSync('data');
      final before = snapshot(outside);

      sub.renameSync(p.join(base.path, 'sub_moved'));
      Link(sub.path).createSync(outside.path);

      expect(
          () => SafePath.commitFile(
              base.path, partial.path, p.join(sub.path, 'a.txt')),
          throwsA(isA<UnsafePathException>()));
      expect(snapshot(outside), before);
    });

    test('a folder moved elsewhere and linked back is caught too', () {
      // The sharper form of the swap above: the folder goes outside and
      // carries the partial with it, and a link stands where it was. Followed,
      // the link leads straight to the partial, so only a look at the chain
      // refuses it.
      final sub = Directory(p.join(base.path, 'sub'))..createSync();
      final partial = File(p.join(sub.path, 'a.txt.qs.partial'))
        ..writeAsStringSync('data');
      final moved = p.join(outside.path, 'moved');
      sub.renameSync(moved);
      Link(sub.path).createSync(moved);

      expect(
          () => SafePath.commitFile(
              base.path, partial.path, p.join(sub.path, 'a.txt')),
          throwsA(isA<UnsafePathException>()));
      expect(File(p.join(moved, 'a.txt')).existsSync(), isFalse,
          reason: 'the file was given its name outside the destination');
      expect(File(p.join(moved, 'a.txt.qs.partial')).readAsStringSync(), 'data');
    });

    test('a partial that has become a link is not committed', () {
      final victim = File(p.join(outside.path, 'v'))..writeAsStringSync('vvv');
      final partial = p.join(base.path, 'a.txt.qs.partial');
      Link(partial).createSync(victim.path);
      expect(
          () => SafePath.commitFile(
              base.path, partial, p.join(base.path, 'a.txt')),
          throwsA(isA<UnsafePathException>()));
      expect(victim.readAsStringSync(), 'vvv');
      expect(File(p.join(base.path, 'a.txt')).existsSync(), isFalse);
    });
  });

  group('commitDirectory', () {
    Directory staged() {
      final d = Directory(p.join(base.path, 'Trip.qs.partial'))..createSync();
      File(p.join(d.path, 'one.jpg')).writeAsStringSync('1');
      return d;
    }

    test('renames a staged folder onto a free name', () async {
      final d = staged();
      final used = await commitDirectory(d.path, p.join(base.path, 'Trip'),
          base: base.path);
      expect(used, p.join(base.path, 'Trip'));
      expect(File(p.join(used, 'one.jpg')).readAsStringSync(), '1');
      expect(d.existsSync(), isFalse);
    });

    test('never replaces a folder that is there, even an empty one', () async {
      final d = staged();
      final mine = Directory(p.join(base.path, 'Trip'))..createSync();
      final used = await commitDirectory(d.path, mine.path, base: base.path);
      expect(used, p.join(base.path, 'Trip (1)'));
      expect(mine.listSync(), isEmpty,
          reason: 'the user\'s folder is left exactly as it was');
      expect(File(p.join(used, 'one.jpg')).readAsStringSync(), '1');
    });

    test('never replaces a link, dangling or not', () async {
      final d = staged();
      final link = Link(p.join(base.path, 'Trip'))
        ..createSync(p.join(outside.path, 'nope'));
      final before = snapshot(outside);
      final used = await commitDirectory(d.path, link.path, base: base.path);
      expect(used, p.join(base.path, 'Trip (1)'));
      expect(FileSystemEntity.isLinkSync(link.path), isTrue);
      expect(snapshot(outside), before);
    });

    test('never replaces a file', () async {
      final d = staged();
      final file = File(p.join(base.path, 'Trip'))..writeAsStringSync('mine');
      final used = await commitDirectory(d.path, file.path, base: base.path);
      expect(used, p.join(base.path, 'Trip (1)'));
      expect(file.readAsStringSync(), 'mine');
    });
  });

  group('windows path length', () {
    test('a path over MAX_PATH is refused with a clear error', () {
      final long = 'C:\\Users\\me\\Downloads\\${'x' * 260}.bin';
      expect(() => SafePath.assertPathLength(long, os: 'windows'),
          throwsA(isA<PathTooLongException>()));
    });

    test('a path under it passes', () {
      SafePath.assertPathLength(r'C:\Users\me\Downloads\a.bin', os: 'windows');
    });

    test('other systems have no such limit', () {
      SafePath.assertPathLength('/${'x' * 300}', os: 'macos');
    });

    test('259 characters is the longest a classic Windows path can be', () {
      // MAX_PATH is 260 including the terminating NUL.
      final fits = 'C:\\${'x' * (259 - 3)}';
      expect(fits.length, 259);
      SafePath.assertPathLength(fits, os: 'windows');
      expect(() => SafePath.assertPathLength('${fits}x', os: 'windows'),
          throwsA(isA<PathTooLongException>()));
    });

    test('the message says what to do about it', () {
      try {
        SafePath.assertPathLength('C:\\${'x' * 300}', os: 'windows');
        fail('should have been refused');
      } on PathTooLongException catch (e) {
        expect(e.message, contains('260'));
      }
    });
  });

  group('durable file through the helper', () {
    test('DurableFile with a base never writes through a link', () async {
      Link(p.join(base.path, 'sub')).createSync(outside.path);
      final before = snapshot(outside);
      final f = DurableFile(p.join(base.path, 'sub', 'a.bin'), base: base.path);
      await expectLater(f.open(), throwsA(isA<UnsafePathException>()));
      expect(snapshot(outside), before);
    });

    test('DurableFile commit refuses a folder that was moved away and '
        'linked back', () async {
      final f = DurableFile(p.join(base.path, 'sub', 'a.bin'), base: base.path);
      await f.open();
      await f.add(Uint8List.fromList([1, 2, 3]));
      final moved = p.join(outside.path, 'moved');
      Directory(p.join(base.path, 'sub')).renameSync(moved);
      Link(p.join(base.path, 'sub')).createSync(moved);

      await expectLater(f.commit(), throwsA(isA<UnsafePathException>()));

      expect(File(p.join(moved, 'a.bin')).existsSync(), isFalse,
          reason: 'the commit followed the link and named the file outside');
    },
        // Windows refuses to move a folder that has an open file in it, to
        // anyone, so there this swap cannot happen while the partial is open.
        // The swap at the moment it can — once the file is closed — is the
        // next test, and runs everywhere.
        skip: Platform.isWindows
            ? 'Windows will not move a folder that has an open file in it'
            : false);

    test('DurableFile commit refuses a folder that was moved away and '
        'linked back once the file is closed', () async {
      final f = DurableFile(p.join(base.path, 'sub', 'a.bin'), base: base.path);
      await f.open();
      await f.add(Uint8List.fromList([1, 2, 3]));
      final moved = p.join(outside.path, 'moved');
      var swapped = false;
      // `commit` has closed the file and is about to look at the folders and
      // move it: the first moment any system lets the folder be moved.
      SafePath.debugRace = (stage, path) {
        if (stage != 'seal' || swapped) return;
        Directory(p.join(base.path, 'sub')).renameSync(moved);
        Link(p.join(base.path, 'sub')).createSync(moved);
        swapped = true;
      };
      addTearDown(() => SafePath.debugRace = null);

      await expectLater(f.commit(), throwsA(isA<UnsafePathException>()));

      expect(swapped, isTrue, reason: 'the moment was never reached');
      expect(File(p.join(moved, 'a.bin')).existsSync(), isFalse,
          reason: 'the commit followed the link and named the file outside');
    });

    test('commitDirectory refuses a parent that was moved away and linked '
        'back', () async {
      final sub = Directory(p.join(base.path, 'sub'))..createSync();
      final staged = Directory(p.join(sub.path, 'Trip.qs.partial'))
        ..createSync();
      File(p.join(staged.path, 'one.jpg')).writeAsStringSync('1');
      final moved = p.join(outside.path, 'moved');
      sub.renameSync(moved);
      Link(sub.path).createSync(moved);

      await expectLater(
          commitDirectory(staged.path, p.join(sub.path, 'Trip'),
              base: base.path),
          throwsA(isA<UnsafePathException>()));

      expect(Directory(p.join(moved, 'Trip')).existsSync(), isFalse);
    });

    test('DurableFile commit does not replace and reports the name used',
        () async {
      final f = DurableFile(p.join(base.path, 'a.bin'), base: base.path);
      await f.open();
      await f.add(Uint8List.fromList([1, 2, 3]));
      File(p.join(base.path, 'a.bin')).writeAsStringSync('mine');

      final used = await f.commit();

      expect(used, p.join(base.path, 'a (1).bin'));
      expect(File(p.join(base.path, 'a.bin')).readAsStringSync(), 'mine');
      expect(File(used).readAsBytesSync(), [1, 2, 3]);
    });
  });

  group('discard', () {
    test('removes a partial that is where it should be', () {
      final partial = File(p.join(base.path, 'a', 'x.bin.qs.partial'))
        ..createSync(recursive: true);

      expect(SafePath.discard(base.path, partial.path), isTrue);

      expect(partial.existsSync(), isFalse);
    });

    test('a name that is not there is already clear', () {
      expect(SafePath.discard(base.path, p.join(base.path, 'nope', 'x')),
          isTrue);
    });

    test('a link at the name goes, and what it pointed at stays', () {
      final keep = File(p.join(outside.path, 'keep.txt'))
        ..writeAsStringSync('keep');
      final name = p.join(base.path, 'x.bin.qs.partial');
      if (!linkOrSkip(name, keep.path)) return;

      expect(SafePath.discard(base.path, name), isTrue);

      expect(FileSystemEntity.typeSync(name, followLinks: false),
          FileSystemEntityType.notFound);
      expect(keep.readAsStringSync(), 'keep');
    });

    test('a folder above it that is a link: nothing is deleted, and it says '
        'so', () {
      Directory(p.join(base.path, 'a')).createSync();
      final here = File(p.join(base.path, 'a', 'x.bin.qs.partial'))
        ..writeAsStringSync('ours');
      Directory(p.join(base.path, 'a')).renameSync(p.join(base.path, 'moved'));
      if (!linkOrSkip(p.join(base.path, 'a'), outside.path)) return;
      File(p.join(outside.path, 'x.bin.qs.partial'))
          .writeAsStringSync('theirs');
      final before = snapshot(outside);

      expect(SafePath.discard(base.path, here.path), isFalse);

      expect(snapshot(outside), before);
      expect(File(p.join(base.path, 'moved', 'x.bin.qs.partial'))
          .readAsStringSync(), 'ours');
    });

    test('a path that is not under the destination at all is left alone', () {
      final stranger = File(p.join(outside.path, 'x.bin.qs.partial'))
        ..writeAsStringSync('theirs');

      expect(SafePath.discard(base.path, stranger.path), isFalse);

      expect(stranger.readAsStringSync(), 'theirs');
    });

    test('a folder at the name is not a partial, and is left', () {
      final folder = Directory(p.join(base.path, 'x.bin.qs.partial'))
        ..createSync();
      File(p.join(folder.path, 'inside')).writeAsStringSync('keep');

      expect(SafePath.discard(base.path, folder.path), isFalse);

      expect(File(p.join(folder.path, 'inside')).readAsStringSync(), 'keep');
    });

    test('with no destination named, the folder that holds it stands in', () {
      final partial = File(p.join(base.path, 'x.bin.qs.partial'))
        ..writeAsStringSync('ours');

      expect(SafePath.discard(null, partial.path), isTrue);
      expect(SafePath.discard('', partial.path), isTrue);

      expect(partial.existsSync(), isFalse);
    });
  });
}

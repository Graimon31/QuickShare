// What only a Windows machine can say about the storage layer.
//
// Everything below runs production code against the real NTFS volume, the real
// Win32 calls and the real reparse points of the machine it runs on. On any
// other platform the file is skipped whole (`@TestOn`); there is no per-test
// `skip:` hiding a failure on Windows. The two places where a test cannot run
// without rights the runner may not have — creating a symbolic link, mounting a
// small virtual disk — say so in the output (`SYMLINK_SKIPPED=`,
// `VHD_SKIPPED=`) and skip only that test, and only for that reason.
//
//     flutter test --no-pub test/platform/windows_native_test.dart --reporter=expanded
//
// CI runs it as job `test_windows_native` in .github/workflows/build_desktop.yml
// on windows-latest, where the runner is an administrator, so both rights are
// there and nothing is skipped.
//
// Lines worth reading in the output:
//
//     DISK_PROBE_BYTES=<n>   what WindowsDiskSpaceProbe says is free on the
//                            temp volume (compare with `Get-PSDrive`)
//     VHD_DISK_FULL=...      the error a genuinely full 16 MiB NTFS volume gave
@TestOn('windows')
library;

// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/security/path_sanitizer.dart';
import 'package:quickshare/core/storage/disk_space.dart';
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/storage/safe_path.dart';
import 'package:quickshare/core/storage/storage_failure.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';

import '../integration/qhtp_receive_harness.dart';

/// Runs `cmd /c mklink …` and says whether it worked, and if not why.
({bool ok, String output}) _mklink(List<String> args) {
  final result = Process.runSync('cmd', ['/c', 'mklink', ...args]);
  final output = '${result.stdout}${result.stderr}'.trim();
  return (ok: result.exitCode == 0, output: output);
}

void main() {
  late Directory root;
  final links = <String>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_win_native_');
    links.clear();
  });

  tearDown(() {
    // Links first, so that nothing below is deleted through one.
    for (final link in links.reversed) {
      try {
        if (FileSystemEntity.typeSync(link, followLinks: false) ==
            FileSystemEntityType.link) {
          Link(link).deleteSync();
        }
      } catch (_) {}
    }
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      print('could not remove ${root.path}: $e');
    }
  });

  String at(String relative) => p.join(root.path, relative);

  File put(String path, String content) {
    File(path).parent.createSync(recursive: true);
    return File(path)..writeAsStringSync(content);
  }

  /// A junction: `mklink /J` needs no privilege, so this one must work
  /// everywhere. Failing to make it is a failure of the test machine, and says
  /// so.
  void junction(String link, String target) {
    final made = _mklink(['/J', link, target]);
    expect(made.ok, isTrue, reason: 'mklink /J failed: ${made.output}');
    links.add(link);
  }

  /// A symbolic link needs a privilege (or Developer Mode). Returns false, and
  /// prints why, when this machine has not got it.
  bool trySymlink(String link, String target, {bool directory = false}) {
    final made = _mklink([if (directory) '/D', link, target]);
    if (!made.ok) {
      print('SYMLINK_SKIPPED=${made.output}');
      return false;
    }
    links.add(link);
    return true;
  }

  // ===========================================================================
  group('WindowsDiskSpaceProbe', () {
    /// `Get-PSDrive` free bytes for the drive [path] is on: an answer that
    /// comes from outside the code under test.
    int powershellFree(String path) {
      final letter = p.rootPrefix(p.absolute(path))[0];
      final out = Process.runSync('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '[long](Get-PSDrive -Name $letter).Free',
      ]);
      expect(out.exitCode, 0, reason: '${out.stderr}');
      return int.parse('${out.stdout}'.trim());
    }

    test('is the platform probe, and agrees with PowerShell about the volume',
        () async {
      final probe = DiskSpaceProbe.forCurrentPlatform();
      expect(probe, isA<WindowsDiskSpaceProbe>());

      final before = powershellFree(root.path);
      final space = await probe.available(root.path);
      final after = powershellFree(root.path);

      expect(space.isKnown, isTrue, reason: space.unknownReason);
      expect(space.availableBytes, greaterThan(0));
      print('DISK_PROBE_BYTES=${space.availableBytes} '
          '(powershell before=$before after=$after)');

      const tolerance = 64 * 1024 * 1024;
      expect(space.availableBytes!,
          inInclusiveRange(min(before, after) - tolerance,
              max(before, after) + tolerance),
          reason: 'GetDiskFreeSpaceExW and Get-PSDrive read the same volume');
    });

    test('a path that does not exist yet is answered for its nearest parent',
        () async {
      final probe = WindowsDiskSpaceProbe();
      final existing = await probe.available(root.path);
      final deep = await probe.available(at(r'not\there\yet\at\all'));

      expect(existing.isKnown, isTrue, reason: existing.unknownReason);
      expect(deep.isKnown, isTrue, reason: deep.unknownReason);
      expect((deep.availableBytes! - existing.availableBytes!).abs(),
          lessThan(64 * 1024 * 1024));
      expect(Directory(at('not')).existsSync(), isFalse,
          reason: 'asking must not create anything');
    });

    test('a drive that is not there is unknown, with a reason and no crash',
        () async {
      String? missing;
      for (final letter in 'ZYXWVUTSRQPONMLKJIHGFED'.split('')) {
        if (!Directory('$letter:\\').existsSync()) {
          missing = letter;
          break;
        }
      }
      expect(missing, isNotNull, reason: 'every drive letter is in use');

      final space = await WindowsDiskSpaceProbe()
          .available('$missing:\\nothing\\here')
          .timeout(const Duration(seconds: 30));

      expect(space.isKnown, isFalse,
          reason: 'there is no volume to measure; a number would be invented');
      expect(space.unknownReason, contains('GetDiskFreeSpaceExW'));
    });
  });

  // ===========================================================================
  group('links', () {
    test('a junction in the destination chain is a link: refused, and nothing '
        'is written through it', () {
      final base = Directory(at('dest'))..createSync();
      final target = Directory(at('elsewhere'))..createSync();
      junction(p.join(base.path, 'Trip'), target.path);

      expect(
          FileSystemEntity.typeSync(p.join(base.path, 'Trip'),
              followLinks: false),
          FileSystemEntityType.link,
          reason: 'dart:io must report a junction as a link, or every check '
              'built on it is blind to it');

      expect(
          () => SafePath.assertNoLinksBelow(
              base.path, p.join(base.path, 'Trip', 'a.bin')),
          throwsA(isA<UnsafePathException>()));
      expect(() => SafePath.resolve(r'Trip\a.bin', base.path),
          throwsA(isA<UnsafePathException>()));
      expect(
          () => SafePath.ensureParents(
              base.path, p.join(base.path, 'Trip', 'deep', 'a.bin')),
          throwsA(isA<UnsafePathException>()));
      expect(
          () => SafePath.openPartial(
              base.path, p.join(base.path, 'Trip', 'a.bin.qs.partial'),
              truncate: true),
          throwsA(isA<UnsafePathException>()));
      expect(
          () => SafePath.commitFile(
              base.path,
              put(at(r'dest\loose.qs.partial'), 'x').path,
              p.join(base.path, 'Trip', 'a.bin')),
          throwsA(isA<UnsafePathException>()));

      expect(target.listSync(), isEmpty,
          reason: 'something was created on the far side of the junction');
    });

    test('a directory symlink in the chain is refused the same way', () {
      final base = Directory(at('dest'))..createSync();
      final target = Directory(at('elsewhere'))..createSync();
      if (!trySymlink(p.join(base.path, 'Trip'), target.path,
          directory: true)) {
        markTestSkipped('this machine cannot create symbolic links '
            '(see SYMLINK_SKIPPED above)');
        return;
      }

      expect(
          FileSystemEntity.typeSync(p.join(base.path, 'Trip'),
              followLinks: false),
          FileSystemEntityType.link);
      expect(() => SafePath.resolve(r'Trip\a.bin', base.path),
          throwsA(isA<UnsafePathException>()));
      expect(
          () => SafePath.openPartial(
              base.path, p.join(base.path, 'Trip', 'a.bin.qs.partial'),
              truncate: true),
          throwsA(isA<UnsafePathException>()));
      expect(target.listSync(), isEmpty);
    });

    test('a file symlink standing where the partial goes is never truncated '
        'through', () {
      final base = Directory(at('dest'))..createSync();
      final victim = put(at(r'outside\victim.bin'), 'precious bytes');
      final partial = p.join(base.path, 'a.bin.qs.partial');
      if (!trySymlink(partial, victim.path)) {
        markTestSkipped('this machine cannot create symbolic links '
            '(see SYMLINK_SKIPPED above)');
        return;
      }

      final raf = SafePath.openPartial(base.path, partial, truncate: true);
      raf.writeStringSync('fresh');
      raf.closeSync();

      expect(victim.readAsStringSync(), 'precious bytes');
      expect(FileSystemEntity.typeSync(partial, followLinks: false),
          FileSystemEntityType.file);
      expect(File(partial).readAsStringSync(), 'fresh');
    });
  });

  // ===========================================================================
  group('cleaning up after a failure', () {
    // Throwing away a half-written file is a delete by path, and a delete by
    // path follows every folder above the file. A junction is the link Windows
    // lets anybody make, so it is the one that matters here.
    test('abort does not delete through a junction in the chain', () async {
      final base = Directory(at('dest'))..createSync();
      final target = Directory(at('elsewhere'))..createSync();
      junction(p.join(base.path, 'Trip'), target.path);
      final foreign = put(p.join(target.path, 'a.bin.qs.partial'), 'not ours');
      final inner = put(p.join(target.path, 'b.bin'), 'not ours either');

      // Never opened: Windows will not move a folder that holds an open file,
      // so the state to test is "the chain has a link in it when the delete
      // comes", and a file that was never opened is in exactly that state.
      await DurableFile(p.join(base.path, 'Trip', 'a.bin'), base: base.path)
          .abort();
      await DurableFile(p.join(base.path, 'Trip', 'b.bin'),
              staged: false, base: base.path)
          .abort();

      expect(foreign.readAsStringSync(), 'not ours');
      expect(inner.readAsStringSync(), 'not ours either');
    });

    test('SafePath.discard leaves the file and says so, and never throws', () {
      final base = Directory(at('dest'))..createSync();
      final target = Directory(at('elsewhere'))..createSync();
      junction(p.join(base.path, 'Trip'), target.path);
      final foreign = put(p.join(target.path, 'a.bin.qs.partial'), 'not ours');

      final cleared = SafePath.discard(
          base.path, p.join(base.path, 'Trip', 'a.bin.qs.partial'));

      expect(cleared, isFalse);
      expect(foreign.readAsStringSync(), 'not ours');
    });

    test('a directory symlink in the chain is treated the same way', () {
      final base = Directory(at('dest'))..createSync();
      final target = Directory(at('elsewhere'))..createSync();
      if (!trySymlink(p.join(base.path, 'Trip'), target.path,
          directory: true)) {
        markTestSkipped('this machine cannot create symbolic links '
            '(see SYMLINK_SKIPPED above)');
        return;
      }
      final foreign = put(p.join(target.path, 'a.bin.qs.partial'), 'not ours');

      expect(
          SafePath.discard(
              base.path, p.join(base.path, 'Trip', 'a.bin.qs.partial')),
          isFalse);
      expect(foreign.readAsStringSync(), 'not ours');
    });

    test('a junction standing where the partial goes is removed as a junction, '
        'and what it points at is left', () {
      final base = Directory(at('dest'))..createSync();
      final target = Directory(at('elsewhere'))..createSync();
      final keep = put(p.join(target.path, 'keep.txt'), 'keep');
      final partial = p.join(base.path, 'a.bin.qs.partial');
      junction(partial, target.path);

      expect(SafePath.discard(base.path, partial), isTrue);

      expect(FileSystemEntity.typeSync(partial, followLinks: false),
          FileSystemEntityType.notFound);
      expect(keep.readAsStringSync(), 'keep');
    });
  });

  // ===========================================================================
  group('renaming without replacing', () {
    test('an ordinary rename onto a free name works', () {
      final from = put(at('src.bin'), 'payload');
      SafePath.renameNoClobber(from.path, at('dst.bin'));
      expect(File(at('dst.bin')).readAsStringSync(), 'payload');
      expect(from.existsSync(), isFalse);
    });

    test('an existing file is refused and left exactly as it was', () {
      final from = put(at('src.bin'), 'incoming');
      final taken = put(at('dst.bin'), 'the user\'s own file');

      expect(() => SafePath.renameNoClobber(from.path, taken.path),
          throwsA(isA<PathTakenException>()));

      expect(taken.readAsStringSync(), 'the user\'s own file');
      expect(from.readAsStringSync(), 'incoming');
    });

    test('a junction at the destination is a taken name', () {
      final from = put(at('src.bin'), 'incoming');
      final target = Directory(at('elsewhere'))..createSync();
      put(p.join(target.path, 'keep.txt'), 'keep');
      junction(at('dst.bin'), target.path);

      expect(() => SafePath.renameNoClobber(from.path, at('dst.bin')),
          throwsA(isA<PathTakenException>()));

      expect(File(p.join(target.path, 'keep.txt')).readAsStringSync(), 'keep');
      expect(target.listSync().length, 1);
      expect(from.readAsStringSync(), 'incoming');
    });

    test('a file symlink at the destination is a taken name', () {
      final from = put(at('src.bin'), 'incoming');
      final target = put(at(r'elsewhere\t.bin'), 'target');
      if (!trySymlink(at('dst.bin'), target.path)) {
        markTestSkipped('this machine cannot create symbolic links '
            '(see SYMLINK_SKIPPED above)');
        return;
      }

      expect(() => SafePath.renameNoClobber(from.path, at('dst.bin')),
          throwsA(isA<PathTakenException>()));
      expect(target.readAsStringSync(), 'target');
    });

    test('a folder is refused onto an existing one, and commitDirectory gives '
        'the newcomer the next free name', () {
      final base = Directory(at('dest'))..createSync();
      final taken = Directory(p.join(base.path, 'Trip'))..createSync();
      put(p.join(taken.path, 'mine.txt'), 'mine');

      final staged1 = Directory(p.join(base.path, 'one.qs.partial'))
        ..createSync();
      put(p.join(staged1.path, 'a.txt'), 'a');
      expect(
          () => SafePath.renameDirectoryNoClobber(staged1.path, taken.path),
          throwsA(isA<PathTakenException>()));
      expect(File(p.join(taken.path, 'mine.txt')).readAsStringSync(), 'mine');
      expect(File(p.join(staged1.path, 'a.txt')).existsSync(), isTrue);

      final landed =
          SafePath.commitDirectory(base.path, staged1.path, taken.path);
      expect(landed, p.join(base.path, 'Trip (1)'));
      expect(File(p.join(landed, 'a.txt')).readAsStringSync(), 'a');
      expect(taken.listSync().length, 1, reason: 'the original was not touched');
    });

    test('committing a file onto a taken name lands as "name (1)"', () {
      final base = Directory(at('dest'))..createSync();
      final taken = put(p.join(base.path, 'photo.jpg'), 'the user\'s');
      final partial = put(p.join(base.path, 'photo.jpg.qs.partial'), 'received');

      final landed = SafePath.commitFile(
          base.path, partial.path, p.join(base.path, 'photo.jpg'));

      expect(landed, p.join(base.path, 'photo (1).jpg'));
      expect(taken.readAsStringSync(), 'the user\'s');
      expect(File(landed).readAsStringSync(), 'received');
    });
  });

  // ===========================================================================
  group('names and lengths', () {
    test('a path of 260 characters or more is refused as too long, and no '
        'partial file appears', () async {
      final base = Directory(at('dest'))..createSync();
      // Long enough that the partial path, base and all, passes MAX_PATH while
      // the name itself stays under the 255 a single component may have.
      var name = 'a' * 200;
      while (p.join(base.path, '$name.bin').length < 262) {
        name += 'a';
      }
      expect(name.length, lessThanOrEqualTo(240));
      final target = p.join(base.path, '$name.bin');
      expect(target.length, greaterThanOrEqualTo(SafePath.windowsMaxPath));

      final file = DurableFile(target, base: base.path);
      Object? error;
      try {
        await file.open();
      } catch (e) {
        error = e;
      }

      expect(error, isA<PathTooLongException>());
      expect(classifyStorageError(error)?.code, FailureCode.pathTooLong);
      expect(base.listSync(), isEmpty,
          reason: 'a partial was created at a path Windows cannot open again');
      expect(File('$target$kPartialSuffix').existsSync(), isFalse);
    });

    test('a path just under the limit is written, synced and committed',
        () async {
      final base = Directory(at('dest'))..createSync();
      var name = 'b' * 150;
      // The partial is 11 characters longer than the name: keep it below 260.
      while (p.join(base.path, '$name.bin$kPartialSuffix').length < 259) {
        name += 'b';
      }
      final target = p.join(base.path, '$name.bin');
      expect('$target$kPartialSuffix'.length, lessThan(260));

      final file = DurableFile(target, base: base.path);
      await file.open();
      await file.add([1, 2, 3, 4]);
      final landed = await file.commit();

      expect(landed, target);
      expect(File(target).readAsBytesSync(), [1, 2, 3, 4]);
      expect(File('$target$kPartialSuffix').existsSync(), isFalse);
    });

    test('reserved device names and trailing dots and spaces land under safe '
        'names, and no device is opened', () async {
      final base = Directory(at('dest'))..createSync();
      const raw = <String, String>{
        r'CONIN$': r'_CONIN$',
        r'CONOUT$': r'_CONOUT$',
        'con.txt': '_con.txt',
        'NUL': '_NUL',
        'com1': '_com1',
        'LPT\u00B9': '_LPT\u00B9',
        'con .txt': '_con .txt',
        'prn.': '_prn',
        'report.pdf.': 'report.pdf',
        'report2.pdf ': 'report2.pdf',
        'both.txt. .': 'both.txt',
      };

      for (final entry in raw.entries) {
        expect(PathSanitizer.isWindowsReserved(entry.key) ||
            entry.key.endsWith('.') ||
            entry.key.endsWith(' '), isTrue,
            reason: 'the table below is only meaningful for names Windows '
                'treats specially: "${entry.key}"');

        final path = SafePath.resolve(entry.key, base.path);
        expect(p.basename(path), entry.value, reason: 'for "${entry.key}"');

        final file = DurableFile(path, base: base.path);
        await file.open();
        await file.add([7, 7, 7]);
        await file.commit();
      }

      final names = base.listSync().map((e) => p.basename(e.path)).toSet();
      expect(names, raw.values.toSet(),
          reason: 'every name must have become an ordinary file in the folder');
      for (final name in raw.values) {
        expect(File(p.join(base.path, name)).readAsBytesSync(), [7, 7, 7],
            reason: name);
      }
    });
  });

  // ===========================================================================
  group('a full volume', () {
    test('isDiskFull matches the Windows codes, and not the one that shares '
        '39 with ENOTEMPTY elsewhere', () {
      FileSystemException withCode(int code) =>
          FileSystemException('write failed', r'C:\x', OSError('whatever', code));

      expect(isDiskFull(withCode(112)), isTrue,
          reason: 'ERROR_DISK_FULL, in any language');
      expect(isDiskFull(withCode(39)), isTrue, reason: 'ERROR_HANDLE_DISK_FULL');
      expect(isDiskFull(withCode(5)), isFalse, reason: 'ERROR_ACCESS_DENIED');
      expect(isDiskFull(withCode(32)), isFalse,
          reason: 'ERROR_SHARING_VIOLATION is not a full disk');
    });

    test('a genuinely full NTFS volume (16 MiB VHD) is recognised as full',
        () async {
      final vhd = await _tryAttachVhd(root);
      if (vhd.letter == null) {
        print('VHD_SKIPPED=${vhd.why}');
        markTestSkipped('a small virtual disk could not be mounted here: '
            '${vhd.why}');
        return;
      }
      final drive = '${vhd.letter}:\\';
      try {
        // The probe sees a volume of a few MiB.
        final space = await WindowsDiskSpaceProbe().available(drive);
        expect(space.isKnown, isTrue, reason: space.unknownReason);
        expect(space.availableBytes!, lessThan(17 * 1024 * 1024));
        await expectLater(
            requireFreeSpace(WindowsDiskSpaceProbe(), p.join(drive, 'x.bin'),
                remainingBytes: 20 * 1024 * 1024, margin: 0),
            throwsA(isA<NotEnoughSpaceException>()));

        // And writing past the end gives the error the receive paths classify.
        final file = DurableFile(p.join(drive, 'big.bin'), base: drive);
        await file.open();
        FileSystemException? full;
        final chunk = List<int>.filled(1024 * 1024, 9);
        try {
          for (var i = 0; i < 40; i++) {
            await file.add(chunk);
          }
        } on FileSystemException catch (e) {
          full = e;
        }
        await file.abort();

        expect(full, isNotNull, reason: 'forty MiB were written to 16 MiB');
        print('VHD_DISK_FULL errno=${full!.osError?.errorCode} '
            'message="${full.osError?.message}"');
        expect(full.osError?.errorCode, 112,
            reason: 'ERROR_DISK_FULL, whatever language Windows speaks');
        expect(isDiskFull(full), isTrue);
        expect(classifyStorageError(full)?.code, FailureCode.diskFull);
      } finally {
        await _detachVhd(vhd);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  // ===========================================================================
  group('QHTP over loopback on NTFS', () {
    setUpAll(installFakeWakelock);

    late QhtpHarness h;
    setUp(() async => h = await QhtpHarness.create());
    tearDown(() => h.dispose());

    Uint8List bytesOf(int n, int seed) {
      final rand = Random(seed);
      return Uint8List.fromList(List.generate(n, (_) => rand.nextInt(256)));
    }

    String shaOf(List<int> b) => sha256.convert(b).toString();

    test('a cut transfer resumes through a Range request and the file is '
        'identical', () async {
      final data = bytesOf(1024 * 1024, 4242);
      await h.serve({'video.bin': data});
      const have = 300 * 1024;
      final partial = File(h.received('video.bin.qs.partial'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(data.sublist(0, have));

      final result = await h
          .client()
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path);
      expectReceived(result);

      final fileRequest = h.requests.firstWhere((r) => r.isFile);
      expect(fileRequest.range, 'bytes=$have-');
      expect(shaOf(File(h.received('video.bin')).readAsBytesSync()),
          shaOf(data));
      expect(partial.existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('first file delivered, transfer cut, file deleted, resumed: it is '
        'fetched again and its sha256 matches', () async {
      final a = bytesOf(300 * 1024, 1);
      final b = bytesOf(120 * 1024, 2);
      await h.serve({'a.bin': a, 'b.bin': b});

      late QhtpReceiverClient first;
      first = h.client(onRequest: (r) {
        if (r.isFile && r.fileId == h.idOf('b.bin')) first.cancel();
      });
      expectRefused(await first.downloadSession(
          payload: h.payload, targetBaseDir: h.target.path));
      expect(shaOf(File(h.received('a.bin')).readAsBytesSync()), shaOf(a));

      // Windows will not delete a file something still has open; the receiver
      // must have let go of it by now.
      File(h.received('a.bin')).deleteSync();

      h.requests.clear();
      expectReceived(await h
          .client()
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path));

      expect(h.fileRequestsFor('a.bin'), 1);
      expect(h.fileRequestsFor('b.bin'), 1);
      expect(shaOf(File(h.received('a.bin')).readAsBytesSync()), shaOf(a));
      expect(shaOf(File(h.received('b.bin')).readAsBytesSync()), shaOf(b));
      expect(File(h.received('a (1).bin')).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

// --- a small NTFS volume -----------------------------------------------------

class _Vhd {
  _Vhd(this.letter, this.file, this.why);
  final String? letter;
  final String file;
  final String why;
}

/// Mounts a fixed 16 MiB NTFS virtual disk on a free drive letter with
/// `diskpart`, which needs administrator rights — and a GitHub windows runner
/// has them. When it cannot be done, [_Vhd.letter] is null and [_Vhd.why] says
/// what diskpart answered.
Future<_Vhd> _tryAttachVhd(Directory scratch) async {
  String? letter;
  for (final candidate in 'ZYXWVUTSRQPONMLKJIHGFED'.split('')) {
    if (!Directory('$candidate:\\').existsSync()) {
      letter = candidate;
      break;
    }
  }
  final file = p.join(scratch.path, 'ddfull.vhd');
  if (letter == null) return _Vhd(null, file, 'no free drive letter');

  final script = File(p.join(scratch.path, 'attach.txt'))
    ..writeAsStringSync([
      'create vdisk file="$file" maximum=16 type=fixed',
      'select vdisk file="$file"',
      'attach vdisk',
      'create partition primary',
      'format fs=ntfs quick label=DDFULL',
      'assign letter=$letter',
      'exit',
    ].join('\r\n'));

  final result = await Process.run('diskpart', ['/s', script.path]);
  final said = '${result.stdout}${result.stderr}'.replaceAll(RegExp(r'\s+'), ' ');
  for (var i = 0; i < 40; i++) {
    if (Directory('$letter:\\').existsSync()) return _Vhd(letter, file, '');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  // Whatever was half-made goes again.
  await _detachVhd(_Vhd(letter, file, ''));
  return _Vhd(null, file, 'diskpart exit ${result.exitCode}: $said');
}

Future<void> _detachVhd(_Vhd vhd) async {
  final script = File('${vhd.file}.detach.txt');
  try {
    if (!File(vhd.file).existsSync()) return;
    script.writeAsStringSync([
      'select vdisk file="${vhd.file}"',
      'detach vdisk',
      'exit',
    ].join('\r\n'));
    await Process.run('diskpart', ['/s', script.path]);
  } catch (e) {
    print('could not detach ${vhd.file}: $e');
  }
}

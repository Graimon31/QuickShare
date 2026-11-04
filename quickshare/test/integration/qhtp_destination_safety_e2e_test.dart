// FS-01 — the destination folder is the user's, and a sender (or anything else
// that can write there) must not be able to turn a transfer into a write
// somewhere else, or into the loss of something that is already there.
//
// Names from the manifest were cleaned lexically — no `..`, no separators —
// and that was the whole defence. A symlink already sitting in the destination
// walks straight past it: the receiver created folders, opened partials and
// renamed files through whatever the path happened to resolve to. And
// `File.rename` replaces an existing file silently, so a file that appeared
// under the chosen name during the download was overwritten at the last step.
//
// Policy under test: inside the destination, no write ever follows a symlink
// (even one that points back inside), a name that is taken in any way — a file,
// a folder, a dangling link — is taken, and the final step never replaces.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/security/path_sanitizer.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_receive_result.dart';

import 'qhtp_receive_harness.dart';

Uint8List _bytes(int n, int seed) {
  final rand = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => rand.nextInt(256)));
}

void main() {
  setUpAll(installFakeWakelock);

  late QhtpHarness h;
  final a = _bytes(150 * 1024, 11);
  final z = _bytes(90 * 1024, 12);

  setUp(() async => h = await QhtpHarness.create());
  tearDown(() => h.dispose());

  Future<Either<Failure, QhtpReceiveResult>> receive({
    RequestHook? onRequest,
  }) =>
      h.client(onRequest: onRequest).downloadSession(
          payload: h.payload, targetBaseDir: h.target.path);

  String top() => p.join(h.target.path, p.basename(h.source.path));

  group('ordinary names', () {
    test('nested folders are rebuilt, Unicode names included', () async {
      await h.serve({
        'сад/глубже/файл №1.bin': a,
        'photos/2026/IMG_0042.HEIC': z,
      });

      expectReceived(await receive());

      expect(File(h.received('сад/глубже/файл №1.bin')).readAsBytesSync(), a);
      expect(File(h.received('photos/2026/IMG_0042.HEIC')).readAsBytesSync(), z);
    });
  });

  group('names near the filesystem limit', () {
    test('a 250-byte name still lands: its .qs.partial has to fit too',
        () async {
      // The final name is within the 255-byte limit; the partial beside it is
      // 11 bytes longer. A receiver that sanitised to exactly 255 failed such
      // a transfer after three retries, with "File name too long".
      final name = '${'n' * 246}.bin';
      expect(name.length, 250);
      await h.serve({name: a});

      expectReceived(await receive());

      final landed = Directory(top())
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.bin'))
          .toList();
      expect(landed, hasLength(1));
      expect(landed.single.readAsBytesSync(), a);
      expect(p.basename(landed.single.path), endsWith('.bin'));
    });

    test('and the numbered name beside an existing one fits as well',
        () async {
      final name = '${'m' * 246}.bin';
      await h.serve({name: a});
      Directory(top()).createSync(recursive: true);
      final existing = PathSanitizer.sanitizeSegment(name);
      File(p.join(top(), existing)).writeAsStringSync('mine');

      expectReceived(await receive());

      expect(File(p.join(top(), existing)).readAsStringSync(), 'mine');
      final others = Directory(top())
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path) != existing)
          .toList();
      expect(others, hasLength(1));
      expect(others.single.readAsBytesSync(), a);
    });
  });

  group('a symlink in the destination is never followed', () {
    test('the top-level folder is a link to somewhere else', () async {
      await h.serve({'sub/z.bin': z, 'a.bin': a});
      Link(top()).createSync(h.outside.path);
      final before = QhtpHarness.snapshot(h.outside);

      final failure = expectRefused(await receive());

      expect(failure.code, FailureCode.unsafeDestination);
      expect(QhtpHarness.snapshot(h.outside), before,
          reason: 'not a byte may land outside the destination');
    });

    test('a sub-folder is a link to somewhere else', () async {
      await h.serve({'sub/z.bin': z});
      Directory(top()).createSync(recursive: true);
      Link(p.join(top(), 'sub')).createSync(h.outside.path);
      final before = QhtpHarness.snapshot(h.outside);

      final failure = expectRefused(await receive());

      expect(failure.code, FailureCode.unsafeDestination);
      expect(QhtpHarness.snapshot(h.outside), before);
    });

    test('a sub-folder is a link to another folder inside the destination',
        () async {
      // Pointing back inside is no safer to follow: it is still a name the
      // user did not expect the file to appear under.
      await h.serve({'sub/z.bin': z});
      final other = Directory(p.join(h.target.path, 'elsewhere'))
        ..createSync(recursive: true);
      File(p.join(other.path, 'keep.txt')).writeAsStringSync('keep');
      Directory(top()).createSync(recursive: true);
      Link(p.join(top(), 'sub')).createSync(other.path);
      final before = QhtpHarness.snapshot(other);

      final failure = expectRefused(await receive());

      expect(failure.code, FailureCode.unsafeDestination);
      expect(QhtpHarness.snapshot(other), before);
    });

    test('a dangling link at the final name is a taken name, not a hole',
        () async {
      await h.serve({'a.bin': a});
      Directory(top()).createSync(recursive: true);
      final ghost = File(p.join(h.outside.path, 'ghost.bin'));
      Link(h.received('a.bin')).createSync(ghost.path);

      expectReceived(await receive());

      expect(ghost.existsSync(), isFalse,
          reason: 'writing "through" a dangling link would have created this');
      expect(FileSystemEntity.isLinkSync(h.received('a.bin')), isTrue);
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });

    test('a link where the .qs.partial goes is not followed, and its target '
        'is not truncated', () async {
      await h.serve({'a.bin': a});
      Directory(top()).createSync(recursive: true);
      final victim = File(p.join(h.outside.path, 'victim.txt'))
        ..writeAsStringSync('the user\'s own file, do not touch');
      Link('${h.received('a.bin')}.qs.partial').createSync(victim.path);
      final before = QhtpHarness.snapshot(h.outside);

      expectReceived(await receive());

      expect(QhtpHarness.snapshot(h.outside), before);
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
    });

    test('a folder swapped for a link after the check is caught at commit',
        () async {
      await h.serve({'sub/z.bin': z});
      final before = QhtpHarness.snapshot(h.outside);

      final failure = expectRefused(await receive(onRequest: (r) {
        if (!r.isFile) return;
        // The partial is open inside the real `sub`. Swap it, then let the
        // bytes arrive.
        final sub = p.join(top(), 'sub');
        Directory(sub).renameSync(p.join(top(), 'sub_moved'));
        Link(sub).createSync(h.outside.path);
      }));

      expect(failure.code, FailureCode.unsafeDestination);
      expect(QhtpHarness.snapshot(h.outside), before,
          reason: 'the rename must not have gone through the new link');
      expect(File(h.received('sub/z.bin')).existsSync(), isFalse);
    });
  });

  test('a swapped parent cannot delete an outside partial during verification',
      () async {
    await h.serve({'sub/z.bin': z});
    final victim = File(p.join(h.outside.path, 'z.bin.qs.partial'))
      ..writeAsStringSync('precious bytes of a different size');
    final before = QhtpHarness.snapshot(h.outside);
    var swapped = false;

    final failure = expectRefused(await receive(onRequest: (r) {
      if (!r.isFile || swapped) return;
      final sub = p.join(top(), 'sub');
      expect(File(p.join(sub, 'z.bin.qs.partial')).existsSync(), isTrue,
          reason: 'the receiver must have opened its own partial first');
      Directory(sub).renameSync(p.join(top(), 'sub_moved'));
      Link(sub).createSync(h.outside.path);
      swapped = true;
    }));

    expect(swapped, isTrue);
    expect(failure.code, FailureCode.unsafeDestination);
    expect(QhtpHarness.snapshot(h.outside), before,
        reason: 'verification must not delete the outside partial on a '
            'size mismatch');
    expect(victim.readAsStringSync(), 'precious bytes of a different size');
    expect(File(h.received('sub/z.bin')).existsSync(), isFalse);
  });

  group('an existing file is never replaced', () {
    test('one that appears under the chosen name during the download',
        () async {
      await h.serve({'a.bin': a});
      const mine = 'made by the user while the transfer ran';

      expectReceived(await receive(onRequest: (r) {
        if (r.isFile) {
          // The name was free when it was chosen. It is not any more.
          File(h.received('a.bin')).writeAsStringSync(mine);
        }
      }));

      expect(File(h.received('a.bin')).readAsStringSync(), mine);
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
      final saved = await h.store.loadState(h.sessionId);
      expect(saved, isNull, reason: 'a finished session leaves no record');
    });

    test('one that is already there when the session starts', () async {
      await h.serve({'a.bin': a});
      Directory(top()).createSync(recursive: true);
      File(h.received('a.bin')).writeAsStringSync('already here');

      expectReceived(await receive());

      expect(File(h.received('a.bin')).readAsStringSync(), 'already here');
      expect(File(h.received('a (1).bin')).readAsBytesSync(), a);
    });
  });

  group('names off the wire', () {
    test('a climb out of the destination stays inside', () {
      final client = h.client();
      final resolved = client.materializePath('../../../etc/passwd', h.target.path);
      expect(p.isWithin(h.target.path, resolved), isTrue);
    });

    test('a link in the way is refused when the path is resolved', () {
      Link(p.join(h.target.path, 'Trip')).createSync(h.outside.path);
      final client = h.client();
      expect(() => client.materializePath('Trip/a.bin', h.target.path),
          throwsA(anything));
    });
  });
}

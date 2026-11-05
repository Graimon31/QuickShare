// The WebRTC receiver's disk behaviour, driven frame by frame against a real
// temp directory: FS-01 (no write ever follows a link or replaces a file) and
// OPS-01 (a transfer that cannot fit says so first; a disk that fills mid-way
// is reported as that, and cleaned up after).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/storage/disk_space.dart';
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';

import '../../support/links.dart';

class _Fixed extends DiskSpaceProbe {
  _Fixed(this.answer);
  final DiskSpace answer;
  final asked = <String>[];
  @override
  Future<DiskSpace> available(String path) async {
    asked.add(path);
    return answer;
  }
}

/// A file whose disk fills after [room] bytes.
class _FullDisk extends DurableFile {
  _FullDisk(super.finalPath, {super.staged, super.base, required this.room});
  int room;

  @override
  Future<void> add(List<int> bytes) async {
    if (bytes.length > room) {
      throw const FileSystemException(
          'writeFrom failed', '', OSError('No space left on device', 28));
    }
    room -= bytes.length;
    return super.add(bytes);
  }
}

/// A file that does something to the filesystem right after it commits.
class _AfterCommit extends DurableFile {
  _AfterCommit(super.finalPath,
      {super.staged, super.base, required this.then});
  final void Function() then;

  @override
  Future<String> commit() async {
    final path = await super.commit();
    then();
    return path;
  }
}

void main() {
  late Directory root;
  late Directory dest;
  late Directory outside;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_webrtc_safety_');
    dest = Directory(p.join(root.path, 'dest'))..createSync();
    outside = Directory(p.join(root.path, 'outside'))..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  RTCDataChannelMessage text(String s) => RTCDataChannelMessage(s);
  RTCDataChannelMessage binary(List<int> bytes) =>
      RTCDataChannelMessage.fromBinary(Uint8List.fromList(bytes));

  TransferItem item(String path, int size) => TransferItem(
        name: p.basename(path),
        size: size,
        mimeType: 'application/octet-stream',
        path: path,
        compressed: false,
      );

  Map<String, String> snapshot(Directory d) => {
        for (final e in d.listSync(recursive: true, followLinks: false))
          p.relative(e.path, from: d.path): e is File
              ? e.readAsStringSync()
              : e is Link
                  ? 'link:${e.targetSync()}'
                  : 'dir',
      };

  /// A failure is reported first and cleaned up straight after, on the same
  /// turn of the event loop; give the cleanup the moment it needs.
  Future<void> cleanedUp(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> sendFile(WebRtcReceiverTransport t, int index, List<int> bytes) async {
    await t.deliverForTest(text(TransferProtocol.buildFileStart(index)),
        baseDir: dest.path);
    await t.deliverForTest(binary(bytes), baseDir: dest.path);
    await t.deliverForTest(text(TransferProtocol.buildFileEnd(index)),
        baseDir: dest.path);
  }

  Future<void> announce(WebRtcReceiverTransport t, List<TransferItem> items) =>
      t.deliverForTest(text(TransferProtocol.buildManifest(items)),
          baseDir: dest.path);

  group('a single file', () {
    test('a file already under that name is kept, and the new one is numbered',
        () async {
      File(p.join(dest.path, 'a.bin')).writeAsStringSync('mine');
      final t = WebRtcReceiverTransport();
      await announce(t, [item('a.bin', 3)]);
      await sendFile(t, 0, [1, 2, 3]);

      expect(File(p.join(dest.path, 'a.bin')).readAsStringSync(), 'mine');
      expect(File(p.join(dest.path, 'a (1).bin')).readAsBytesSync(), [1, 2, 3]);
      expect(await t.completionForTest, p.join(dest.path, 'a (1).bin'));
    });

    test('a file that appears under the chosen name mid-transfer is never '
        'replaced', () async {
      final t = WebRtcReceiverTransport();
      await announce(t, [item('a.bin', 3)]);
      await t.deliverForTest(text(TransferProtocol.buildFileStart(0)),
          baseDir: dest.path);
      await t.deliverForTest(binary([1, 2, 3]), baseDir: dest.path);

      File(p.join(dest.path, 'a.bin')).writeAsStringSync('made meanwhile');

      await t.deliverForTest(text(TransferProtocol.buildFileEnd(0)),
          baseDir: dest.path);

      expect(File(p.join(dest.path, 'a.bin')).readAsStringSync(),
          'made meanwhile');
      expect(File(p.join(dest.path, 'a (1).bin')).readAsBytesSync(), [1, 2, 3]);
      expect(t.receivedPaths, [p.join(dest.path, 'a (1).bin')]);
    });

    test('a dangling link at the name is occupied, not written through',
        () async {
      final ghost = File(p.join(outside.path, 'ghost'));
      Link(p.join(dest.path, 'a.bin')).createSync(ghost.path);
      final t = WebRtcReceiverTransport();
      await announce(t, [item('a.bin', 3)]);
      await sendFile(t, 0, [1, 2, 3]);

      expect(ghost.existsSync(), isFalse);
      expect(File(p.join(dest.path, 'a (1).bin')).readAsBytesSync(), [1, 2, 3]);
    });

    test('a link in the .qs.partial slot is not followed or truncated',
        () async {
      final victim = File(p.join(outside.path, 'victim'))
        ..writeAsStringSync('precious');
      Link(p.join(dest.path, 'a.bin.qs.partial')).createSync(victim.path);
      final t = WebRtcReceiverTransport();
      await announce(t, [item('a.bin', 3)]);
      await sendFile(t, 0, [1, 2, 3]);

      expect(victim.readAsStringSync(), 'precious');
      expect(File(p.join(dest.path, 'a.bin')).readAsBytesSync(), [1, 2, 3]);
    });

    test('resolveTargetPath refuses a name that goes through a link', () {
      Link(p.join(dest.path, 'Trip')).createSync(outside.path);
      expect(
          () => WebRtcReceiverTransport()
              .resolveTargetPath('Trip/a.bin', dest.path),
          throwsA(anything));
    });
  });

  group('a folder', () {
    final items = [item('Trip/a.bin', 3), item('Trip/sub/b.bin', 2)];

    test('is staged whole and lands in one piece', () async {
      final t = WebRtcReceiverTransport();
      await announce(t, items);
      await sendFile(t, 0, [1, 2, 3]);
      await sendFile(t, 1, [4, 5]);

      expect(File(p.join(dest.path, 'Trip', 'a.bin')).readAsBytesSync(), [1, 2, 3]);
      expect(File(p.join(dest.path, 'Trip', 'sub', 'b.bin')).readAsBytesSync(), [4, 5]);
      expect(await t.completionForTest, p.join(dest.path, 'Trip'));
    });

    test('a folder that appears under the final name mid-transfer is not '
        'replaced — not even an empty one', () async {
      final t = WebRtcReceiverTransport();
      await announce(t, items);
      await sendFile(t, 0, [1, 2, 3]);

      final mine = Directory(p.join(dest.path, 'Trip'))..createSync();

      await sendFile(t, 1, [4, 5]);

      expect(mine.listSync(), isEmpty);
      final landed = await t.completionForTest;
      expect(landed, p.join(dest.path, 'Trip (1)'));
      expect(File(p.join(landed, 'a.bin')).readAsBytesSync(), [1, 2, 3]);
      expect(t.receivedPaths, [landed]);
    });

    test('an existing link named like the folder is refused, nothing is '
        'written through it', () async {
      Link(p.join(dest.path, 'Trip')).createSync(outside.path);
      final before = snapshot(outside);
      final t = WebRtcReceiverTransport();
      final done = expectLater(
          t.completionForTest,
          throwsA(isA<FileException>()
              .having((e) => e.code, 'code', FailureCode.unsafeDestination)));
      await announce(t, items);
      await sendFile(t, 0, [1, 2, 3]);
      await done;

      expect(snapshot(outside), before);
    });

    test('an existing folder is merged into, file by file, never over a file',
        () async {
      final trip = Directory(p.join(dest.path, 'Trip'))..createSync();
      File(p.join(trip.path, 'a.bin')).writeAsStringSync('mine');
      final t = WebRtcReceiverTransport();
      await announce(t, items);
      await sendFile(t, 0, [1, 2, 3]);
      await sendFile(t, 1, [4, 5]);

      expect(File(p.join(trip.path, 'a.bin')).readAsStringSync(), 'mine');
      expect(File(p.join(trip.path, 'a (1).bin')).readAsBytesSync(), [1, 2, 3]);
      expect(File(p.join(trip.path, 'sub', 'b.bin')).readAsBytesSync(), [4, 5]);
    });

    test('a stale staging folder that is a link: only the link is removed',
        () async {
      final precious = File(p.join(outside.path, 'precious.txt'))
        ..writeAsStringSync('do not delete');
      Link(p.join(dest.path, 'Trip.qs.partial')).createSync(outside.path);
      final t = WebRtcReceiverTransport();
      await announce(t, items);
      await sendFile(t, 0, [1, 2, 3]);
      await sendFile(t, 1, [4, 5]);

      expect(precious.readAsStringSync(), 'do not delete');
      expect(File(p.join(dest.path, 'Trip', 'a.bin')).readAsBytesSync(), [1, 2, 3]);
    });

    test('a staging folder swapped for a link before the commit is caught',
        () async {
      final before = snapshot(outside);
      final t = WebRtcReceiverTransport(
        debugFileFactory: (path, {required staged, required base}) =>
            _AfterCommit(path, staged: staged, base: base, then: () {
          if (!path.endsWith('b.bin')) return;
          final stagedDir = p.join(dest.path, 'Trip.qs.partial');
          Directory(stagedDir).renameSync(p.join(dest.path, 'moved'));
          Link(stagedDir).createSync(outside.path);
        }),
      );
      final done = expectLater(
          t.completionForTest,
          throwsA(isA<FileException>()
              .having((e) => e.code, 'code', FailureCode.unsafeDestination)));
      await announce(t, items);
      await sendFile(t, 0, [1, 2, 3]);
      await sendFile(t, 1, [4, 5]);
      await done;

      expect(snapshot(outside), before);
      expect(Directory(p.join(dest.path, 'Trip')).existsSync(), isFalse,
          reason: 'a folder that was not committed is not reported as received');
    });
  });

  group('room on the disk', () {
    test('a session that cannot fit is refused before a file is opened',
        () async {
      final probe = _Fixed(const DiskSpace.known(1000));
      final t = WebRtcReceiverTransport(diskSpace: probe);
      final done = expectLater(
          t.completionForTest,
          throwsA(isA<FileException>().having(
              (e) => FailureCode.parseNotEnoughSpace(e.code),
              'sizes',
              (needed: 500 + 64 * 1024 * 1024, available: 1000))));
      await announce(t, [item('a.bin', 500)]);
      await done;

      expect(probe.asked, [dest.path]);
      expect(dest.listSync(recursive: true), isEmpty);
    });

    test('an unknown answer lets the transfer run', () async {
      final t = WebRtcReceiverTransport(
          diskSpace: _Fixed(const DiskSpace.unknown('no channel')));
      await announce(t, [item('a.bin', 3)]);
      await sendFile(t, 0, [1, 2, 3]);
      expect(File(p.join(dest.path, 'a.bin')).readAsBytesSync(), [1, 2, 3]);
    });

    test('a disk that fills mid-file is reported as that, and cleaned up',
        () async {
      final t = WebRtcReceiverTransport(
        debugFileFactory: (path, {required staged, required base}) =>
            _FullDisk(path, staged: staged, base: base, room: 2),
      );
      final done = expectLater(
          t.completionForTest,
          throwsA(isA<FileException>()
              .having((e) => e.code, 'code', FailureCode.diskFull)));
      await announce(t, [item('a.bin', 3)]);
      await t.deliverForTest(text(TransferProtocol.buildFileStart(0)),
          baseDir: dest.path);
      await t.deliverForTest(binary([1, 2, 3]), baseDir: dest.path);
      await done;
      await cleanedUp(() => dest.listSync(recursive: true).isEmpty);

      expect(dest.listSync(recursive: true), isEmpty,
          reason: 'there is no resume here, so no partial is worth keeping');
    });

    test('a folder session that fills the disk leaves no staging folder',
        () async {
      final t = WebRtcReceiverTransport(
        debugFileFactory: (path, {required staged, required base}) =>
            _FullDisk(path, staged: staged, base: base, room: 1),
      );
      final done = expectLater(t.completionForTest, throwsA(isA<FileException>()));
      await announce(t, [item('Trip/a.bin', 3), item('Trip/b.bin', 2)]);
      await t.deliverForTest(text(TransferProtocol.buildFileStart(0)),
          baseDir: dest.path);
      await t.deliverForTest(binary([1, 2, 3]), baseDir: dest.path);
      await done;
      await cleanedUp(() => dest.listSync(recursive: true).isEmpty);

      expect(Directory(p.join(dest.path, 'Trip.qs.partial')).existsSync(), isFalse);
      expect(Directory(p.join(dest.path, 'Trip')).existsSync(), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Cleaning up after a failure goes through the same checks as writing.
  //
  // A transfer that fails throws its half-written files away. The folders above
  // them are the user's, and somebody who can write there can swap one for a
  // link while the transfer runs; the throwing-away must not follow it.
  group('a failure cleans up without going through a link', () {
    // Windows refuses to move a folder that holds an open file, so the swap
    // cannot be made to a partial that is open there. `windows_native_test.dart`
    // covers the junction on the platform that has them.
    final canSwap = !Platform.isWindows;
    const why = 'Windows cannot move a folder that holds an open file, so a '
        'partial that is being written cannot be swapped out from under it';

    /// Something the sender can do to fail the session at a moment of the test's
    /// choosing: send more bytes than the item announced.
    Future<void> overrun(WebRtcReceiverTransport t) =>
        t.deliverForTest(binary(List.filled(64, 9)), baseDir: dest.path);

    test('a single file whose folder was swapped: the stranger\'s file '
        'survives, the error is the transfer\'s own', () async {
      final t = WebRtcReceiverTransport();
      final settled = expectLater(
          t.completionForTest,
          throwsA(isA<Exception>().having(
              (e) => e.toString(), 'message', contains('sent more than'))));

      await announce(t, [item('a/x.bin', 3), item('b/y.bin', 2)]);
      await t.deliverForTest(text(TransferProtocol.buildFileStart(0)),
          baseDir: dest.path);
      await t.deliverForTest(binary([1]), baseDir: dest.path);

      Directory(p.join(dest.path, 'a')).renameSync(p.join(dest.path, 'moved'));
      if (!linkOrSkip(p.join(dest.path, 'a'), outside.path)) return;
      File(p.join(outside.path, 'x.bin$kPartialSuffix'))
          .writeAsStringSync('belongs to somebody else');
      final before = snapshot(outside);

      await overrun(t);
      await settled;
      await t.discardInFlightForTesting();

      expect(snapshot(outside), before,
          reason: 'the cleanup went through the link and removed a file '
              'outside the destination');
      expect(
          AppLogger.getInMemoryLogs().where((l) =>
              l.contains('[DISK]') && l.contains('symbolic link')),
          isNotEmpty,
          reason: 'a file left in place on purpose is written to the log');
    }, skip: canSwap ? false : why);

    test('a folder whose inner folder was swapped: nothing outside is touched, '
        'and the staging folder is not followed into the link', () async {
      final t = WebRtcReceiverTransport();
      final settled = expectLater(
          t.completionForTest,
          throwsA(isA<Exception>().having(
              (e) => e.toString(), 'message', contains('sent more than'))));

      await announce(t, [item('Trip/a.bin', 3), item('Trip/sub/b.bin', 2)]);
      await sendFile(t, 0, [1, 2, 3]);
      await t.deliverForTest(text(TransferProtocol.buildFileStart(1)),
          baseDir: dest.path);
      await t.deliverForTest(binary([4]), baseDir: dest.path);

      final staged = p.join(dest.path, 'Trip.qs.partial');
      Directory(p.join(staged, 'sub')).renameSync(p.join(staged, 'moved'));
      if (!linkOrSkip(p.join(staged, 'sub'), outside.path)) return;
      File(p.join(outside.path, 'b.bin')).writeAsStringSync('not ours');
      File(p.join(outside.path, 'keep.txt')).writeAsStringSync('keep');
      final before = snapshot(outside);

      await overrun(t);
      await settled;
      await t.discardInFlightForTesting();

      expect(snapshot(outside), before);
    }, skip: canSwap ? false : why);

    test('an ordinary failure still clears its partial', () async {
      // The other half of the rule: refusing to delete through a link must not
      // turn into refusing to delete.
      final t = WebRtcReceiverTransport();
      final settled = expectLater(t.completionForTest, throwsA(isA<Exception>()));

      await announce(t, [item('a/x.bin', 3), item('b/y.bin', 2)]);
      await t.deliverForTest(text(TransferProtocol.buildFileStart(0)),
          baseDir: dest.path);
      await t.deliverForTest(binary([1]), baseDir: dest.path);
      expect(File(p.join(dest.path, 'a', 'x.bin$kPartialSuffix')).existsSync(),
          isTrue);

      await overrun(t);
      await settled;
      await cleanedUp(() => !File(
              p.join(dest.path, 'a', 'x.bin$kPartialSuffix')).existsSync());

      expect(File(p.join(dest.path, 'a', 'x.bin$kPartialSuffix')).existsSync(),
          isFalse);
    });
  });
}

// The WebRTC receiver's own bookkeeping, driven frame by frame against a real
// temp directory.
//
// Three promises that the byte count alone cannot keep:
//
//  * a folder that arrived in full is never thrown away because its last
//    rename failed (a Windows sharing violation from antivirus is transient,
//    and a permanent failure must leave the folder for the user, not delete
//    it);
//  * every announced item is sealed, once, at exactly its announced size —
//    a running total that adds up is not a transfer that happened;
//  * two items that land on the same name never overwrite one another, on a
//    case-insensitive volume or because their paths normalise alike.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';

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
    root = Directory.systemTemp.createTempSync('dd_webrtc_integrity_');
    dest = Directory(p.join(root.path, 'dest'))..createSync();
    outside = Directory(p.join(root.path, 'outside'))..createSync();
  });
  tearDown(() {
    // A test that made the destination read-only must not stop the cleanup.
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['-R', 'u+rwX', root.path]);
    }
    root.deleteSync(recursive: true);
  });

  RTCDataChannelMessage text(String s) => RTCDataChannelMessage(s);
  RTCDataChannelMessage binary(List<int> bytes) =>
      RTCDataChannelMessage.fromBinary(Uint8List.fromList(bytes));

  TransferItem item(String path, int size) => TransferItem(
        name: p.posix.basename(path),
        size: size,
        mimeType: 'application/octet-stream',
        path: path,
        compressed: false,
      );

  Future<void> announce(WebRtcReceiverTransport t, List<TransferItem> items) =>
      t.deliverForTest(text(TransferProtocol.buildManifest(items)),
          baseDir: dest.path);

  Future<void> frame(WebRtcReceiverTransport t, String message) =>
      t.deliverForTest(text(message), baseDir: dest.path);

  Future<void> bytes(WebRtcReceiverTransport t, List<int> data) =>
      t.deliverForTest(binary(data), baseDir: dest.path);

  Future<void> sendFile(
      WebRtcReceiverTransport t, int index, List<int> data) async {
    await frame(t, TransferProtocol.buildFileStart(index));
    await bytes(t, data);
    await frame(t, TransferProtocol.buildFileEnd(index));
  }

  /// The session must end in failure, with [message] in the reason. Bounded,
  /// so a session that neither succeeds nor fails is a failing test and not a
  /// hung one.
  Future<void> expectFails(WebRtcReceiverTransport t, Pattern message) =>
      expectLater(
          t.completionForTest.timeout(const Duration(seconds: 8)),
          throwsA(isA<Exception>().having((e) => '$e', 'reason', contains(message))));

  void chmod(String mode, String path) {
    final result = Process.runSync('chmod', [mode, path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  final posix = !Platform.isWindows;
  final isRoot = posix && Process.runSync('id', ['-u']).stdout.toString().trim() == '0';
  final canBlockRename = posix && !isRoot;

  final folder = [item('Trip/a.bin', 3), item('Trip/sub/b.bin', 2)];

  // ---------------------------------------------------------------------------
  group('a folder that arrived in full', () {
    test('lands after a rename that fails at first and then works', () async {
      final t = WebRtcReceiverTransport(
        debugFileFactory: (path, {required staged, required base}) =>
            _AfterCommit(path, staged: staged, base: base, then: () {
          if (!path.endsWith('b.bin')) return;
          // The rename onto the real name is refused for a moment — the shape
          // of an antivirus scan holding the folder on Windows.
          chmod('555', dest.path);
          Timer(const Duration(milliseconds: 350),
              () => chmod('755', dest.path));
        }),
      );
      await announce(t, folder);
      await sendFile(t, 0, [1, 2, 3]);
      await sendFile(t, 1, [4, 5]);

      expect(await t.completionForTest.timeout(const Duration(seconds: 10)),
          p.join(dest.path, 'Trip'));
      expect(File(p.join(dest.path, 'Trip', 'a.bin')).readAsBytesSync(),
          [1, 2, 3]);
      expect(File(p.join(dest.path, 'Trip', 'sub', 'b.bin')).readAsBytesSync(),
          [4, 5]);
      expect(Directory(p.join(dest.path, 'Trip.qs.partial')).existsSync(),
          isFalse);
    }, skip: canBlockRename ? false : 'needs a non-root POSIX user to make a '
        'rename fail');

    test('is kept, not deleted, when the rename never works — and the failure '
        'says where it is', () async {
      final t = WebRtcReceiverTransport(
        debugFileFactory: (path, {required staged, required base}) =>
            _AfterCommit(path, staged: staged, base: base, then: () {
          if (path.endsWith('b.bin')) chmod('555', dest.path);
        }),
      );
      final staged = p.join(dest.path, 'Trip.qs.partial');
      final failed = expectFails(t, staged);
      await announce(t, folder);
      await sendFile(t, 0, [1, 2, 3]);
      await sendFile(t, 1, [4, 5]);
      await failed;

      // The failure cleans up on its own turn of the event loop; give it every
      // chance to do the thing this test says it must not do.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await t.discardInFlightForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(File(p.join(staged, 'a.bin')).readAsBytesSync(), [1, 2, 3],
          reason: 'a complete folder was deleted because its rename failed');
      expect(File(p.join(staged, 'sub', 'b.bin')).readAsBytesSync(), [4, 5]);
      expect(Directory(p.join(dest.path, 'Trip')).existsSync(), isFalse,
          reason: 'a folder that was not committed is not reported as received');
      expect(File(p.join(staged, '.qs.kept')).existsSync(), isTrue,
          reason: 'the kept folder carries the mark the startup sweep honours');
    }, skip: canBlockRename ? false : 'needs a non-root POSIX user to make a '
        'rename fail');

    test('a staging folder swapped for a link is not deleted through',
        () async {
      final precious = File(p.join(outside.path, 'precious.txt'))
        ..writeAsStringSync('do not delete');
      final t = WebRtcReceiverTransport();
      await announce(t, folder);
      await sendFile(t, 0, [1, 2, 3]);

      final staged = p.join(dest.path, 'Trip.qs.partial');
      Directory(staged).renameSync(p.join(dest.path, 'moved'));
      Link(staged).createSync(outside.path);

      // Any failure runs the same cleanup.
      final failed = expectFails(t, 'file-start');
      await frame(t, TransferProtocol.buildFileStart(7));
      await failed;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(precious.readAsStringSync(), 'do not delete');
      expect(outside.listSync().length, 1);
    });
  });

  // ---------------------------------------------------------------------------
  group('every item is sealed, once, at its exact size', () {
    final two = [item('a.bin', 10), item('b.bin', 10)];

    test('a file-start while another item is open fails the session',
        () async {
      final t = WebRtcReceiverTransport();
      final failed = expectFails(t, 'still open');
      await announce(t, two);
      await frame(t, TransferProtocol.buildFileStart(0));
      await bytes(t, List.filled(10, 1));
      // No file-end for item 0.
      await frame(t, TransferProtocol.buildFileStart(1));
      await bytes(t, List.filled(10, 2));
      await frame(t, TransferProtocol.buildFileEnd(1));
      await frame(t, TransferProtocol.buildComplete());
      await failed;

      expect(t.receivedPaths, isEmpty,
          reason: 'item 0 was never sealed, so the session did not receive it');
    });

    test('more bytes than the item announced fails at once', () async {
      final t = WebRtcReceiverTransport();
      final failed = expectFails(t, 'more than');
      await announce(t, [item('a.bin', 10)]);
      await frame(t, TransferProtocol.buildFileStart(0));
      await bytes(t, List.filled(11, 1));
      // No file-end: the overshoot itself must be the end of it.
      await failed;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(File(p.join(dest.path, 'a.bin')).existsSync(), isFalse);
      expect(
          dest.listSync(recursive: true).whereType<File>(), isEmpty,
          reason: 'nothing of the oversized item is left behind');
    });

    test('15 bytes of a 10-byte item followed by a full second item does not '
        'succeed', () async {
      final t = WebRtcReceiverTransport();
      final failed = expectFails(t, RegExp('15|more than'));
      await announce(t, two);
      await sendFile(t, 0, List.filled(15, 1));
      await sendFile(t, 1, List.filled(10, 2));
      await frame(t, TransferProtocol.buildComplete());
      await failed;
    });

    test('an item that was never sent cannot be covered by the others\' bytes',
        () async {
      // Item 0 is empty and is skipped; item 1 brings the whole running total.
      final t = WebRtcReceiverTransport();
      final failed = expectFails(t, 'never arrived');
      await announce(t, [item('a.bin', 0), item('b.bin', 5)]);
      await sendFile(t, 1, [1, 2, 3, 4, 5]);
      await failed;

      expect(File(p.join(dest.path, 'a.bin')).existsSync(), isFalse);
    });

    test('an item announced twice cannot stand in for the one not sent',
        () async {
      final t = WebRtcReceiverTransport();
      final failed = expectFails(t, 'twice');
      await announce(t, two);
      await sendFile(t, 0, List.filled(10, 1));
      await sendFile(t, 0, List.filled(10, 1));
      await frame(t, TransferProtocol.buildComplete());
      await failed;
    });

    test('a well-formed session still succeeds, empty items included',
        () async {
      final t = WebRtcReceiverTransport();
      await announce(t, [item('a.bin', 0), item('b.bin', 5)]);
      await sendFile(t, 0, const []);
      await sendFile(t, 1, [1, 2, 3, 4, 5]);
      await frame(t, TransferProtocol.buildComplete());

      await t.completionForTest.timeout(const Duration(seconds: 5));
      expect(File(p.join(dest.path, 'a.bin')).lengthSync(), 0);
      expect(File(p.join(dest.path, 'b.bin')).readAsBytesSync(),
          [1, 2, 3, 4, 5]);
    });
  });

  // ---------------------------------------------------------------------------
  group('two items for one name in a staged folder', () {
    test('paths that normalise alike land side by side, not over each other',
        () async {
      final t = WebRtcReceiverTransport();
      await announce(t, [
        item('Trip/a.jpg', 3),
        // The same file once the path has been cleaned: `.` is dropped.
        item('Trip/./a.jpg', 3),
      ]);
      await sendFile(t, 0, [1, 2, 3]);
      await sendFile(t, 1, [4, 5, 6]);

      expect(await t.completionForTest.timeout(const Duration(seconds: 5)),
          p.join(dest.path, 'Trip'));
      final names = Directory(p.join(dest.path, 'Trip'))
          .listSync()
          .map((e) => p.basename(e.path))
          .toList()
        ..sort();
      expect(names, ['a (1).jpg', 'a.jpg'],
          reason: 'one of the two files was overwritten by the other');
      expect(File(p.join(dest.path, 'Trip', 'a.jpg')).readAsBytesSync(),
          [1, 2, 3]);
      expect(File(p.join(dest.path, 'Trip', 'a (1).jpg')).readAsBytesSync(),
          [4, 5, 6]);
    });

    // Real only where the volume folds case: which is what this machine's
    // temp directory is, or is not.
    final caseInsensitive = () {
      final probe = Directory.systemTemp.createTempSync('dd_case_probe_');
      try {
        File(p.join(probe.path, 'probe.txt')).writeAsStringSync('x');
        return File(p.join(probe.path, 'PROBE.TXT')).existsSync();
      } finally {
        probe.deleteSync(recursive: true);
      }
    }();

    test('Photo.jpg and photo.jpg both arrive on a case-insensitive volume',
        () async {
      final t = WebRtcReceiverTransport();
      await announce(
          t, [item('Trip/Photo.jpg', 3), item('Trip/photo.jpg', 3)]);
      await sendFile(t, 0, [1, 2, 3]);
      await sendFile(t, 1, [4, 5, 6]);

      await t.completionForTest.timeout(const Duration(seconds: 5));
      final files = Directory(p.join(dest.path, 'Trip'))
          .listSync()
          .whereType<File>()
          .toList();
      expect(files, hasLength(2),
          reason: 'two items were announced; one file on disk means one was '
              'written over the other and both were counted as received');
      expect(files.map((f) => f.readAsBytesSync().toString()).toSet(),
          {'[1, 2, 3]', '[4, 5, 6]'});
    }, skip: caseInsensitive
        ? false
        : 'this volume is case-sensitive: the two names are different files '
            'and the normalisation test above is the real collision');
  });
}

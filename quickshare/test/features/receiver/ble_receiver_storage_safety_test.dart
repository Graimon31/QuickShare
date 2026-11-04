// The Bluetooth receiver's disk behaviour: FS-01 and OPS-01 through the real
// metadata/data handlers, in a temp directory.
//
// BLE's notify handlers are synchronous and cannot be awaited, so this is the
// path where a check that wants to `await` has the least room — which is why
// it is worth proving separately that the same rules hold here.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/storage/disk_space.dart';
import 'package:quickshare/features/receiver/data/transports/universal_ble_receiver_transport.dart';

class _Fixed extends DiskSpaceProbe {
  _Fixed(this.answer);
  final DiskSpace answer;
  @override
  Future<DiskSpace> available(String path) async => answer;
}

/// A handle on a full disk.
class _FullRaf implements RandomAccessFile {
  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    throw const FileSystemException(
        'writeFrom failed', '', OSError('No space left on device', 28));
  }

  @override
  void closeSync() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} on a full disk');
}

void main() {
  late Directory root;
  late Directory dest;
  late Directory outside;
  late UniversalBleReceiverTransport transport;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_ble_safety_');
    dest = Directory(p.join(root.path, 'dest'))..createSync();
    outside = Directory(p.join(root.path, 'outside'))..createSync();
    transport = UniversalBleReceiverTransport();
    transport.setBaseDirForTesting(dest.path);
    transport.setTargetDeviceIdForTesting('device_1');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Uint8List meta(String name, int size,
          {String? path, int index = 0, int count = 1, int? sessionBytes}) =>
      Uint8List.fromList(utf8.encode(jsonEncode({
        'name': name,
        'size': size,
        'index': index,
        'count': count,
        'sessionBytes': sessionBytes ?? size,
        if (path != null) 'path': path,
      })));

  Map<String, String> snapshot(Directory d) => {
        for (final e in d.listSync(recursive: true, followLinks: false))
          p.relative(e.path, from: d.path): e is File
              ? e.readAsStringSync()
              : e is Link
                  ? 'link:${e.targetSync()}'
                  : 'dir',
      };

  Matcher failsWith(String code) => throwsA(isA<FileException>()
      .having((e) => e.code, 'code', code));

  group('FS-01', () {
    test('a nested folder is rebuilt', () async {
      transport.handleMetadataForTesting(meta('f.bin', 3, path: 'Trip/Day 1/f.bin'));
      transport.handleDataForTesting(Uint8List.fromList([1, 2, 3]));
      expect(await transport.completionForTesting.future,
          p.join(dest.path, 'Trip', 'Day 1', 'f.bin'));
      expect(File(p.join(dest.path, 'Trip', 'Day 1', 'f.bin')).readAsBytesSync(),
          [1, 2, 3]);
    });

    test('a climb out of the destination stays inside it', () async {
      transport.handleMetadataForTesting(
          meta('passwd', 1, path: '../../../etc/passwd'));
      transport.handleDataForTesting(Uint8List.fromList([9]));
      final landed = await transport.completionForTesting.future;
      expect(p.isWithin(dest.path, landed), isTrue);
      expect(outside.listSync(), isEmpty);
    });

    test('a link in the folder chain fails the session; nothing leaves the '
        'destination', () async {
      Link(p.join(dest.path, 'Trip')).createSync(outside.path);
      final before = snapshot(outside);
      final done = expectLater(
          transport.completionForTesting.future,
          failsWith(FailureCode.unsafeDestination));

      transport.handleMetadataForTesting(meta('f.bin', 3, path: 'Trip/f.bin'));
      transport.handleDataForTesting(Uint8List.fromList([1, 2, 3]));

      await done;
      expect(snapshot(outside), before);
    });

    test('a folder moved away and linked back before the file is sealed '
        'fails the session and names nothing outside', () async {
      // The sharper form of a swap: the folder goes outside, partial and all,
      // and a link stands where it was. Followed, the link leads straight to
      // the partial; only a look at the chain at the last step refuses it.
      transport.handleMetadataForTesting(meta('f.bin', 3, path: 'Trip/f.bin'));
      transport.handleDataForTesting(Uint8List.fromList([1, 2]));
      final moved = p.join(outside.path, 'moved');
      Directory(p.join(dest.path, 'Trip')).renameSync(moved);
      Link(p.join(dest.path, 'Trip')).createSync(moved);
      final done = expectLater(
          transport.completionForTesting.future,
          failsWith(FailureCode.unsafeDestination));

      transport.handleDataForTesting(Uint8List.fromList([3]));

      await done;
      expect(File(p.join(moved, 'f.bin')).existsSync(), isFalse,
          reason: 'the file was given its name outside the destination');
    });

    test('a dangling link at the final name is occupied', () async {
      final ghost = File(p.join(outside.path, 'ghost'));
      Link(p.join(dest.path, 'a.bin')).createSync(ghost.path);

      transport.handleMetadataForTesting(meta('a.bin', 3));
      transport.handleDataForTesting(Uint8List.fromList([1, 2, 3]));
      final landed = await transport.completionForTesting.future;

      expect(ghost.existsSync(), isFalse);
      expect(landed, p.join(dest.path, 'a (1).bin'));
      expect(File(landed).readAsBytesSync(), [1, 2, 3]);
    });

    test('a link in the partial slot is replaced, its target untouched',
        () async {
      final victim = File(p.join(outside.path, 'victim'))
        ..writeAsStringSync('precious');
      Link(p.join(dest.path, 'a.bin.qs.partial')).createSync(victim.path);

      transport.handleMetadataForTesting(meta('a.bin', 3));
      transport.handleDataForTesting(Uint8List.fromList([1, 2, 3]));
      await transport.completionForTesting.future;

      expect(victim.readAsStringSync(), 'precious');
      expect(File(p.join(dest.path, 'a.bin')).readAsBytesSync(), [1, 2, 3]);
    });

    test('a file created under the chosen name mid-transfer is not replaced',
        () async {
      transport.handleMetadataForTesting(meta('a.bin', 4));
      transport.handleDataForTesting(Uint8List.fromList([1, 2]));

      File(p.join(dest.path, 'a.bin')).writeAsStringSync('made meanwhile');

      transport.handleDataForTesting(Uint8List.fromList([3, 4]));
      final landed = await transport.completionForTesting.future;

      expect(File(p.join(dest.path, 'a.bin')).readAsStringSync(),
          'made meanwhile');
      expect(landed, p.join(dest.path, 'a (1).bin'));
      expect(File(landed).readAsBytesSync(), [1, 2, 3, 4]);
    });

    test('a folder swapped for a link mid-transfer is caught when sealing',
        () async {
      final before = snapshot(outside);
      final done = expectLater(
          transport.completionForTesting.future,
          failsWith(FailureCode.unsafeDestination));

      transport.handleMetadataForTesting(meta('f.bin', 4, path: 'Trip/f.bin'));
      transport.handleDataForTesting(Uint8List.fromList([1, 2]));
      Directory(p.join(dest.path, 'Trip')).renameSync(p.join(dest.path, 'moved'));
      Link(p.join(dest.path, 'Trip')).createSync(outside.path);
      transport.handleDataForTesting(Uint8List.fromList([3, 4]));

      await done;
      expect(snapshot(outside), before);
    });

    test('a destination that is not an absolute path is refused', () async {
      transport.setBaseDirForTesting('downloads');
      final done = expectLater(
          transport.completionForTesting.future, throwsA(isA<Exception>()));
      transport.handleMetadataForTesting(meta('a.bin', 1));
      await done;
      expect(Directory('downloads').existsSync(), isFalse);
    });
  });

  group('OPS-01', () {
    test('a session that cannot fit fails with both sizes, and leaves nothing',
        () async {
      transport = UniversalBleReceiverTransport(
          diskSpace: _Fixed(const DiskSpace.known(1000)));
      transport.setBaseDirForTesting(dest.path);
      transport.setTargetDeviceIdForTesting('device_1');
      final done = expectLater(
          transport.completionForTesting.future,
          throwsA(isA<FileException>().having(
              (e) => FailureCode.parseNotEnoughSpace(e.code),
              'sizes',
              (needed: 5000 + 64 * 1024 * 1024, available: 1000))));

      transport.handleMetadataForTesting(meta('a.bin', 5000));
      await done;

      expect(dest.listSync(recursive: true), isEmpty);
    });

    test('an unknown answer lets it run', () async {
      transport = UniversalBleReceiverTransport(
          diskSpace: _Fixed(const DiskSpace.unknown('no channel')));
      transport.setBaseDirForTesting(dest.path);
      transport.setTargetDeviceIdForTesting('device_1');

      transport.handleMetadataForTesting(meta('a.bin', 2));
      transport.handleDataForTesting(Uint8List.fromList([1, 2]));
      expect(await transport.completionForTesting.future,
          p.join(dest.path, 'a.bin'));
    });

    test('a full disk is named, and the partial is removed', () async {
      transport.handleMetadataForTesting(meta('a.bin', 10));
      expect(File(p.join(dest.path, 'a.bin.qs.partial')).existsSync(), isTrue);

      transport.setPathsForTesting(
        raf: _FullRaf(),
        partialPath: p.join(dest.path, 'a.bin.qs.partial'),
        targetPath: p.join(dest.path, 'a.bin'),
        fileTotalBytes: 10,
      );
      final done = expectLater(
          transport.completionForTesting.future, failsWith(FailureCode.diskFull));
      transport.handleDataForTesting(Uint8List.fromList([1, 2, 3]));
      await done;

      expect(dest.listSync(recursive: true), isEmpty);
    });
  });
}

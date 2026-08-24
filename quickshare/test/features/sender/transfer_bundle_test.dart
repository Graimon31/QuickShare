// Bundling several files froze the whole app while it ran.
//
// ZipFileEncoder deflates on whichever isolate calls it, and it was being
// called straight from the bloc — so picking a folder, or several files for
// Bluetooth, stopped every animation and every tap for as long as the deflate
// took. On this hardware that is about 55 MB/s for media that does not
// compress: two seconds for a hundred megabytes, most of a minute for a few
// videos off a phone. Reported, accurately, as "the app hung".
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';

void main() {
  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync('dd_bundle_'));
  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  /// Incompressible, so deflate does the most work for the least benefit —
  /// which is the photo and video case exactly.
  File payload(String name, int megabytes) {
    final block = Uint8List(1024 * 1024);
    for (var i = 0; i < block.length; i++) {
      block[i] = (i * 2654435761) & 0xFF;
    }
    final file = File(p.join(workspace.path, name));
    final sink = file.openSync(mode: FileMode.write);
    for (var i = 0; i < megabytes; i++) {
      sink.writeFromSync(block);
    }
    sink.closeSync();
    return file;
  }

  /// Longest stretch the event loop went unserviced while [work] ran.
  Future<Duration> longestStall(Future<void> Function() work) async {
    var last = DateTime.now();
    var longest = Duration.zero;
    final ticker = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final now = DateTime.now();
      final gap = now.difference(last);
      if (gap > longest) longest = gap;
      last = now;
    });
    await work();
    ticker.cancel();
    return longest;
  }

  test('bundling on its own isolate leaves the caller responsive', () async {
    final file = payload('clip.mp4', 60);
    final zipPath = p.join(workspace.path, 'bundle.zip');

    // The measurement has to be able to see a stall, or "no stall" means
    // nothing. Same work, same payload, on the calling isolate.
    final blockingPath = p.join(workspace.path, 'blocking.zip');
    final blocked =
        await longestStall(() => writeTransferBundle([file.path], blockingPath));

    // Through the production entry point, not a hand-rolled Isolate.run: the
    // wrapper exists because a closure built inside an async body captures the
    // completer driving it and fails to send.
    final free = await longestStall(() async {
      final size = await bundleForTransfer([file.path], zipPath);
      expect(size, equals(File(zipPath).lengthSync()),
          reason: 'the size handed to the receiver has to be the finished one');
    });

    expect(blocked, greaterThan(const Duration(milliseconds: 300)),
        reason: 'doing it inline is what froze the app; if this is small the '
            'payload is too easy and the test proves nothing');
    expect(free, lessThan(const Duration(milliseconds: 300)),
        reason: 'off the calling isolate, the interface keeps running');
    expect(free * 2, lessThan(blocked));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('everything picked ends up in the archive, files and folders alike',
      () async {
    final loose = File(p.join(workspace.path, 'notes.txt'))
      ..writeAsStringSync('hello');
    final folder = Directory(p.join(workspace.path, 'Trip'))..createSync();
    File(p.join(folder.path, 'a.jpg')).writeAsStringSync('aaaa');
    Directory(p.join(folder.path, 'day 2')).createSync();
    File(p.join(folder.path, 'day 2', 'b.jpg')).writeAsStringSync('bbbb');

    final zipPath = p.join(workspace.path, 'mixed.zip');
    final size = await writeTransferBundle([loose.path, folder.path], zipPath);

    // Reported size must match a finished archive. The encoder's writes used
    // to be started and never awaited, so this was measured mid-flush.
    expect(size, equals(File(zipPath).lengthSync()));

    final names = ZipDecoder()
        .decodeBytes(File(zipPath).readAsBytesSync())
        .files
        .map((f) => f.name)
        .toList();
    expect(names, contains('notes.txt'));
    expect(names.any((n) => n.endsWith('a.jpg')), isTrue);
    expect(names.any((n) => n.endsWith('b.jpg')), isTrue,
        reason: 'a nested file has to survive the bundling');
  });
}

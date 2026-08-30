// A folder picked on one device has to be a folder on the other.
//
// It used to become a .zip, because the DataChannel and Bluetooth paths could
// carry one object of a known size and nothing else. The recipient then had
// an archive to unpack instead of the photos they were sent. Now the sender
// walks the tree into a list of files, each carrying the relative path it
// keeps, and the receiver rebuilds the directories as the files land.
//
// This exercises both halves against each other — the sender's walk, the
// manifest that goes on the wire, and the receiver's path resolution — with
// only the radio in between left out.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/utils/mime_compression.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/sender/data/indexer/transfer_selection.dart';

void main() {
  late Directory source;
  late Directory destination;

  setUp(() {
    source = Directory.systemTemp.createTempSync('dd_rt_src_');
    destination = Directory.systemTemp.createTempSync('dd_rt_dst_');
  });

  tearDown(() {
    for (final dir in [source, destination]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  void write(String relative, String contents) {
    final file = File(p.join(source.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  /// Every file under [root], as `relative path -> contents`.
  Map<String, String> treeOf(Directory root) => {
        for (final entity in root.listSync(recursive: true, followLinks: false))
          if (entity is File)
            p.posix.joinAll(p.split(p.relative(entity.path, from: root.path))):
                entity.readAsStringSync(),
      };

  /// The whole trip: walk the selection, put it on the wire, write it out.
  Future<Map<String, String>> transfer(List<String> paths) async {
    final files = await expandSelection(paths);

    final items = [
      for (final f in files)
        TransferItem(
          name: f.name,
          size: f.size,
          mimeType: f.mimeType,
          compressed: shouldCompressForTransfer(f.mimeType, f.name),
          path: f.relPath,
        ),
    ];

    // Through the encoder and back, so nothing here is testing a list of
    // objects that never became bytes.
    final rebuilt = <TransferItem>[];
    for (final frame in TransferProtocol.buildManifestFrames(items)) {
      final json = jsonDecode(frame) as Map<String, dynamic>;
      if (json['type'] == TransferProtocol.manifestBegin) continue;
      rebuilt.addAll(TransferProtocol.parseManifest(json));
    }

    final receiver = WebRtcReceiverTransport();
    for (var index = 0; index < rebuilt.length; index++) {
      final target =
          receiver.resolveTargetPath(rebuilt[index].path, destination.path);
      Directory(p.dirname(target)).createSync(recursive: true);
      File(target).writeAsBytesSync(File(files[index].path).readAsBytesSync());
    }

    return treeOf(destination);
  }

  test('a folder arrives as the same folder', () async {
    write('Trip/IMG_0001.jpg', 'first photo');
    write('Trip/Day 2/IMG_0002.jpg', 'second photo');
    write('Trip/Day 2/notes/packing.txt', 'socks');

    final arrived = await transfer([p.join(source.path, 'Trip')]);

    expect(arrived, {
      'Trip/IMG_0001.jpg': 'first photo',
      'Trip/Day 2/IMG_0002.jpg': 'second photo',
      'Trip/Day 2/notes/packing.txt': 'socks',
    });
  });

  test('nothing lands outside the destination', () async {
    write('Trip/IMG_0001.jpg', 'first photo');

    await transfer([p.join(source.path, 'Trip')]);

    for (final entity in destination.listSync(recursive: true)) {
      expect(p.isWithin(destination.path, entity.path), isTrue);
    }
  });

  test('loose files still land at the top, not in a folder', () async {
    write('one.txt', 'one');
    write('two.txt', 'two');

    final arrived = await transfer(
        [p.join(source.path, 'one.txt'), p.join(source.path, 'two.txt')]);

    expect(arrived, {'one.txt': 'one', 'two.txt': 'two'});
  });

  test('a folder and loose files keep their own places', () async {
    write('Trip/IMG_0001.jpg', 'photo');
    write('receipt.pdf', 'paid');

    final arrived = await transfer(
        [p.join(source.path, 'Trip'), p.join(source.path, 'receipt.pdf')]);

    expect(arrived, {
      'Trip/IMG_0001.jpg': 'photo',
      'receipt.pdf': 'paid',
    });
  });

  test('a deep tree survives the trip whole', () async {
    // Enough files that the manifest cannot go in one frame, so the split
    // path is what rebuilds this one.
    for (var i = 0; i < 900; i++) {
      write('Library/${i % 30}/note_$i.txt', 'body $i');
    }

    final arrived = await transfer([p.join(source.path, 'Library')]);

    expect(arrived, hasLength(900));
    expect(arrived['Library/7/note_37.txt'], equals('body 37'));
  });

  test('the session is described by the folder, not by its contents', () async {
    write('Trip/IMG_0001.jpg', 'photo');
    write('Trip/Day 2/IMG_0002.jpg', 'photo');

    final files = await expandSelection([p.join(source.path, 'Trip')]);

    expect(commonRootFolder(files), equals('Trip'));
  });

  test('a flat selection has no folder to be named after', () async {
    write('one.txt', 'one');
    write('two.txt', 'two');

    final files = await expandSelection(
        [p.join(source.path, 'one.txt'), p.join(source.path, 'two.txt')]);

    expect(commonRootFolder(files), isNull);
  });

  test('two folders at once are not passed off as one', () async {
    write('Trip/a.txt', 'a');
    write('Work/b.txt', 'b');

    final files = await expandSelection(
        [p.join(source.path, 'Trip'), p.join(source.path, 'Work')]);

    expect(commonRootFolder(files), isNull);
  });
}

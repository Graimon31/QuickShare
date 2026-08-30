// A folder used to be turned into a .zip before it could be sent over
// Bluetooth or the internet, because those channels could only carry one
// object of a known size. The recipient got an archive to unpack instead of
// the photos they were sent, and the sender waited through a full deflate
// pass before the first byte could leave.
//
// Both channels carry a manifest of files now, each with the relative path it
// has to keep, so the selection goes as itself. This is the walk that turns
// what the user picked into that list.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/indexer/transfer_selection.dart';

void main() {
  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync('dd_select_'));
  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  File write(String relative, [String contents = 'x']) {
    final file = File(p.join(workspace.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file;
  }

  test('a folder becomes its files, each keeping where it sits', () async {
    write('Trip/IMG_0001.jpg');
    write('Trip/Day 2/IMG_0002.jpg');
    write('Trip/Day 2/notes/list.txt');

    final files = await expandSelection([p.join(workspace.path, 'Trip')]);

    expect(files.map((f) => f.relPath).toList(), [
      'Trip/Day 2/IMG_0002.jpg',
      'Trip/Day 2/notes/list.txt',
      'Trip/IMG_0001.jpg',
    ]);
    // The root folder is part of every path: without it the far side gets the
    // contents scattered over the destination rather than the folder itself.
    expect(files.every((f) => f.relPath.startsWith('Trip/')), isTrue);
  });

  test('the absolute path still points at the file on this disk', () async {
    final photo = write('Trip/Day 2/IMG_0002.jpg', 'bytes');

    final files = await expandSelection([p.join(workspace.path, 'Trip')]);

    final found = files.singleWhere((f) => f.name == 'IMG_0002.jpg');
    expect(found.path, equals(photo.path));
    expect(found.size, equals(5));
  });

  test('files picked directly carry no path to rebuild', () async {
    // Nothing to rebuild means nothing on the wire: an ordinary multi-file
    // send costs exactly what it did before folders were possible.
    final one = write('one.txt');
    final two = write('two.txt');

    final files = await expandSelection([one.path, two.path]);

    expect(files.map((f) => f.relativePath), everyElement(isNull));
    expect(files.map((f) => f.relPath).toSet(), {'one.txt', 'two.txt'});
  });

  test('a folder and loose files can be sent together', () async {
    write('Trip/IMG_0001.jpg');
    final loose = write('receipt.pdf');

    final files = await expandSelection(
        [p.join(workspace.path, 'Trip'), loose.path]);

    expect(files.map((f) => f.relPath).toSet(),
        {'Trip/IMG_0001.jpg', 'receipt.pdf'});
  });

  test('junk inside a folder is left behind', () async {
    write('Trip/IMG_0001.jpg');
    write('Trip/.DS_Store');
    write('Trip/.hidden/secret.txt');

    final files = await expandSelection([p.join(workspace.path, 'Trip')]);

    expect(files.single.relPath, equals('Trip/IMG_0001.jpg'));
  });

  test('a hidden file picked on purpose is still sent', () async {
    // The junk filter is for things swept up by a folder, not for a file
    // somebody named. Dropping it silently left the caller with an empty
    // selection and nothing to explain it.
    final dotfile = write('.env', 'SECRET=1');

    final files = await expandSelection([dotfile.path]);

    expect(files.single.relPath, equals('.env'));
  });

  test('a mime type is worked out per file, not per session', () async {
    write('Trip/IMG_0001.jpg');
    write('Trip/notes.txt');

    final files = await expandSelection([p.join(workspace.path, 'Trip')]);

    expect(files.singleWhere((f) => f.name == 'IMG_0001.jpg').mimeType,
        equals('image/jpeg'));
    expect(files.singleWhere((f) => f.name == 'notes.txt').mimeType,
        equals('text/plain'));
  });

  test('a folder with nothing sendable in it says so', () async {
    Directory(p.join(workspace.path, 'Empty')).createSync();

    expect(() => expandSelection([p.join(workspace.path, 'Empty')]),
        throwsA(isA<FileIndexerException>()));
  });
}

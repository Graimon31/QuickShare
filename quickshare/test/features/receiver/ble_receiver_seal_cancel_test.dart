import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/features/receiver/data/transports/universal_ble_receiver_transport.dart';

void main() {
  late Directory tempDir;
  late UniversalBleReceiverTransport transport;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ble_seal_cancel_test_');
    transport = UniversalBleReceiverTransport();
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('C3: _sealCurrentFile finishes file and cancel() does NOT delete the finished file', () async {
    final finalFile = File(p.join(tempDir.path, 'photo.jpg'));
    final partialFile = File(p.join(tempDir.path, 'photo.jpg.qs.partial'));

    // Prepare a partial file and open handle
    final raf = partialFile.openSync(mode: FileMode.write);
    raf.writeFromSync(Uint8List.fromList([1, 2, 3, 4]));

    transport.setPathsForTesting(
      raf: raf,
      partialPath: partialFile.path,
      targetPath: finalFile.path,
      fileReceivedBytes: 4,
      fileTotalBytes: 4,
    );

    // Seal the file
    await transport.sealCurrentFileForTesting();

    // Verify file was sealed into finalPath
    expect(finalFile.existsSync(), isTrue);
    expect(partialFile.existsSync(), isFalse);
    expect(finalFile.lengthSync(), equals(4));
    expect(transport.receivedPaths, contains(finalFile.path));

    // Now simulate dispose -> cancel() on receive page
    await transport.cancel();

    // CRITICAL: Final file MUST still be on disk!
    expect(finalFile.existsSync(), isTrue,
        reason: 'cancel() must not delete a sealed completed file!');
  });

  test('Important 15: _sealCurrentFile throws and removes partial on short file', () async {
    final finalFile = File(p.join(tempDir.path, 'short.bin'));
    final partialFile = File(p.join(tempDir.path, 'short.bin.qs.partial'));

    final raf = partialFile.openSync(mode: FileMode.write);
    raf.writeFromSync(Uint8List.fromList([1, 2])); // only 2 bytes

    transport.setPathsForTesting(
      raf: raf,
      partialPath: partialFile.path,
      targetPath: finalFile.path,
      fileReceivedBytes: 2,
      fileTotalBytes: 10, // announced 10 bytes
    );

    expect(
      () => transport.sealCurrentFileForTesting(),
      throwsA(isA<StateError>()),
    );

    // Partial should be discarded, final file never created
    expect(finalFile.existsSync(), isFalse);
    expect(partialFile.existsSync(), isFalse);
    expect(transport.receivedPaths.contains(finalFile.path), isFalse);
  });

  test('cancel() deletes partial file if cancelled mid-transfer', () async {
    final finalFile = File(p.join(tempDir.path, 'incomplete.bin'));
    final partialFile = File(p.join(tempDir.path, 'incomplete.bin.qs.partial'));

    final raf = partialFile.openSync(mode: FileMode.write);
    raf.writeFromSync(Uint8List.fromList([1, 2, 3]));

    transport.setPathsForTesting(
      raf: raf,
      partialPath: partialFile.path,
      targetPath: finalFile.path,
      fileReceivedBytes: 3,
      fileTotalBytes: 100,
    );

    await transport.cancel();

    expect(finalFile.existsSync(), isFalse);
    expect(partialFile.existsSync(), isFalse);
  });
}

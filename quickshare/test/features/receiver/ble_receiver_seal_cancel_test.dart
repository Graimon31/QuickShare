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

  test('P0-1: truncated middle file fails completion instead of silent drop', () async {
    transport.setBaseDirForTesting(tempDir.path);
    transport.setTargetDeviceIdForTesting('device_1');

    // Announce file 1 (size 10 bytes)
    final meta1 = Uint8List.fromList(
      '{"name":"file1.bin","size":10,"index":0,"count":2,"sessionBytes":20}'
          .codeUnits,
    );
    transport.handleMetadataForTesting(meta1);

    // Deliver only 5 bytes
    transport.handleDataForTesting(Uint8List.fromList([1, 2, 3, 4, 5]));

    // Announce file 2 before file 1 completed
    final meta2 = Uint8List.fromList(
      '{"name":"file2.bin","size":10,"index":1,"count":2,"sessionBytes":20}'
          .codeUnits,
    );
    transport.handleMetadataForTesting(meta2);

    // Completion future must complete with StateError, not succeed without file1
    expect(transport.completionForTesting.future, throwsA(isA<StateError>()));

    // file1 partial must be deleted, and final not created
    final file1 = File(p.join(tempDir.path, 'file1.bin'));
    final file1Partial = File(p.join(tempDir.path, 'file1.bin.qs.partial'));
    expect(file1.existsSync(), isFalse);
    expect(file1Partial.existsSync(), isFalse);
    expect(transport.receivedPaths.contains(file1.path), isFalse);
  });

  test('P0-1: truncated last file fails completion instead of hanging', () async {
    transport.setBaseDirForTesting(tempDir.path);
    transport.setTargetDeviceIdForTesting('device_1');

    // Announce single file of 10 bytes
    final meta = Uint8List.fromList(
      '{"name":"last.bin","size":10,"index":0,"count":1,"sessionBytes":10}'
          .codeUnits,
    );
    transport.handleMetadataForTesting(meta);

    // Deliver only 4 bytes
    transport.handleDataForTesting(Uint8List.fromList([1, 2, 3, 4]));

    // Completion must fail with StateError, not hang forever
    final futureExpectation =
        expectLater(transport.completionForTesting.future, throwsA(isA<StateError>()));

    // Trigger finalize (e.g. sender disconnected or closed transfer)
    await transport.finalizeForTesting();
    await futureExpectation;

    final last = File(p.join(tempDir.path, 'last.bin'));
    final lastPartial = File(p.join(tempDir.path, 'last.bin.qs.partial'));
    expect(last.existsSync(), isFalse);
    expect(lastPartial.existsSync(), isFalse);
    expect(transport.receivedPaths.contains(last.path), isFalse);
  });

  test('P0-1 remnants: failed session drops subsequent metadata and data', () async {
    transport.setBaseDirForTesting(tempDir.path);
    final errorFuture = expectLater(
        transport.completionForTesting.future, throwsA(isA<Exception>()));
    transport.failSessionForTesting(Exception('Initial failure'));

    expect(transport.isFailedForTesting, isTrue);

    final meta = Uint8List.fromList(
      '{"name":"ignored.bin","size":10,"index":0,"count":1,"sessionBytes":10}'
          .codeUnits,
    );
    transport.handleMetadataForTesting(meta);
    transport.handleDataForTesting(Uint8List.fromList([1, 2, 3]));

    final ignored = File(p.join(tempDir.path, 'ignored.bin'));
    final ignoredPartial = File(p.join(tempDir.path, 'ignored.bin.qs.partial'));
    expect(ignored.existsSync(), isFalse);
    expect(ignoredPartial.existsSync(), isFalse);
    await errorFuture;
  });

  test('P0-1 remnants: idle timer armed on data and finalize fails incomplete file', () async {
    transport.setBaseDirForTesting(tempDir.path);
    transport.setTargetDeviceIdForTesting('device_1');

    final meta = Uint8List.fromList(
      '{"name":"idle_test.bin","size":100,"index":0,"count":1,"sessionBytes":100}'
          .codeUnits,
    );
    transport.handleMetadataForTesting(meta);
    transport.handleDataForTesting(Uint8List.fromList([1, 2, 3, 4, 5]));

    expect(transport.idleTimerForTesting, isNotNull);

    final futureExpectation =
        expectLater(transport.completionForTesting.future, throwsA(isA<StateError>()));

    await transport.finalizeForTesting();
    await futureExpectation;

    expect(transport.isFailedForTesting, isTrue);
  });

  test('no phantom success: finalize with zero files fails completion with StateError', () async {
    transport.setBaseDirForTesting(tempDir.path);
    transport.setTargetDeviceIdForTesting('device_1');

    final futureExpectation = expectLater(
      transport.completionForTesting.future,
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('Connection lost before any file was received'),
      )),
    );

    await transport.finalizeForTesting();
    await futureExpectation;

    expect(transport.receivedPaths, isEmpty);
    expect(tempDir.listSync(), isEmpty);
  });

  test('finalize with metadata but no data bytes fails and deletes partial', () async {
    transport.setBaseDirForTesting(tempDir.path);
    transport.setTargetDeviceIdForTesting('device_1');

    final meta = Uint8List.fromList(
      '{"name":"empty_delivery.bin","size":50,"index":0,"count":1,"sessionBytes":50}'
          .codeUnits,
    );
    transport.handleMetadataForTesting(meta);

    final futureExpectation = expectLater(
      transport.completionForTesting.future,
      throwsA(isA<StateError>()),
    );

    await transport.finalizeForTesting();
    await futureExpectation;

    final file = File(p.join(tempDir.path, 'empty_delivery.bin'));
    final partial = File(p.join(tempDir.path, 'empty_delivery.bin.qs.partial'));
    expect(file.existsSync(), isFalse);
    expect(partial.existsSync(), isFalse);
    expect(transport.receivedPaths, isEmpty);
  });
}

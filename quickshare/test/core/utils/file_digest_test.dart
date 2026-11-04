// Re-reading a finished file for its SHA-256 is the expensive way to get a
// digest, and it is needed exactly when the bytes did not pass through (a
// resumed download's first half; a file a resume has to prove is still whole).
// It must not freeze the isolate that answers Cancel, and Cancel must reach it.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/utils/file_digest.dart';
import 'package:quickshare/core/utils/streaming_digest.dart';

import '../../support/open_files.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('dd_filedigest_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File fileOf(int bytes) {
    final f = File(p.join(dir.path, 'f$bytes.bin'));
    f.writeAsBytesSync(
        Uint8List.fromList(List.generate(bytes, (i) => (i * 31 + 7) & 0xFF)));
    return f;
  }

  test('a small file is hashed in place and matches', () async {
    final f = fileOf(1000);
    expect(await FileDigest.sha256Of(f.path),
        'sha256:${sha256.convert(f.readAsBytesSync())}');
  });

  test('a big one is hashed in a worker and matches', () async {
    final f = fileOf(StreamingDigest.worthAnIsolate + 12345);
    expect(await FileDigest.sha256Of(f.path),
        'sha256:${sha256.convert(f.readAsBytesSync())}');
  });

  test('an empty file has the empty digest', () async {
    final f = fileOf(0);
    expect(await FileDigest.sha256Of(f.path),
        'sha256:${sha256.convert(const <int>[])}');
  });

  /// What a caller of a cancelled digest is entitled to: the file is not open
  /// any more. Windows refuses to rename or delete an open file, so doing both
  /// is the check there; elsewhere the operating system is asked.
  void expectPutDown(File f) {
    final held = holdsOpen(f.path);
    if (held != null) {
      expect(held, isFalse,
          reason: 'the worker was told to stop, but still has the file open');
    }
    final moved = f.renameSync(p.join(dir.path, 'moved.bin'));
    moved.deleteSync();
    expect(moved.existsSync(), isFalse);
  }

  test('cancelling reaches the worker and ends the wait', () async {
    final f = fileOf(StreamingDigest.worthAnIsolate * 6);
    final cancel = Completer<void>();
    final pending = FileDigest.sha256Of(f.path, cancelled: cancel.future);
    final expectation = expectLater(pending, throwsA(isA<DigestCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    cancel.complete();
    await expectation;

    // The contract of the exception: by the time it is thrown the file is
    // free. Killing the worker does not give that — an isolate's open files
    // outlive the kill until it is torn down — and it showed on Windows as a
    // folder that could not be deleted after a cancelled transfer.
    expectPutDown(f);
  });

  test('a cancel that is already asked for when the worker starts still stops it',
      () async {
    final f = fileOf(StreamingDigest.worthAnIsolate * 6);

    await expectLater(
        FileDigest.sha256Of(f.path, cancelled: Future<void>.value()),
        throwsA(isA<DigestCancelled>()));

    expectPutDown(f);
  });

  test('cancelling is quick: it waits for a block, not for the file', () async {
    final f = fileOf(StreamingDigest.worthAnIsolate * 12);
    final cancel = Completer<void>();
    final pending = FileDigest.sha256Of(f.path, cancelled: cancel.future);
    final expectation = expectLater(pending, throwsA(isA<DigestCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final asked = Stopwatch()..start();
    cancel.complete();
    await expectation;

    expect(asked.elapsed, lessThan(const Duration(seconds: 1)),
        reason: 'a cancel that waits for the whole hash is a Cancel that '
            'does nothing');
    expectPutDown(f);
  });

  test('a cancel that comes after the answer changes nothing', () async {
    final f = fileOf(StreamingDigest.worthAnIsolate + 12345);
    final cancel = Completer<void>();

    final digest = await FileDigest.sha256Of(f.path, cancelled: cancel.future);
    cancel.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(digest, 'sha256:${sha256.convert(f.readAsBytesSync())}');
    expectPutDown(f);
  });

  test('a digest that ran to the end leaves the file free as well', () async {
    final f = fileOf(StreamingDigest.worthAnIsolate + 1);

    await FileDigest.sha256Of(f.path);

    expectPutDown(f);
  });

  test('a file that is not there is a file error, not a hang', () async {
    await expectLater(FileDigest.sha256Of(p.join(dir.path, 'nope')),
        throwsA(isA<FileSystemException>()));
  });

  test('a file that vanishes before the worker reads it is a file error',
      () async {
    final f = fileOf(StreamingDigest.worthAnIsolate + 1);
    final pending = FileDigest.sha256Of(f.path);
    f.deleteSync();
    // Either the length lookup or the worker's read notices; both are
    // FileSystemExceptions, and neither may hang.
    await expectLater(pending.timeout(const Duration(seconds: 20)),
        throwsA(isA<FileSystemException>()));
  });
}

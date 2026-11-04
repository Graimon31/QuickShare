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

  test('cancelling reaches the worker and ends the wait', () async {
    final f = fileOf(StreamingDigest.worthAnIsolate * 6);
    final cancel = Completer<void>();
    final pending = FileDigest.sha256Of(f.path, cancelled: cancel.future);
    final expectation = expectLater(pending, throwsA(isA<DigestCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    cancel.complete();
    await expectation;
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

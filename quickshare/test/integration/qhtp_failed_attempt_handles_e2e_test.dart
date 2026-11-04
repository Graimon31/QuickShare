// An attempt that fails while a block is still being written must leave the
// partial's handle closed, not open.
//
// The receiver hands blocks to the disk and keeps reading the socket while the
// write runs. An error from anywhere in that loop — the connection, the hashing
// worker, a listener — lands with a write in flight, and the attempt's cleanup
// then closes the handle. A handle with an operation pending does not close:
// the call returns "An async operation is currently pending" and the file stays
// open. The cleanup swallowed that, so every such failure leaked a descriptor
// per retry, on Windows kept the partial from being renamed or deleted, and
// let the write land after the next attempt had measured the length it
// resumes from.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'qhtp_receive_harness.dart';

Uint8List _bytes(int n, int seed) {
  final rand = Random(seed);
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rand.nextInt(256);
  }
  return out;
}

/// A handle with the SDK's contract: one operation at a time, and a close that
/// is refused — not queued — while one is running. Writes take a while, so
/// there is a write in flight whenever the test wants one.
class _StrictHandle implements RandomAccessFile {
  _StrictHandle(this._real, this._writeTime);

  final RandomAccessFile _real;
  final Duration _writeTime;

  bool busy = false;
  bool closed = false;
  int refusedCloses = 0;

  FileSystemException _pending() => const FileSystemException(
      'An async operation is currently pending');

  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer,
      [int start = 0, int? end]) async {
    if (closed) throw const FileSystemException('File closed');
    if (busy) throw _pending();
    busy = true;
    try {
      await Future<void>.delayed(_writeTime);
      await _real.writeFrom(buffer, start, end);
      return this;
    } finally {
      busy = false;
    }
  }

  @override
  Future<RandomAccessFile> flush() async {
    if (closed) throw const FileSystemException('File closed');
    if (busy) throw _pending();
    await _real.flush();
    return this;
  }

  @override
  Future<void> close() async {
    if (busy) {
      refusedCloses++;
      throw _pending();
    }
    if (closed) throw const FileSystemException('File closed');
    closed = true;
    await _real.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} on a strict handle');
}

class _Disk {
  final handles = <_StrictHandle>[];

  RandomAccessFile wrap(RandomAccessFile real) {
    final handle = _StrictHandle(real, const Duration(milliseconds: 400));
    handles.add(handle);
    return handle;
  }

  bool get writeRunning => handles.any((h) => h.busy);
  int get refusedCloses => handles.fold(0, (sum, h) => sum + h.refusedCloses);
}

void main() {
  setUpAll(installFakeWakelock);

  late QhtpHarness h;
  setUp(() async => h = await QhtpHarness.create());
  tearDown(() => h.dispose());

  test('an error thrown while a block is being written leaves every handle '
      'closed, the last attempt\'s included', () async {
    final data = _bytes(24 * 1024 * 1024, 31);
    await h.serve({'big.bin': data});
    final disk = _Disk();
    var provoked = 0;

    final result = await h.client(wrapSink: disk.wrap).downloadSession(
      payload: h.payload,
      targetBaseDir: h.target.path,
      onProgress: (progress) {
        // Every attempt, at a moment a write is known to be running. The first
        // two are followed by a back-off, and the file is closed only after
        // it, by which time the write has long finished; the last has no
        // back-off, and its cleanup meets the write.
        if (progress.phase != 'transferring' || !disk.writeRunning) return;
        provoked++;
        throw StateError('a listener failed mid-write (test)');
      },
    );

    expect(provoked, greaterThanOrEqualTo(3),
        reason: 'every attempt was meant to fail with a write running');
    expect(disk.handles, hasLength(3), reason: 'one handle per attempt');
    expect(disk.refusedCloses, 0,
        reason: 'the cleanup closed a handle that had a write running, which '
            'the file system refuses, and carried on as if it had worked');
    expect(disk.handles.where((handle) => !handle.closed), isEmpty,
        reason: 'a handle was left open');
    // And the session did not pretend: three failed attempts are a failure.
    final failure = expectRefused(result);
    expect(failure.message, contains('after 3 retries'));
    expect(File(h.received('big.bin')).existsSync(), isFalse,
        reason: 'a file that never arrived whole is not under its real name');
  });
}

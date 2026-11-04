// The sender reads a file a block ahead of the socket. When the receiver hangs
// up, that read-ahead is still in flight, and the handle has to be closed
// anyway: `RandomAccessFile.close()` with an operation pending does not wait
// and does not close — it returns an error and leaves the handle open. A
// descriptor leaked per dropped download everywhere, and on Windows a source
// file that cannot be renamed or deleted until the garbage collector runs.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/features/sender/data/server/local_http_server.dart';

import '../../support/open_files.dart';

/// A file that remembers the handle it gave out, so a test can ask it later
/// whether it was closed. Everything else is real: the handle is the SDK's own,
/// with the SDK's own refusal to close while a read is pending.
class _SpyFile implements File {
  _SpyFile(this._real);

  final File _real;
  RandomAccessFile? opened;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      opened = await _real.open(mode: mode);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} on a spy file');
}

void main() {
  late Directory dir;
  late File file;
  const blockSize = 1024 * 1024;
  // Several blocks, so that a read-ahead is always pending at a `yield`.
  const size = blockSize * 4 + 123;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dd_readrange_');
    file = File(p.join(dir.path, 'big.bin'))
      ..writeAsBytesSync(
          Uint8List.fromList(List.generate(size, (i) => i % 251)));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a receiver that hangs up mid-file leaves the handle closed', () async {
    final spy = _SpyFile(file);
    final first = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = LocalHttpServer.readRangeForTesting(spy, 0, size).listen((_) {
      // The generator is parked at its `yield` and the next block is being
      // read. Hang up right there.
      if (!first.isCompleted) first.complete();
    });
    await first.future;

    await sub.cancel();
    // A read that was left running would still be finishing about now.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(handleIsClosed(spy.opened!), isTrue,
        reason: 'the look-ahead read was pending when the generator was '
            'cancelled, close() was refused, and the handle stayed open');
  });

  test('and the file can be renamed and deleted straight away', () async {
    // What Windows enforces for a handle that is still open.
    final spy = _SpyFile(file);
    final first = Completer<void>();
    final sub = LocalHttpServer.readRangeForTesting(spy, 0, size)
        .listen((_) => first.isCompleted ? null : first.complete());
    await first.future;
    await sub.cancel();

    final moved = file.renameSync(p.join(dir.path, 'moved.bin'));
    moved.deleteSync();
    expect(moved.existsSync(), isFalse);
  });

  test('hanging up does not surface an error nobody is left to handle',
      () async {
    final spy = _SpyFile(file);
    final first = Completer<void>();
    final sub = LocalHttpServer.readRangeForTesting(spy, 0, size)
        .listen((_) => first.isCompleted ? null : first.complete());
    await first.future;

    await sub.cancel(); // throws if closing the handle was refused
  });

  test('a whole read delivers every byte, once, and closes the handle',
      () async {
    final spy = _SpyFile(file);
    final got = BytesBuilder(copy: false);
    await for (final block in LocalHttpServer.readRangeForTesting(spy, 0, size)) {
      got.add(block);
    }

    expect(got.length, size);
    expect(got.takeBytes(), file.readAsBytesSync());
    expect(handleIsClosed(spy.opened!), isTrue);
  });

  test('a range from the middle starts where it was asked to', () async {
    final spy = _SpyFile(file);
    const from = blockSize + 77;
    const to = blockSize * 3 + 5;
    final got = BytesBuilder(copy: false);
    await for (final block
        in LocalHttpServer.readRangeForTesting(spy, from, to)) {
      got.add(block);
    }

    expect(got.takeBytes(), file.readAsBytesSync().sublist(from, to));
    expect(handleIsClosed(spy.opened!), isTrue);
  });

  test('an empty range reads nothing and still closes the handle', () async {
    final spy = _SpyFile(file);
    final blocks =
        await LocalHttpServer.readRangeForTesting(spy, 10, 10).toList();

    expect(blocks, isEmpty);
    expect(handleIsClosed(spy.opened!), isTrue);
  });
}

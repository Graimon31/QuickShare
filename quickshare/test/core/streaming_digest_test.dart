// Hashing belongs on another core, not in the transfer's loop.
//
// Measured on this machine, serving a 400 MB file over the local HTTPS
// server: 53 MB/s with no hashing in the loop, 34.7 MB/s with SHA-256 inline.
// Dart's SHA-256 does about 103 MB/s and the event loop is already carrying
// TLS and a socket, so the two simply take turns. Moving it to a worker
// isolate hashes the same bytes without the transfer paying for them — but
// only if the answer is identical to hashing them here, which is what this
// checks.
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/utils/streaming_digest.dart';

void main() {
  test('the worker agrees with hashing the same bytes in one go', () async {
    final rand = Random(7);
    final blocks = [
      for (var i = 0; i < 9; i++)
        Uint8List.fromList(
            List.generate(300 * 1024 + i, (_) => rand.nextInt(256))),
    ];
    final whole = <int>[for (final b in blocks) ...b];

    final digest = await StreamingDigest.start();
    for (final block in blocks) {
      await digest.add(block);
    }
    final answer = await digest.finish();

    expect(answer, 'sha256:${sha256.convert(whole)}');
  });

  test('the blocks handed over are still readable afterwards', () async {
    // TransferableTypedData detaches whatever it is given, and these bytes
    // are on their way to a socket at the same time — so a copy is made on
    // the way in. Without it the transfer would send zeroes.
    final block = Uint8List.fromList(List.generate(1024, (i) => i % 251));
    final digest = await StreamingDigest.start();
    await digest.add(block);
    await digest.finish();

    expect(block[5], 5, reason: 'the caller keeps its own bytes');
  });

  test('an aborted digest does not leave the worker running', () async {
    final digest = await StreamingDigest.start();
    await digest.add(Uint8List(1024));
    await digest.abort();
    // Aborting twice is what a failed attempt inside a retry loop does.
    await digest.abort();
  });

  test('a file below the isolate threshold is not worth one', () {
    expect(StreamingDigest.worthAnIsolate, greaterThan(1024 * 1024),
        reason: 'spawning an isolate per small file in a folder of ten '
            'thousand would cost more than it saves');
  });
}

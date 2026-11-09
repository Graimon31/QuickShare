// The SHA-256 each end keeps of an item, including the one that has to be
// caught up with a file that was half written when a transfer resumed.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/utils/streaming_digest.dart';
import 'package:quickshare/core/webrtc/resume/item_digest.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dd_digest_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Uint8List noise(int n, [int seed = 1]) {
    final r = Random(seed);
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  test('a small item is hashed in place and matches SHA-256', () async {
    final data = noise(300000);
    final d = await ItemDigest.start(data.length);
    await d.add(data.sublist(0, 1000));
    await d.add(data.sublist(1000));
    expect(await d.finish(), sha256.convert(data).toString());
  });

  test('an item past the isolate threshold is hashed by a worker, with the '
      'same answer', () async {
    final data = noise(StreamingDigest.worthAnIsolate + 12345);
    final d = await ItemDigest.start(data.length);
    for (var at = 0; at < data.length; at += 1 << 20) {
      await d.add(data.sublist(at, min(at + (1 << 20), data.length)));
    }
    expect(await d.finish(), sha256.convert(data).toString());
  });

  test('a digest caught up with the part already on disk covers the whole '
      'file', () async {
    final data = noise(2500000, 7);
    final path = p.join(dir.path, 'partial.bin');
    File(path).writeAsBytesSync(data.sublist(0, 1700000));

    final d = await ItemDigest.start(data.length, forceInline: true);
    await d.primeFrom(path, 1700000);
    await d.add(data.sublist(1700000));
    expect(await d.finish(), sha256.convert(data).toString());
  });

  test('catching up with a file shorter than it should be is an error, not '
      'a quietly different hash', () async {
    final path = p.join(dir.path, 'short.bin');
    File(path).writeAsBytesSync(noise(1000));
    final d = await ItemDigest.start(5000, forceInline: true);
    await expectLater(
        d.primeFrom(path, 5000), throwsA(isA<FileSystemException>()));
    await d.abort();
  });

  test('a digest of a different file differs; one flipped bit changes it',
      () async {
    final data = noise(100000);
    final flipped = Uint8List.fromList(data)..[5000] ^= 1;
    final a = await ItemDigest.start(data.length);
    await a.add(data);
    final b = await ItemDigest.start(data.length);
    await b.add(flipped);
    expect(await a.finish(), isNot(await b.finish()));
  });

  test('aborting a digest is safe, twice, and after finishing', () async {
    final d = await ItemDigest.start(10);
    await d.abort();
    await d.abort();
    final e = await ItemDigest.start(10);
    await e.add([1, 2, 3]);
    await e.finish();
    await e.abort();
  });
}

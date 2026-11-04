// A resumed download must be exactly the bytes it claims to be.
//
// The receiver asks for the rest of a partial file with `Range: bytes=N-`. The
// answer is only worth appending if it says it is the rest: a 206 whose
// `Content-Range` starts at N, of a file of the right total length. Anything
// else is a server that did not do what was asked, and what it sends is not
// ours to append — least of all when the item has no digest anywhere, because
// then nothing downstream can tell the right bytes from the wrong ones, only
// their number.
//
// A real sender (`LocalHttpServer`) and a real receiver, on loopback. The Dio
// interceptor stands in for a misbehaving server by rewriting what goes out and
// what comes back, so the server behind it is the genuine one and the bytes it
// sends are real.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';

import 'qhtp_receive_harness.dart';

Uint8List _bytes(int n, int seed) {
  final rand = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => rand.nextInt(256)));
}

void main() {
  setUpAll(installFakeWakelock);

  late QhtpHarness h;
  final source = _bytes(1024 * 1024, 4242);
  const have = 300 * 1024;

  setUp(() async => h = await QhtpHarness.create());
  tearDown(() => h.dispose());

  bool isFileGet(RequestOptions o) =>
      o.method == 'GET' &&
      o.uri.path.contains('/v2/files/') &&
      !o.uri.path.endsWith('/digest');

  /// A receiver whose traffic can be rewritten on the way out and on the way
  /// back. The digest endpoint is refused, and the session is served without
  /// checksums, so the item has no digest anywhere.
  QhtpReceiverClient client({
    void Function(RequestOptions options)? rewriteRequest,
    void Function(Response<dynamic> response)? rewriteResponse,
  }) {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.path.endsWith('/digest')) {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'digest endpoint unavailable (test)',
            ));
            return;
          }
          if (isFileGet(options)) rewriteRequest?.call(options);
          handler.next(options);
        },
        onResponse: (response, handler) {
          if (isFileGet(response.requestOptions)) {
            rewriteResponse?.call(response);
          }
          handler.next(response);
        },
      ));
    return QhtpReceiverClient(dioClient: dio, store: h.store);
  }

  /// `a.bin` served with no digest, and its first [have] bytes already on disk
  /// as a partial — the state a cut transfer leaves.
  Future<File> seedPartial() async {
    await h.serve({'a.bin': source}, checksums: false);
    return File(h.received('a.bin.qs.partial'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(source.sublist(0, have));
  }

  String shaOf(List<int> b) => sha256.convert(b).toString();

  test('control: an honest 206 resumes and the file is identical', () async {
    final partial = await seedPartial();
    final ranges = <String?>[];

    final result = await client(
      rewriteRequest: (o) => ranges.add(o.headers['Range'] as String?),
    ).downloadSession(payload: h.payload, targetBaseDir: h.target.path);

    expectReceived(result);
    expect(ranges, ['bytes=$have-']);
    expect(shaOf(File(h.received('a.bin')).readAsBytesSync()), shaOf(source));
    expect(partial.existsSync(), isFalse);
  });

  test('a 206 that starts somewhere other than where it was asked to is not '
      'appended', () async {
    final partial = await seedPartial();

    // Asks for the right NUMBER of bytes from the wrong place: the answer is a
    // perfectly well-formed 206 of exactly the length that is missing.
    final result = await client(
      rewriteRequest: (o) =>
          o.headers['Range'] = 'bytes=0-${source.length - have - 1}',
    ).downloadSession(payload: h.payload, targetBaseDir: h.target.path);

    expectRefused(result);
    expect(File(h.received('a.bin')).existsSync(), isFalse,
        reason: 'a file of the right size and the wrong content was committed '
            'as complete');
    expect(partial.readAsBytesSync(), source.sublist(0, have),
        reason: 'the partial must be exactly what it was: nothing appended');
  });

  test('a 206 with no Content-Range is not appended', () async {
    final partial = await seedPartial();

    final result = await client(
      rewriteResponse: (r) => r.headers.removeAll('content-range'),
    ).downloadSession(payload: h.payload, targetBaseDir: h.target.path);

    expectRefused(result);
    expect(File(h.received('a.bin')).existsSync(), isFalse);
    expect(partial.readAsBytesSync(), source.sublist(0, have));
  });

  test('a 206 for a file of another length is not appended', () async {
    final partial = await seedPartial();

    final result = await client(
      rewriteResponse: (r) => r.headers.set('content-range',
          'bytes $have-${source.length * 2 - 1}/${source.length * 2}'),
    ).downloadSession(payload: h.payload, targetBaseDir: h.target.path);

    expectRefused(result);
    expect(File(h.received('a.bin')).existsSync(), isFalse);
    expect(partial.readAsBytesSync(), source.sublist(0, have));
  });

  test('a 200 means the Range was ignored: the item starts again from zero',
      () async {
    final partial = await seedPartial();
    var stripped = 0;

    final result = await client(
      rewriteRequest: (o) {
        if (o.headers.remove('Range') != null) stripped++;
      },
    ).downloadSession(payload: h.payload, targetBaseDir: h.target.path);

    expectReceived(result);
    expect(stripped, greaterThan(0), reason: 'the test never took the Range off');
    final landed = File(h.received('a.bin')).readAsBytesSync();
    expect(landed.length, source.length,
        reason: 'the whole file was appended to the old partial');
    expect(shaOf(landed), shaOf(source));
    expect(partial.existsSync(), isFalse);
  });

  test('a 200 that restarts the item never truncates through a link put in '
      'the partial\'s place meanwhile', () async {
    final partial = await seedPartial();
    final victim = File('${h.outside.path}/victim.bin')
      ..writeAsStringSync('the user\'s own file');
    var swapped = false;

    final result = await client(
      rewriteRequest: (o) => o.headers.remove('Range'),
      // Between measuring the partial and restarting it, the partial is
      // replaced by a link to somebody else's file.
      rewriteResponse: (r) {
        if (swapped) return;
        swapped = true;
        partial.deleteSync();
        Link(partial.path).createSync(victim.path);
      },
    ).downloadSession(payload: h.payload, targetBaseDir: h.target.path);

    expectReceived(result);
    expect(swapped, isTrue);
    expect(victim.readAsStringSync(), 'the user\'s own file',
        reason: 'the restart truncated or wrote through the link');
    expect(shaOf(File(h.received('a.bin')).readAsBytesSync()), shaOf(source));
  });
}

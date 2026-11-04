// A `.qs.partial` is bytes an earlier run wrote. Nothing about them is known
// except their number, and the manifest says what that number has to be.
//
// What these tests pin down is what the receiver does with a partial that
// cannot be the start of the item it belongs to, and with one that can: a
// stale one left beside an empty file, one that is longer than the file it was
// for, a body that ends short, and a partial whose own bytes were damaged
// between the runs.
//
// A real sender (`LocalHttpServer`) and a real receiver on loopback, in
// scratch directories. The session is served without checksums and the
// digest endpoint is refused wherever a test says so, so that the item has no
// digest anywhere and only the byte count and the receiver's own care stand
// between the disk and the wrong content.
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

String _shaOf(List<int> b) => sha256.convert(b).toString();

void main() {
  setUpAll(installFakeWakelock);

  late QhtpHarness h;

  setUp(() async => h = await QhtpHarness.create());
  tearDown(() => h.dispose());

  File partialOf(String relative) =>
      File('${h.received(relative)}.qs.partial');

  group('an empty item', () {
    test('is empty on arrival, whatever a stale partial beside it holds',
        () async {
      await h.serve({
        'empty.bin': Uint8List(0),
        'b.bin': Uint8List.fromList([1, 2, 3]),
      }, checksums: false);
      final stale = partialOf('empty.bin')
        ..createSync(recursive: true)
        ..writeAsStringSync('stale bytes of something else');

      final result = await h
          .client(failDigests: true)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path);

      expectReceived(result);
      expect(File(h.received('empty.bin')).lengthSync(), 0,
          reason: 'bytes left by another file were published as this one');
      expect(stale.existsSync(), isFalse);
      expect(File(h.received('b.bin')).readAsBytesSync(), [1, 2, 3]);
    });

    test('a stale partial is not even resumed onto: it is emptied first',
        () async {
      await h.serve({'empty.bin': Uint8List(0)}, checksums: false);
      partialOf('empty.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_bytes(4096, 3));

      final result = await h
          .client(failDigests: true)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path);

      expectReceived(result);
      expect(File(h.received('empty.bin')).lengthSync(), 0);
      expect(h.fileRequestsFor('empty.bin'), 0,
          reason: 'there is nothing to ask the sender for');
    });
  });

  group('a partial longer than the item', () {
    test('is started over, and the item still arrives whole', () async {
      final a = _bytes(200 * 1024, 11);
      await h.serve({'a.bin': a}, checksums: false);
      partialOf('a.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_bytes(a.length + 5000, 12));
      final ranges = <String?>[];
      final progress = <QhtpProgress>[];

      final result = await h.client(
        failDigests: true,
        onRequest: (r) {
          if (r.isFile) ranges.add(r.range);
        },
      ).downloadSession(
          payload: h.payload,
          targetBaseDir: h.target.path,
          onProgress: progress.add);

      expectReceived(result);
      expect(ranges, [null], reason: 'resumed from a partial that was too long');
      expect(File(h.received('a.bin')).readAsBytesSync(), a);

      // It was started over straight away: the item was never "verified" as
      // it stood, found too long, and thrown back for another attempt a
      // second later.
      final id = h.idOf('a.bin');
      final phases = [
        for (final e in progress.where((e) => e.itemId == id)) e.phase,
      ];
      expect(phases.where((phase) => phase == 'verifying'), hasLength(1),
          reason: phases.join(', '));
      expect(phases.first, 'transferring');
    });
  });

  group('a body that ends short', () {
    /// Replaces the sender's answer with the same answer cut after [keep]
    /// bytes, with a length that agrees: the shape of a sender that stopped
    /// early and said so honestly, or of a middlebox that trimmed the body.
    QhtpReceiverClient truncating(int keep) {
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
            handler.next(options);
          },
          onResponse: (response, handler) {
            final isFile = response.requestOptions.uri.path
                .contains(RegExp(r'/v2/files/[^/]+$'));
            final body = response.data;
            if (isFile && body is ResponseBody) {
              var left = keep;
              response.data = ResponseBody(
                body.stream.map((chunk) {
                  final cut = min(left, chunk.length);
                  left -= cut;
                  return Uint8List.sublistView(chunk, 0, cut);
                }).where((chunk) => chunk.isNotEmpty),
                body.statusCode,
                headers: {
                  ...body.headers,
                  'content-length': ['$keep'],
                },
              );
            }
            handler.next(response);
          },
        ));
      return QhtpReceiverClient(dioClient: dio, store: h.store);
    }

    test('never gets the real name when there is no digest to disagree',
        () async {
      final a = _bytes(150 * 1024, 21);
      await h.serve({'a.bin': a}, checksums: false);

      final result = await truncating(a.length - 100)
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path);

      final failure = expectRefused(result);
      expect(failure.message, contains('size mismatch'),
          reason: 'refused where the file is published, not found out later');
      expect(File(h.received('a.bin')).existsSync(), isFalse,
          reason: 'a file ${a.length - 100} bytes long was published as '
              'complete');
      expect(partialOf('a.bin').existsSync(), isFalse,
          reason: 'a retry must start from zero, not onto a short body');
    });
  });

  group('a resumed partial', () {
    const have = 100 * 1024;

    test('whose own bytes were damaged is not published as verified',
        () async {
      final a = _bytes(200 * 1024, 31);
      await h.serve({'a.bin': a});
      final damaged = Uint8List.fromList(a.sublist(0, have))..[10] ^= 0xFF;
      partialOf('a.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(damaged);

      final result = await h
          .client()
          .downloadSession(payload: h.payload, targetBaseDir: h.target.path);

      // The damage is found by the digest over the whole file. What matters is
      // that the bytes it finds are never what lands: the retry starts again
      // from zero and the file that arrives is the sender's.
      expectReceived(result);
      expect(_shaOf(File(h.received('a.bin')).readAsBytesSync()), _shaOf(a));
      expect(partialOf('a.bin').existsSync(), isFalse);
    });

    test('that is intact is hashed too, and the digest is the whole '
        'file\'s', () async {
      final a = _bytes(200 * 1024, 32);
      await h.serve({'a.bin': a});
      partialOf('a.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(a.sublist(0, have));
      final ranges = <String?>[];

      final result = await h.client(onRequest: (r) {
        if (r.isFile) ranges.add(r.range);
      }).downloadSession(payload: h.payload, targetBaseDir: h.target.path);

      expectReceived(result);
      expect(ranges, ['bytes=$have-']);
      expect(File(h.received('a.bin')).readAsBytesSync(), a);
      final recorded = (await h.store.loadState(h.sessionId));
      // The session finished, so its record is gone; the digest the item
      // carried is checked through the completion body instead.
      expect(recorded, isNull);
      expect(h.completionBody?['failedItems'], 0);
    });
  });
}

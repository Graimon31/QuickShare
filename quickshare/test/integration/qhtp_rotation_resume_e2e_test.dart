// A transfer survives the sender changing its code and QR underneath it.
//
// The sender's offer rotates every five minutes. A receiver that is partway
// through a session — or that was cut off a minute ago and is about to resume —
// holds the token it was given, and a rotation must not take that away. A real
// sender (`LocalHttpServer`) and a real receiver (`QhtpReceiverClient`), on
// loopback: the rotation happens between the cut and the resume.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

import 'qhtp_receive_harness.dart';

Uint8List _bytes(int n, int seed) {
  final rand = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => rand.nextInt(256)));
}

void main() {
  setUpAll(installFakeWakelock);

  late QhtpHarness h;
  final source = _bytes(1024 * 1024, 7);
  const have = 300 * 1024;

  setUp(() async => h = await QhtpHarness.create());
  tearDown(() => h.dispose());

  QRPayload payloadWith(String token) => QRPayload(
        version: 2,
        ip: '127.0.0.1',
        port: h.payload.port,
        token: token,
        sessionId: h.payload.sessionId,
        mode: 'http-lan',
        tlsFingerprint: h.payload.tlsFingerprint,
      );

  String shaOf(List<int> b) => sha256.convert(b).toString();

  test('cut, rotated, resumed: the file arrives whole on the token it had',
      () async {
    await h.serve({'a.bin': source}, checksums: false);
    File(h.received('a.bin.qs.partial'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(source.sublist(0, have));

    // The first attempt gets as far as the manifest — the token is used — and
    // then the link drops before a byte of the file moves again.
    var cut = true;
    final first = await h
        .client(onRequest: (r) {
          if (r.isFile && cut) {
            throw DioException(
              requestOptions: RequestOptions(path: r.path),
              type: DioExceptionType.connectionError,
              error: 'link dropped (test)',
            );
          }
        })
        .downloadSession(payload: h.payload, targetBaseDir: h.target.path);
    expectRefused(first);
    expect(File(h.received('a.bin')).existsSync(), isFalse);
    expect(h.requests.any((r) => r.path.endsWith('/v2/manifest')), isTrue,
        reason: 'the token must have been used for the rest to mean anything');

    // The offer rotates while the receiver is away.
    expect(
        h.server.rotateCredentials(
            authToken: 'rotated-token-after-the-cut',
            sessionCode: SessionCode.generate()),
        isTrue);

    cut = false;
    final resumed = await h
        .client()
        .downloadSession(payload: h.payload, targetBaseDir: h.target.path);

    expectReceived(resumed);
    expect(shaOf(File(h.received('a.bin')).readAsBytesSync()), shaOf(source));
  });

  test('a receiver that only holds the old QR, never used, is turned away '
      'after the rotation', () async {
    await h.serve({'a.bin': source}, checksums: false);
    expect(
        h.server.rotateCredentials(
            authToken: 'rotated-token',
            sessionCode: SessionCode.generate()),
        isTrue);

    final result = await h
        .client()
        .downloadSession(payload: h.payload, targetBaseDir: h.target.path);

    expectRefused(result);
    expect(File(h.received('a.bin')).existsSync(), isFalse);
  });

  test('a receiver that scans the new QR receives normally', () async {
    await h.serve({'a.bin': source}, checksums: false);
    expect(
        h.server.rotateCredentials(
            authToken: 'rotated-token',
            sessionCode: SessionCode.generate()),
        isTrue);

    final result = await h.client().downloadSession(
        payload: payloadWith('rotated-token'), targetBaseDir: h.target.path);

    expectReceived(result);
    expect(shaOf(File(h.received('a.bin')).readAsBytesSync()), shaOf(source));
  });
}

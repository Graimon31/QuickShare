// The receiver against a server that did not run the real indexer.
//
// DD-21, over a live socket. The unit tests pin the guard; this pins that the
// download path actually consults it, and that a refusal happens before the
// loop that creates directories — nothing on disk, and a message that names
// the sender as the unreasonable party.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

void main() {
  late HttpServer server;
  late SessionTlsIdentity tls;
  late Directory target;
  const token = 'the-token';

  /// Whatever the test sets — this is a server that is trying things on.
  late String manifestBody;

  setUp(() async {
    tls = SessionTlsIdentity.generate();
    target = Directory.systemTemp.createTempSync('dd_hostile_');

    Response json(Object body) => Response.ok(
          body is String ? body : jsonEncode(body),
          headers: {'content-type': 'application/json'},
        );

    server = await shelf_io.serve(
      (Request r) {
        final path = r.url.path;
        if (path == 'v2/session') {
          return json({'sessionId': 'hostile', 'itemCount': 1, 'totalBytes': 1});
        }
        if (path == 'v2/manifest') return json(manifestBody);
        return Response.notFound('');
      },
      InternetAddress.loopbackIPv4,
      0,
      securityContext: tls.securityContext,
    );
  });

  tearDown(() async {
    await server.close(force: true);
    if (target.existsSync()) target.deleteSync(recursive: true);
  });

  Future<String> download() async {
    final result = await QhtpReceiverClient().downloadSession(
      payload: QRPayload(
        version: 2,
        ip: '127.0.0.1',
        port: server.port,
        token: token,
        mode: 'http-lan',
        sessionId: 'hostile',
        tlsFingerprint: tls.fingerprint,
      ),
      targetBaseDir: target.path,
    );
    return result.fold((f) => f.message, (_) => 'DELIVERED');
  }

  test('a manifest bloated past the ceiling is refused, nothing written',
      () async {
    // A megabytes-long array of junk, well past the 32 MB body limit once
    // encoded — built to be expensive to parse, which is the reason the
    // guard checks bytes before it parses.
    final filler = List.filled(
        AppConstants.qhtpManifestMaxBytes ~/ 20 + 1000, 'x' * 20).join();
    manifestBody = jsonEncode({
      'sessionId': 'hostile',
      'itemCount': 1,
      'totalBytes': 1,
      'items': [
        {'id': '000001', 'path': 'a.bin', 'size': 1}
      ],
      'padding': filler,
    });

    final message = await download();

    expect(message, contains('MB'));
    expect(target.listSync(), isEmpty,
        reason: 'refused before the first directory is created');
  });

  test('a manifest with an absurdly deep path is refused', () async {
    final deep = List.filled(AppConstants.qhtpMaxPathDepth + 5, 'd').join('/');
    manifestBody = jsonEncode({
      'sessionId': 'hostile',
      'itemCount': 1,
      'totalBytes': 1,
      'items': [
        {'id': '000001', 'path': deep, 'size': 1}
      ],
    });

    final message = await download();

    expect(message.toLowerCase(), contains('deep'));
    expect(target.listSync(), isEmpty);
  });

  test('a manifest with a traversal path is refused before it materialises',
      () async {
    manifestBody = jsonEncode({
      'sessionId': 'hostile',
      'itemCount': 1,
      'totalBytes': 1,
      'items': [
        {'id': '000001', 'path': '../../etc/passwd', 'size': 1}
      ],
    });

    final message = await download();

    expect(message, isNot(equals('DELIVERED')));
    expect(target.listSync(), isEmpty);
  });
}

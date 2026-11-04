// What the sender's server does when the code and the QR are replaced.
//
// The server keeps its port, its certificate and its index; what changes is
// the secret that gets a stranger in. The rule that makes that safe to do in
// the middle of someone else's transfer is narrow, so each half is pinned:
//
//  * what was never used dies — the old QR, the old code, a half-finished
//    proof of the old code;
//  * what has been used, or was released to a person who was approved, goes
//    on working until the session ends, because the receiver in the middle of
//    a transfer (or its resume, a minute later) holds exactly that token.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

void main() {
  setUpAll(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());

  const firstToken = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const secondToken = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const thirdToken = 'cccccccccccccccccccccccccccccccc';

  late LocalHttpServer server;
  late SessionCode firstCode;
  late int port;

  QhtpManifest manifest() => QhtpManifest(
        sessionId: 'rotation-session',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        itemCount: 1,
        totalBytes: 100,
        items: const [QhtpItem(id: 'item-1', path: 'file.txt', size: 100)],
      );

  setUp(() async {
    server = LocalHttpServer();
    firstCode = SessionCode.generate();
    port = await server.startQhtpSessionWhileIndexing(
      sessionId: 'rotation-session',
      index: Future.value(QhtpIndexerResult(
        manifest: manifest(),
        itemIdToAbsPathMap: {'item-1': '/tmp/file.txt'},
      )),
      authToken: firstToken,
      sessionCode: firstCode,
    );
    server.onApprovalRequested = (_) async => true;
  });

  tearDown(() async => server.stop());

  Dio dio() => Dio(BaseOptions(
        validateStatus: (_) => true,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ))
        ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
          final c =
              HttpClient(context: SecurityContext(withTrustedRoots: false));
          c.badCertificateCallback =
              (cert, h, p) => SessionTlsIdentity.matches(cert, server.tlsFingerprint!);
          return c;
        });

  String url(String path) => 'https://127.0.0.1:$port$path';

  /// The status of a call that needs the bearer token.
  Future<int> sessionStatus(String token) async {
    final r = await dio().get(url('/v2/session'),
        options: Options(headers: {'Authorization': 'Bearer $token'}));
    return r.statusCode!;
  }

  /// Both rounds of the proof, as a receiver typing [code] runs them. Returns
  /// the second round's response.
  Future<Response<dynamic>> askWith(SessionCode code) async {
    final begun = await CodePake.begin(code);
    final started = await dio().post(url(CodePake.startPath),
        data: {'pA': CodePake.encode(begun.share)});
    final answer = Map<String, dynamic>.from(started.data as Map);
    final keys = await CodePake.complete(
      begun,
      senderShare: CodePake.decode(answer['pB'], length: Spake2.shareLength)!,
      certFingerprint: server.tlsFingerprint!,
    );
    return dio().post(url('/v2/invite/request'), data: {
      'pakeId': answer['pakeId'],
      'cA': CodePake.encode(keys.confirmationA),
      'deviceName': 'Test Laptop',
    });
  }

  bool rotate(String token, SessionCode code) =>
      server.rotateCredentials(authToken: token, sessionCode: code);

  group('the old secret', () {
    test('the old QR token, never used, is refused from the moment of the '
        'rotation', () async {
      expect(rotate(secondToken, SessionCode.generate()), isTrue);

      expect(await sessionStatus(firstToken), 401);
      expect(await sessionStatus(secondToken), 200,
          reason: 'the new QR works');
    });

    test('the old code proves nothing after the rotation; the new one does',
        () async {
      final newCode = SessionCode.generate();
      expect(rotate(secondToken, newCode), isTrue);

      final stale = await askWith(firstCode);
      expect(stale.statusCode, 403);
      expect((stale.data as Map)['code'], 'CODE_MISMATCH');

      final fresh = await askWith(newCode);
      expect(fresh.statusCode, 200);
      expect((fresh.data as Map)['outcome'], 'accepted');
      expect((fresh.data as Map)['token'], secondToken,
          reason: 'a code peer is handed the token that is current');
    });

    test('a proof begun before the rotation cannot be finished after it',
        () async {
      final begun = await CodePake.begin(firstCode);
      final started = await dio().post(url(CodePake.startPath),
          data: {'pA': CodePake.encode(begun.share)});
      final answer = Map<String, dynamic>.from(started.data as Map);
      final keys = await CodePake.complete(
        begun,
        senderShare: CodePake.decode(answer['pB'], length: Spake2.shareLength)!,
        certFingerprint: server.tlsFingerprint!,
      );

      // Mid-exchange the code is replaced.
      expect(rotate(secondToken, SessionCode.generate()), isTrue);

      final finished = await dio().post(url('/v2/invite/request'), data: {
        'pakeId': answer['pakeId'],
        'cA': CodePake.encode(keys.confirmationA),
        'deviceName': 'Test Laptop',
      });
      expect(finished.statusCode, 403,
          reason: 'a correct confirmation of the old code is still the old '
              'code');
    });

    test('rotating to a session that is not running changes nothing and says '
        'so', () async {
      await server.stop();
      expect(rotate(secondToken, SessionCode.generate()), isFalse);
      expect(server.isRunning, isFalse);
    });
  });

  group('what has been used', () {
    test('a token that has authenticated a request goes on working', () async {
      expect(await sessionStatus(firstToken), 200);

      expect(rotate(secondToken, SessionCode.generate()), isTrue);
      expect(await sessionStatus(firstToken), 200,
          reason: 'the receiver in the middle of a transfer holds this token');
      expect(await sessionStatus(secondToken), 200);
    });

    test('the token released to an approved code peer goes on working',
        () async {
      final response = await askWith(firstCode);
      expect((response.data as Map)['outcome'], 'accepted');
      final released = (response.data as Map)['token'] as String;
      expect(released, firstToken);

      expect(rotate(secondToken, SessionCode.generate()), isTrue);
      expect(rotate(thirdToken, SessionCode.generate()), isTrue);

      expect(await sessionStatus(released), 200,
          reason: 'approved by a person; stays valid until the session ends');
    });

    test('a token used and then rotated twice over still works, one that was '
        'never used does not', () async {
      expect(await sessionStatus(firstToken), 200);
      expect(rotate(secondToken, SessionCode.generate()), isTrue);
      // secondToken is never used.
      expect(rotate(thirdToken, SessionCode.generate()), isTrue);

      expect(await sessionStatus(firstToken), 200);
      expect(await sessionStatus(secondToken), 401);
      expect(await sessionStatus(thirdToken), 200);
    });

    test('nothing survives the end of the session', () async {
      expect(await sessionStatus(firstToken), 200);
      expect(rotate(secondToken, SessionCode.generate()), isTrue);

      await server.stop();
      port = await server.startQhtpSessionWhileIndexing(
        sessionId: 'next-session',
        index: Future.value(QhtpIndexerResult(
          manifest: manifest(),
          itemIdToAbsPathMap: {'item-1': '/tmp/file.txt'},
        )),
        authToken: thirdToken,
        sessionCode: SessionCode.generate(),
      );

      expect(await sessionStatus(firstToken), 401,
          reason: 'a token from a finished session opens nothing');
      expect(await sessionStatus(thirdToken), 200);
    });

    test('a finished transfer still closes every token', () async {
      expect(await sessionStatus(firstToken), 200);
      expect(rotate(secondToken, SessionCode.generate()), isTrue);
      expect(await sessionStatus(secondToken), 200);

      final done = await dio().post(url('/v2/session/complete'),
          options: Options(headers: {'Authorization': 'Bearer $secondToken'}));
      expect(done.statusCode, 200);

      expect(await sessionStatus(firstToken), 401);
      expect(await sessionStatus(secondToken), 401);
    });
  });

  group('the comparison', () {
    test('a token that differs from the current one in its last character, or '
        'only by length, is refused', () async {
      expect(rotate(secondToken, SessionCode.generate()), isTrue);

      final nearly = '${secondToken.substring(0, secondToken.length - 1)}c';
      expect(await sessionStatus(nearly), 401);
      expect(await sessionStatus(secondToken.substring(1)), 401);
      expect(await sessionStatus('${secondToken}b'), 401);
      expect(await sessionStatus(''), 401);
    });

    test('a request with no token at all is refused', () async {
      final r = await dio().get(url('/v2/session'));
      expect(r.statusCode, 401);
    });
  });

  test('a rotation does not move the port or the certificate', () async {
    final fingerprint = server.tlsFingerprint;
    expect(rotate(secondToken, SessionCode.generate()), isTrue);

    expect(server.tlsFingerprint, fingerprint);
    expect(await sessionStatus(secondToken), 200,
        reason: 'same port, same pinned certificate, new secret');
  });

  test('a health check needs no token before or after', () async {
    expect(rotate(secondToken, SessionCode.generate()), isTrue);
    final r = await dio().get(url('/v2/health'));
    expect(r.statusCode, 200);
    expect(jsonDecode(r.data is String ? r.data as String : jsonEncode(r.data)),
        containsPair('protocol', 'QHTP'));
  });
}

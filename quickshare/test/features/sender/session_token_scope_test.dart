// What the session's bearer token is good for, and for how long.
//
// DD-19. Three ways the token was weaker than it read:
//
//  * `/info` was exempt from it, and `/info` is a name and a size — so
//    anyone on the network who guessed a port in 8000–9000 learned what was
//    being sent, with no code and no QR anywhere;
//  * a wrong token answered 403 while a missing one answered 401, which told
//    anybody probing the port which of the two they had;
//  * and nothing retired it, so it stayed good for the whole window between
//    the last byte and the server going away.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';

/// `LocalHttpServer` toggles the screen wakelock, which needs a platform
/// channel that doesn't exist under `flutter test`.
class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

void main() {
  setUpAll(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());

  late LocalHttpServer server;
  const token = 'the-session-token';

  setUp(() => server = LocalHttpServer());
  tearDown(() async => server.stop());

  QhtpManifest manifest() => QhtpManifest(
        sessionId: 'scope-session',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        itemCount: 1,
        totalBytes: 5,
        items: const [QhtpItem(id: '000001', path: 'holiday.mov', size: 5)],
      );

  /// A client that trusts this one session's certificate and nothing else,
  /// and never throws on a status — the status is what these tests read.
  Dio client(String fingerprint) => Dio(BaseOptions(
        validateStatus: (_) => true,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ))
        ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
          final c = HttpClient(context: SecurityContext(withTrustedRoots: false));
          c.badCertificateCallback =
              (cert, h, p) => SessionTlsIdentity.matches(cert, fingerprint);
          return c;
        });

  /// The v1 server, which is the only one that serves `/info` — the route
  /// this defect was found on.
  Future<(Dio, int)> legacySession() async {
    final port = await server.start(
      '/nonexistent/holiday.mov',
      'holiday.mov',
      'video/quicktime',
      5,
      token,
    );
    return (client(server.tlsFingerprint!), port);
  }

  Future<(Dio, int)> liveSession() async {
    final port = await server.startQhtpSession(
      manifest: manifest(),
      itemIdToAbsPathMap: const {'000001': '/nonexistent/holiday.mov'},
      authToken: token,
    );
    return (client(server.tlsFingerprint!), port);
  }

  Options bearer(String value) =>
      Options(headers: {'Authorization': 'Bearer $value'});

  group('what the token guards', () {
    test('the preview does not answer without it', () async {
      final (dio, port) = await legacySession();

      final res = await dio.get('https://127.0.0.1:$port/info');

      expect(res.statusCode, equals(401));
      expect('${res.data}', isNot(contains('holiday.mov')),
          reason: 'the refusal must not carry what it refused to hand over');
    });

    test('and answers with it', () async {
      final (dio, port) = await legacySession();

      final res =
          await dio.get('https://127.0.0.1:$port/info', options: bearer(token));

      expect(res.statusCode, equals(200));
    });

    test('the session itself does not answer without it', () async {
      final (dio, port) = await liveSession();

      final res = await dio.get('https://127.0.0.1:$port/v2/session');

      expect(res.statusCode, equals(401));
    });

    test('liveness answers to anyone, and says nothing about the session',
        () async {
      // The one exemption, and it is a fact about the protocol rather than
      // about what is being sent.
      final (dio, port) = await liveSession();

      final res = await dio.get('https://127.0.0.1:$port/v2/health');

      expect(res.statusCode, equals(200));
      expect('${res.data}', isNot(contains('holiday.mov')));
    });
  });

  group('a wrong token and a missing one', () {
    test('are answered the same way', () async {
      // They differed, and the difference told a prober which of the two
      // they had. Nothing here needs telling them apart.
      final (dio, port) = await liveSession();

      final missing = await dio.get('https://127.0.0.1:$port/v2/session');
      final wrong = await dio.get('https://127.0.0.1:$port/v2/session',
          options: bearer('not-the-token'));

      expect(missing.statusCode, equals(401));
      expect(wrong.statusCode, equals(401));
      expect('${wrong.data}', equals('${missing.data}'));
    });
  });

  group('once the receiver says it arrived', () {
    test('the token opens nothing further', () async {
      final (dio, port) = await liveSession();

      expect(
        (await dio.get('https://127.0.0.1:$port/v2/session',
                options: bearer(token)))
            .statusCode,
        equals(200),
        reason: 'good before',
      );

      await dio.post('https://127.0.0.1:$port/v2/session/complete',
          options: bearer(token));

      final after = await dio.get('https://127.0.0.1:$port/v2/session',
          options: bearer(token));
      expect(after.statusCode, equals(401));
    });

    test('but saying so again still works', () async {
      // The receiver retries this when the answer is lost. Turning a
      // delivered transfer into an error over a repeated acknowledgement
      // would be a worse bug than the one being closed.
      final (dio, port) = await liveSession();

      await dio.post('https://127.0.0.1:$port/v2/session/complete',
          options: bearer(token));
      final again = await dio.post(
          'https://127.0.0.1:$port/v2/session/complete',
          options: bearer(token));

      expect(again.statusCode, equals(200));
    });
  });
}

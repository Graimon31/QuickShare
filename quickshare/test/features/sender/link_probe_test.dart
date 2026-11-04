// What counts as "a receiver reached this server", and what counts as the
// route a transfer took.
//
// Two things read the server's idea of its first client:
//
//  * the direct-link ladder, which asks `waitForFirstClient` whether the
//    receiver really came across the link it just raised, before it declares
//    that link up;
//  * the transfer report, which names the address the bytes went to
//    (`lastClientAddress`) so a history entry can say which route carried them.
//
// Both used to be satisfied by anyone who could reach the port. The check ran
// before authentication, so one junk POST, with no token and no code, made a
// dead link look alive and put an arbitrary address into the report.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/network/session_tls_identity.dart';
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

  const token = 'the-session-token';
  late LocalHttpServer server;
  late Directory dir;
  late int port;
  late Dio dio;

  const shortWait = Duration(milliseconds: 80);

  setUp(() async {
    server = LocalHttpServer();
    dir = await Directory.systemTemp.createTemp('link_probe_');
    File('${dir.path}/hello.txt').writeAsStringSync('hello');
    port = await server.startQhtpSession(
      manifest: QhtpManifest(
        sessionId: 'probe-session',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        itemCount: 1,
        totalBytes: 5,
        items: const [QhtpItem(id: '000001', path: 'hello.txt', size: 5)],
      ),
      itemIdToAbsPathMap: {'000001': '${dir.path}/hello.txt'},
      authToken: token,
    );
    final fingerprint = server.tlsFingerprint!;
    dio = Dio(BaseOptions(
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
  });

  tearDown(() async {
    await server.stop();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String url(String path) => 'https://127.0.0.1:$port$path';
  Options bearer(String value) =>
      Options(headers: {'Authorization': 'Bearer $value'});

  /// Everything a stranger can send: no token, a wrong one, or junk at the two
  /// routes that are open on purpose.
  final strangers = <String, Future<Response<dynamic>> Function(Dio)>{
    'GET /v2/health': (d) => d.get(url('/v2/health')),
    'GET /v2/session, no token': (d) => d.get(url('/v2/session')),
    'GET /v2/session, wrong token': (d) =>
        d.get(url('/v2/session'), options: bearer('guess')),
    'GET /v2/manifest, no token': (d) => d.get(url('/v2/manifest')),
    'GET /v2/files/000001, no token': (d) => d.get(url('/v2/files/000001')),
    'GET /v2/files/000001, wrong token': (d) =>
        d.get(url('/v2/files/000001'), options: bearer('guess')),
    'GET /v2/files/000001/digest, no token': (d) =>
        d.get(url('/v2/files/000001/digest')),
    'POST /v2/session/complete, no token': (d) =>
        d.post(url('/v2/session/complete')),
    'POST /v2/invite/request, junk': (d) =>
        d.post(url('/v2/invite/request'), data: 'not json'),
    'POST /v2/invite/request, unknown exchange': (d) => d.post(
        url('/v2/invite/request'),
        data: jsonEncode({'pakeId': 'no-such-exchange', 'cA': 'AAAA'}),
        options: Options(contentType: Headers.jsonContentType)),
    'POST /v2/pake/start, junk': (d) =>
        d.post(url('/v2/pake/start'), data: 'not json'),
  };

  group('a stranger', () {
    for (final entry in strangers.entries) {
      test('${entry.key} is not a client of the link', () async {
        final res = await entry.value(dio);
        expect(res.statusCode, isNotNull, reason: 'the request was answered');

        expect(await server.waitForFirstClient(timeout: shortWait), isFalse,
            reason: 'a dead link must not read as alive');
      });

      test('${entry.key} does not become the route in the report', () async {
        await entry.value(dio);

        expect(server.lastClientAddress, isNull);
      });
    }
  });

  group('the session token', () {
    test('makes a request a client of the link', () async {
      final waiting =
          server.waitForFirstClient(timeout: const Duration(seconds: 5));

      final res = await dio.get(url('/v2/session'), options: bearer(token));

      expect(res.statusCode, 200);
      expect(await waiting, isTrue);
    });

    test('a client that was already there still counts when asked later',
        () async {
      await dio.get(url('/v2/manifest'), options: bearer(token));

      expect(await server.waitForFirstClient(timeout: shortWait), isTrue);
    });

    test('a refused stranger first does not stop the real receiver counting',
        () async {
      await dio.post(url('/v2/invite/request'), data: 'not json');
      expect(await server.waitForFirstClient(timeout: shortWait), isFalse);

      await dio.get(url('/v2/session'), options: bearer(token));

      expect(await server.waitForFirstClient(timeout: shortWait), isTrue);
    });
  });

  group('the route of a transfer', () {
    test('is the address that fetched a file with the token', () async {
      expect(server.lastClientAddress, isNull);

      final res = await dio.get<List<int>>(url('/v2/files/000001'),
          options: bearer(token).copyWith(responseType: ResponseType.bytes));

      expect(res.statusCode, 200);
      expect(utf8.decode(res.data!), 'hello');
      expect(server.lastClientAddress?.address, '127.0.0.1');
    });

    test('is not set by only reading the session or the manifest', () async {
      await dio.get(url('/v2/session'), options: bearer(token));
      await dio.get(url('/v2/manifest'), options: bearer(token));

      expect(server.lastClientAddress, isNull,
          reason: 'being a client is not the same as moving bytes');
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

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

  late LocalHttpServer server;
  const token = 'super-secret-128bit-auth-token';
  late SessionCode sessionCode;
  late int serverPort;

  QhtpManifest manifest() => QhtpManifest(
        sessionId: 'test-session',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        itemCount: 1,
        totalBytes: 100,
        items: const [QhtpItem(id: 'item-1', path: 'file.txt', size: 100)],
      );

  setUp(() async {
    server = LocalHttpServer();
    sessionCode = SessionCode.generate();
    serverPort = await server.startQhtpSessionWhileIndexing(
      sessionId: 'test-session',
      index: Future.value(QhtpIndexerResult(
        manifest: manifest(),
        itemIdToAbsPathMap: {'item-1': '/tmp/file.txt'},
      )),
      authToken: token,
      sessionPublicId: sessionCode.publicId,
    );
  });

  tearDown(() async => server.stop());

  Dio client(String fingerprint) => Dio(BaseOptions(
        validateStatus: (_) => true,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ))
        ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
          final c =
              HttpClient(context: SecurityContext(withTrustedRoots: false));
          c.badCertificateCallback =
              (cert, h, p) => SessionTlsIdentity.matches(cert, fingerprint);
          return c;
        });

  group('/v2/invite/request security', () {
    test('declined invite does NOT return token, fingerprint, or port', () async {
      server.onApprovalRequested = (req) async => false; // Sender declines

      final dio = client(server.tlsFingerprint!);
      final response = await dio.post(
        'https://127.0.0.1:$serverPort/v2/invite/request',
        data: {
          'code': sessionCode.code,
          'invitePort': 0,
        },
      );

      expect(response.statusCode, equals(200));
      final body = response.data is Map ? response.data as Map : jsonDecode(response.data.toString()) as Map;
      expect(body['outcome'], equals('declined'));
      expect(body.containsKey('token'), isFalse);
      expect(body.containsKey('tlsFingerprint'), isFalse);
      expect(body.containsKey('port'), isFalse);
      expect(body.containsKey('sessionId'), isFalse);
    });

    test('accepted invite returns token, fingerprint, and session details', () async {
      server.onApprovalRequested = (req) async => true; // Sender approves

      final dio = client(server.tlsFingerprint!);
      final response = await dio.post(
        'https://127.0.0.1:$serverPort/v2/invite/request',
        data: {
          'code': sessionCode.code,
          'invitePort': 0,
        },
      );

      expect(response.statusCode, equals(200));
      final body = response.data is Map ? response.data as Map : jsonDecode(response.data.toString()) as Map;
      expect(body['outcome'], equals('accepted'));
      expect(body['token'], equals(token));
      expect(body['tlsFingerprint'], equals(server.tlsFingerprint));
      expect(body['port'], equals(serverPort));
      expect(body['sessionId'], equals('test-session'));
    });

    test('invitePort: 0 declines when approver does not answer in time', () async {
      server.onApprovalRequested = (req) async {
        await Future.delayed(const Duration(milliseconds: 200));
        return false;
      };

      final dio = client(server.tlsFingerprint!);
      final response = await dio.post(
        'https://127.0.0.1:$serverPort/v2/invite/request',
        data: {
          'code': sessionCode.code,
          'invitePort': 0,
        },
      );

      expect(response.statusCode, equals(200));
      final body = response.data is Map ? response.data as Map : jsonDecode(response.data.toString()) as Map;
      expect(body['outcome'], equals('declined'));
      expect(body.containsKey('token'), isFalse);
    });

    test('declined invite enforces 60s cooldown for the same IP', () async {
      server.onApprovalRequested = (req) async => false;
      final dio = client(server.tlsFingerprint!);

      final firstResponse = await dio.post(
        'https://127.0.0.1:$serverPort/v2/invite/request',
        data: {
          'code': sessionCode.code,
          'invitePort': 0,
        },
      );
      expect(firstResponse.statusCode, equals(200));
      var body = firstResponse.data is Map
          ? firstResponse.data as Map
          : jsonDecode(firstResponse.data.toString()) as Map;
      expect(body['outcome'], equals('declined'));
      expect(body['detail'], equals('Transfer declined by sender'));

      // Second request immediately after decline should be rejected due to cooldown without calling onApprovalRequested
      var approvalCalled = false;
      server.onApprovalRequested = (req) async {
        approvalCalled = true;
        return true;
      };

      final secondResponse = await dio.post(
        'https://127.0.0.1:$serverPort/v2/invite/request',
        data: {
          'code': sessionCode.code,
          'invitePort': 0,
        },
      );
      expect(secondResponse.statusCode, equals(200));
      body = secondResponse.data is Map
          ? secondResponse.data as Map
          : jsonDecode(secondResponse.data.toString()) as Map;
      expect(body['outcome'], equals('declined'));
      expect(body['detail'], equals('cooldown'));
      expect(approvalCalled, isFalse);
    });

    test('rate limit triggers HTTP 429 after 5 attempts', () async {
      server.onApprovalRequested = (req) async => false;
      final dio = client(server.tlsFingerprint!);

      for (var i = 0; i < 5; i++) {
        final response = await dio.post(
          'https://127.0.0.1:$serverPort/v2/invite/request',
          data: {
            'code': sessionCode.code,
            'invitePort': 0,
          },
        );
        expect(response.statusCode, equals(200));
      }

      // 6th attempt within the same minute from the same IP must be rate-limited
      final rateLimitedResponse = await dio.post(
        'https://127.0.0.1:$serverPort/v2/invite/request',
        data: {
          'code': sessionCode.code,
          'invitePort': 0,
        },
      );
      expect(rateLimitedResponse.statusCode, equals(429));
      final body = rateLimitedResponse.data is Map
          ? rateLimitedResponse.data as Map
          : jsonDecode(rateLimitedResponse.data.toString()) as Map;
      expect(body['code'], equals('RATE_LIMITED'));
    });
  });
}

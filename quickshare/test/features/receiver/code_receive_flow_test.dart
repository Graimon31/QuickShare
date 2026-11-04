// B1 — what CodeReceivePage does with a typed code
// (lib/features/receiver/data/client/code_session_resolver.dart).
//
// The page used to carry this logic as private methods, and this file kept a
// line-for-line copy of one of them — so a regression in the page's own copy
// was invisible here. The logic now lives in `CodeSessionResolver`, which the
// page calls and these tests call, against a REAL `LocalHttpServer` on
// loopback. The page is left with nothing but turning an outcome into a
// message.
//
// What is checked here is the wire contract the page depends on: accepted and
// declined outcomes, the payload handed to `ReceiverBloc`, the health
// pre-filter, and the bound on an unreachable candidate. The security
// properties — who is trusted, and what an impostor is sent — are in
// `code_session_security_test.dart`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

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
        sessionId: 'code-flow-session',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        itemCount: 4,
        totalBytes: 555000,
        items: const [QhtpItem(id: 'item-1', path: 'file.txt', size: 555000)],
      );

  setUp(() async {
    server = LocalHttpServer();
    sessionCode = SessionCode.generate();
    serverPort = await server.startQhtpSessionWhileIndexing(
      sessionId: 'code-flow-session',
      index: Future.value(QhtpIndexerResult(
        manifest: manifest(),
        itemIdToAbsPathMap: {'item-1': '/tmp/file.txt'},
      )),
      authToken: token,
      sessionCode: sessionCode,
    );
  });

  tearDown(() async => server.stop());

  /// A resolver the way the page builds one, minus the presence service:
  /// [target] is the only place it looks.
  CodeSessionResolver resolverAt(InternetAddress address, int port) =>
      CodeSessionResolver(
        peers: () => const [],
        probeTargets: (_) async => [(address: address, port: port)],
        deviceName: 'test-device',
        discoveryWindow: Duration.zero,
      );

  group('B1 contract — accepted / declined', () {
    test(
        'accepted: builds the exact QRPayload the page would hand to '
        'ReceiverBloc, and it round-trips through encode/decode',
        () async {
      server.onApprovalRequested = (req) async => true;

      final outcome = await resolverAt(InternetAddress.loopbackIPv4, serverPort)
          .resolve(sessionCode);

      expect(outcome, isA<CodeSessionFound>());
      final payload = (outcome as CodeSessionFound).payload;
      expect(payload.mode, equals('http-lan'));
      expect(payload.version, equals(AppConstants.qhtpPayloadVersion));
      expect(payload.tlsFingerprint, equals(server.tlsFingerprint));
      expect(payload.token, equals(token));
      expect(payload.sessionId, equals('code-flow-session'));
      expect(payload.itemCount, equals(4));
      expect(payload.fileSize, equals(555000));
      expect(payload.ip, equals('127.0.0.1'));
      expect(payload.port, equals(serverPort));

      // This is exactly what the page does with the payload before handing it
      // to the bloc: `QRCodeScanned(payload.encode(), ...)`.
      final decoded = QRPayload.decode(payload.encode());
      expect(decoded.mode, equals('http-lan'));
      expect(decoded.tlsFingerprint, equals(server.tlsFingerprint));
      expect(decoded.token, equals(token));
      expect(decoded.itemCount, equals(4));
      expect(decoded.fileSize, equals(555000));
    });

    test(
        'declined: never fabricates a token, so the page has nothing to '
        'turn into a QRCodeScanned event',
        () async {
      server.onApprovalRequested = (req) async => false;

      final outcome = await resolverAt(InternetAddress.loopbackIPv4, serverPort)
          .resolve(sessionCode);

      expect(outcome, isA<CodeSessionDeclined>(),
          reason: 'a decline must never leave the resolver able to build a '
              'QRPayload — that is what "no QRCodeScanned" comes down to');
    });
  });

  group('B1 contract — health precheck', () {
    test(
        'a non-QHTP host is rejected by the health precheck before anything '
        'about the code or this device is sent',
        () async {
      final identity = SessionTlsIdentity.generate();
      final requests = <String>[];
      final rawServer = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        identity.securityContext,
      );
      addTearDown(() => rawServer.close(force: true));
      unawaited(rawServer.forEach((request) async {
        requests.add('${request.method} ${request.uri.path}');
        if (request.uri.path == '/v2/health') {
          request.response.headers.contentType = ContentType.json;
          // Answers, but not as QHTP — a captive portal or an unrelated
          // HTTPS service on the guessed candidate address/port, exactly
          // the case the precheck exists for.
          request.response.write(jsonEncode({'ok': true, 'protocol': 'NOT_QHTP'}));
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
        }
      }));

      final outcome =
          await resolverAt(InternetAddress.loopbackIPv4, rawServer.port)
              .resolve(sessionCode);

      expect(outcome, isA<CodeSessionNotFound>());
      expect(requests, equals(['GET /v2/health']),
          reason: 'a host that has not proved it speaks QHTP is not even '
              'asked to start the proof');
    });
  });

  group('B1 contract — unreachable', () {
    test('an unreachable candidate fails within its own timeout, not by hanging',
        () async {
      // A loopback port nothing is listening on: bind then immediately
      // release it, so the connection attempt gets a real ECONNREFUSED
      // rather than a firewall black hole.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      final stopwatch = Stopwatch()..start();
      final outcome = await resolverAt(InternetAddress.loopbackIPv4, deadPort)
          .resolve(sessionCode);
      stopwatch.stop();

      expect(outcome, isA<CodeSessionNotFound>());
      // Bounded well under the 95s the invite step alone allows, which is the
      // whole point — a dead candidate must not eat that.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'an unreachable candidate must fail fast, not hang');
    });
  });
}

// B1 — CodeReceivePage's `_startFromCode` / `_probeCandidate`
// (lib/features/receiver/presentation/pages/code_receive_page.dart:126-397).
//
// ============================================================================
// WHY THIS IS NOT A WIDGET TEST OF THE PAGE ITSELF — read before extending.
// ============================================================================
//
// `_startFromCode` first asks `AppPresence.instance.presence` for a
// `DiscoveredPeer` matching the typed code (app_presence.dart). That is a
// hard singleton: `AppPresence._presence` is a private field with no setter,
// `AppPresence._()` cannot be re-instantiated from a test in another
// library, and the only way it is ever populated is `AppPresence.start()`,
// which opens a real `DevicePresence` backed by the `nsd` mDNS plugin — a
// real platform channel with no implementation under headless `flutter
// test`. There is no seam here a test can use without changing lib/, which
// this task does not permit, so the "a discovered peer accepts" and "a
// discovered peer declines" branches of `_startFromCode` cannot be driven
// end-to-end from outside the app.
//
// What *is* true in every test process, untouched: `AppPresence.instance
// .presence` is null (nothing ever called `.start()`). Under that condition
// `_startFromCode` skips straight to its own fallback — probing candidate
// addresses directly over HTTP (`_probeCandidate`) — which touches no
// AppPresence state at all. But `_probeCandidate` is a private instance
// method on `_CodeReceivePageState`, so it cannot be called directly
// either.
//
// So below, `_probeCandidateContract` is a line-for-line reproduction of
// `_probeCandidate`'s algorithm (GET /v2/health pre-filter, POST
// /v2/invite/request, TLS pinning via `SessionTlsIdentity`, and the exact
// `QRPayload` fields the page builds from the response), run against a REAL
// `LocalHttpServer` on loopback — the same harness `invite_security_test.dart`
// uses. This exercises the true wire contract the page depends on: a
// regression in the server's `/v2/health` or `/v2/invite/request` shape, or
// in `QRPayload` itself, fails this file. A regression only in the page's
// own copy of this algorithm (a typo introduced only in
// code_receive_page.dart, say) would NOT be caught here — that gap is real,
// and is the point of writing this comment instead of pretending otherwise.
//
// A widget mount of the real `CodeReceivePage` was also attempted for the
// "not found" path (no peer, no reachable candidate) that doesn't need
// AppPresence to hold anything. It was dropped: `testWidgets` bodies run
// inside `flutter_test`'s `FakeAsync` zone, and driving them through a real
// socket/timeout dance needs `tester.runAsync` to escape it — extra
// machinery, on a network stack this project's own notes already flag as
// unusual (a permanent VPN forcing a symmetric-NAT-like path), for a case
// the contract tests below already cover more deterministically over
// loopback. Given the explicit instruction that B2-B4 landing solidly
// matters more than forcing B1, and the standing warning against real
// network calls that might hang on this machine, that trade was made in
// favour of the fast, deterministic tests below.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
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

/// A faithful reproduction of `_CodeReceivePageState._probeCandidate`
/// (code_receive_page.dart:321-397) — see the file header for why this is a
/// copy rather than a call into the real method.
///
/// Pre-filters on `GET /v2/health` before ever sending the code, exactly as
/// the production comment there explains: the probe path is a last resort
/// against unverified LAN hosts, so a host that cannot prove it is a QHTP
/// server never sees the code at all.
Future<QRPayload?> probeCandidateContract(
  InternetAddress address,
  int port,
  SessionCode code,
) async {
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
  client.connectionTimeout = const Duration(milliseconds: 1500);
  String? tlsFingerprint;
  client.badCertificateCallback = (X509Certificate cert, String host, int p) {
    tlsFingerprint = SessionTlsIdentity.fingerprintOf(cert.der);
    return true;
  };

  try {
    final healthUri = Uri.parse('https://${address.address}:$port/v2/health');
    final healthRequest =
        await client.getUrl(healthUri).timeout(const Duration(milliseconds: 1500));
    final healthResponse =
        await healthRequest.close().timeout(const Duration(milliseconds: 1500));
    if (healthResponse.statusCode != HttpStatus.ok) return null;
    final healthBody = await healthResponse.transform(utf8.decoder).join();
    try {
      final healthData = jsonDecode(healthBody) as Map<String, dynamic>;
      if (healthData['protocol'] != 'QHTP') return null;
    } catch (_) {
      return null;
    }

    final uri = Uri.parse('https://${address.address}:$port/v2/invite/request');
    final request =
        await client.postUrl(uri).timeout(const Duration(milliseconds: 1500));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'code': code.code,
      'invitePort': 0,
      'deviceName': 'test-device',
    }));
    final response = await request.close().timeout(const Duration(seconds: 95));
    if (response.statusCode == HttpStatus.ok && tlsFingerprint != null) {
      final bodyText = await response.transform(utf8.decoder).join();
      final data = jsonDecode(bodyText) as Map<String, dynamic>;
      if (data['outcome'] != 'accepted') return null;
      final token = data['token'] as String?;
      if (token != null && token.isNotEmpty) {
        return QRPayload(
          version: AppConstants.qhtpPayloadVersion,
          ip: address.address,
          port: port,
          token: token,
          sessionId: data['sessionId'] as String? ?? token,
          mode: 'http-lan',
          tlsFingerprint: tlsFingerprint!,
          itemCount: data['itemCount'] as int? ?? 1,
          fileSize: data['totalBytes'] as int? ?? 0,
          senderName: data['senderName'] as String?,
        );
      }
    }
  } catch (_) {
    // Not a matching QHTP server, or port unreachable / declined / timed out.
  } finally {
    client.close(force: true);
  }
  return null;
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
      sessionPublicId: sessionCode.publicId,
    );
  });

  tearDown(() async => server.stop());

  group('B1 contract — accepted / declined', () {
    test(
        'accepted: builds the exact QRPayload the page would hand to '
        'ReceiverBloc, and it round-trips through encode/decode',
        () async {
      server.onApprovalRequested = (req) async => true;

      final payload = await probeCandidateContract(
          InternetAddress.loopbackIPv4, serverPort, sessionCode);

      expect(payload, isNotNull);
      expect(payload!.mode, equals('http-lan'));
      expect(payload.tlsFingerprint, equals(server.tlsFingerprint));
      expect(payload.token, equals(token));
      expect(payload.sessionId, equals('code-flow-session'));
      expect(payload.itemCount, equals(4));
      expect(payload.fileSize, equals(555000));
      expect(payload.ip, equals('127.0.0.1'));
      expect(payload.port, equals(serverPort));

      // This is exactly what `_startFromCode` does with the payload before
      // handing it to the bloc: `QRCodeScanned(payload.encode(), ...)`.
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

      final payload = await probeCandidateContract(
          InternetAddress.loopbackIPv4, serverPort, sessionCode);

      expect(payload, isNull,
          reason: 'a decline must never leave the probe able to build a '
              'QRPayload — that is what "no QRCodeScanned" comes down to');
    });
  });

  group('B1 contract — health precheck', () {
    test(
        'a non-QHTP host is rejected by the health precheck before the code '
        'is ever sent',
        () async {
      final identity = SessionTlsIdentity.generate();
      var inviteWasHit = false;
      final rawServer = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        identity.securityContext,
      );
      addTearDown(() => rawServer.close(force: true));
      unawaited(rawServer.forEach((request) async {
        if (request.uri.path == '/v2/health') {
          request.response.headers.contentType = ContentType.json;
          // Answers, but not as QHTP — a captive portal or an unrelated
          // HTTPS service on the guessed candidate address/port, exactly
          // the case the precheck exists for.
          request.response.write(jsonEncode({'ok': true, 'protocol': 'NOT_QHTP'}));
          await request.response.close();
        } else if (request.uri.path == '/v2/invite/request') {
          inviteWasHit = true;
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      }));

      final payload = await probeCandidateContract(
          InternetAddress.loopbackIPv4, rawServer.port, sessionCode);

      expect(payload, isNull);
      expect(inviteWasHit, isFalse,
          reason: 'the 10-digit code must never be sent to a host that has '
              'not first proven it speaks QHTP');
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
      final payload = await probeCandidateContract(
          InternetAddress.loopbackIPv4, deadPort, sessionCode);
      stopwatch.stop();

      expect(payload, isNull);
      // _probeCandidate's own budget for this leg is a 1500ms connect
      // timeout; bounded well under the 95s the invite step alone allows,
      // which is the whole point — a dead candidate must not eat that.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'an unreachable candidate must fail fast, not hang');
    });
  });
}

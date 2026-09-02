// The manifest must not wait on background hashing.
//
// Gating `/v2/manifest` on the full session's digests put the entire SHA-256
// run between the QR scan and the first byte transferred — seconds of
// "connecting" for any session under the checksum budget. Digests now travel
// their own per-item endpoint, awaited only by a receiver that is about to
// verify that one item, long after hashing has finished it.
import 'dart:async';
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
  const token = 'digest-token';

  setUp(() => server = LocalHttpServer());
  tearDown(() async => server.stop());

  QhtpManifest manifest({String? sha256}) => QhtpManifest(
        sessionId: 'digest-session',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        itemCount: 1,
        totalBytes: 5,
        items: [
          QhtpItem(id: '000001', path: 'a.bin', size: 5, sha256: sha256),
        ],
      );

  Dio pinnedClient(String fingerprint) => Dio()
    ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
      final c = HttpClient(context: SecurityContext(withTrustedRoots: false));
      c.badCertificateCallback =
          (cert, h, p) => SessionTlsIdentity.matches(cert, fingerprint);
      return c;
    });

  final auth = Options(headers: {'Authorization': 'Bearer $token'});

  test('manifest answers while hashing is unresolved; the digest endpoint '
      'holds per item and answers when the digest lands', () async {
    final digestCompleter = Completer<String?>();
    final port = await server.startQhtpSession(
      manifest: manifest(),
      itemIdToAbsPathMap: const {'000001': '/nonexistent/a.bin'},
      authToken: token,
      checksums: {'000001': digestCompleter.future},
    );
    final dio = pinnedClient(server.tlsFingerprint!);

    // The completer is never resolved, so a gated manifest would hang this
    // GET forever. The timeout is the assertion, not a convenience.
    final manifestRes = await dio
        .get('https://127.0.0.1:$port/v2/manifest', options: auth)
        .timeout(const Duration(seconds: 3));
    final items = (manifestRes.data as Map<String, dynamic>)['items'] as List;
    expect(items.single['sha256'], isNull,
        reason: 'the manifest leaves before any digest exists');

    // The digest endpoint holds while its own item is unresolved.
    var digestAnswered = false;
    final digestFuture = dio
        .get('https://127.0.0.1:$port/v2/files/000001/digest', options: auth)
        .then((r) {
      digestAnswered = true;
      return r;
    });
    await Future.delayed(const Duration(milliseconds: 300));
    expect(digestAnswered, isFalse,
        reason: 'the digest endpoint waits for its item, not for the session');

    digestCompleter.complete('sha256:deadbeef');
    final digestRes = await digestFuture;
    expect(digestRes.statusCode, 200);
    expect((digestRes.data as Map<String, dynamic>)['sha256'],
        'sha256:deadbeef');
  });

  test('digest endpoint answers 204 when the session carries no hashing',
      () async {
    final port = await server.startQhtpSession(
      manifest: manifest(),
      itemIdToAbsPathMap: const {'000001': '/nonexistent/a.bin'},
      authToken: token,
    );
    final res = await pinnedClient(server.tlsFingerprint!)
        .get('https://127.0.0.1:$port/v2/files/000001/digest', options: auth);
    expect(res.statusCode, 204,
        reason: 'no digests promised — the receiver verifies by byte count');
  });

  test('digest endpoint answers from an inline manifest hash immediately',
      () async {
    final port = await server.startQhtpSession(
      manifest: manifest(sha256: 'sha256:inline'),
      itemIdToAbsPathMap: const {'000001': '/nonexistent/a.bin'},
      authToken: token,
    );
    final res = await pinnedClient(server.tlsFingerprint!)
        .get('https://127.0.0.1:$port/v2/files/000001/digest', options: auth);
    expect(res.statusCode, 200);
    expect((res.data as Map<String, dynamic>)['sha256'], 'sha256:inline');
  });
}

// A sender that stops answering must end the transfer, not freeze the screen.
//
// The receiver disabled dio's `receiveTimeout` so a long, healthy body could
// not be cut off mid-stream, and put a 30s idle timeout on the response body
// instead. But that timeout cannot start until the response headers arrive,
// and nothing guarded the wait for *those*. A sender that is suspended or
// wedged still lets the OS accept the TCP connection and then answers nothing,
// so the receiver waited on it forever — sitting on whatever screen it was
// showing, most often "verifying" when the break fell between two files.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

/// In-memory stand-in for [SessionStateStore]; path_provider has no platform
/// channel under `flutter test`.
class _InMemorySessionStateStore extends SessionStateStore {
  final Map<String, Map<String, QhtpItemState>> _states = {};

  @override
  Future<Map<String, QhtpItemState>?> loadState(String sessionId) async =>
      _states[sessionId];

  @override
  Future<void> saveState({
    required String sessionId,
    required String host,
    required int port,
    required String token,
    required String baseDir,
    required Map<String, QhtpItemState> items,
  }) async =>
      _states[sessionId] = Map.of(items);

  @override
  Future<void> deleteState(String sessionId) async => _states.remove(sessionId);
}

/// Answers the session and manifest requests, then goes silent on the file
/// body — the shape a suspended sender presents to the receiver.
Future<(HttpServer, String)> _startMuteFileServer() async {
  final tls = SessionTlsIdentity.generate();
  final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4, 0, tls.securityContext);
  // Held open deliberately: closing them would let the client fail fast, which
  // is the behaviour this test is asserting does *not* happen by accident.
  final stalled = <HttpRequest>[];
  addTearDown(() {
    for (final r in stalled) {
      try {
        r.response.close();
      } catch (_) {}
    }
  });

  server.listen((request) async {
    final path = request.uri.path;
    if (path == '/v2/session') {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'totalBytes': 1024, 'itemCount': 1}));
      await request.response.close();
      return;
    }
    if (path == '/v2/manifest') {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'protocol': 'QHTP',
          'protocolVersion': 1,
          'sessionId': 'stall-session',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'itemCount': 1,
          'totalBytes': 1024,
          'items': [
            {'id': 'item-1', 'path': 'stuck.bin', 'size': 1024},
          ],
        }));
      await request.response.close();
      return;
    }
    // The file body: accepted, then never answered.
    stalled.add(request);
  });

  return (server, tls.fingerprint);
}

void main() {
  late Directory targetDir;
  HttpServer? server;

  setUp(() async {
    targetDir = await Directory.systemTemp.createTemp('qhtp_stall_dst_');
  });

  tearDown(() async {
    await server?.close(force: true);
    server = null;
    if (await targetDir.exists()) await targetDir.delete(recursive: true);
  });

  test('a sender that accepts the connection and never answers fails the '
      'transfer instead of hanging forever', () async {
    final (muteServer, fingerprint) = await _startMuteFileServer();
    server = muteServer;

    // Shortened from the shipping 20s purely so this takes seconds: what is
    // under test is that the wait is bounded at all, not the size of the bound.
    final client = QhtpReceiverClient(
      store: _InMemorySessionStateStore(),
      responseHeaderTimeout: const Duration(seconds: 1),
    );

    final result = await client
        .downloadSession(
          payload: QRPayload(
            version: 2,
            ip: '127.0.0.1',
            port: server!.port,
            token: 'stall-token',
            sessionId: 'stall-session',
            mode: 'http-lan',
            tlsFingerprint: fingerprint,
          ),
          targetBaseDir: targetDir.path,
        )
        // Three attempts at the cap above, plus the 1s and 2s backoff between
        // them, is the worst case. Anything past this is the hang returning.
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () =>
              fail('downloadSession never returned — the stall guard is gone'),
        );

    expect(result.isLeft, isTrue,
        reason: 'a sender that never answers is a failed transfer');

    // Nothing may be published under its real name from a session that never
    // received a byte. The `.qs.partial` itself is left alone on purpose —
    // that is the anchor a resumed session picks up from.
    expect(File(p.join(targetDir.path, 'stuck.bin')).existsSync(), isFalse,
        reason: 'a failed item must not appear under its final name');
  }, timeout: const Timeout(Duration(seconds: 60)));
}

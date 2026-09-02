// A transfer must not report itself once per chunk.
//
// A chunk is 64 KB, so at any real speed that fired hundreds of times a
// second, and every one of them crossed into the bloc, emitted a state and
// rebuilt the screen on the receiving device. On a phone that is enough to
// saturate the isolate that also has to run the read loop: the reads fall
// behind, the sender stalls on a window that never opens, and the taps that
// would cancel it queue up behind a thousand progress updates. It is the
// same root cause as a Desktop→iOS transfer "hanging" and the receiver's
// screen not answering while it does.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

class _InMemoryStore extends SessionStateStore {
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

void main() {
  late Directory source;
  late Directory target;
  LocalHttpServer? server;

  setUpAll(() => wakelockPlusPlatformInstance = _FakeWakelock());

  setUp(() async {
    source = await Directory.systemTemp.createTemp('qhtp_throttle_src_');
    target = await Directory.systemTemp.createTemp('qhtp_throttle_dst_');
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    if (await source.exists()) await source.delete(recursive: true);
    if (await target.exists()) await target.delete(recursive: true);
  });

  test('a multi-megabyte transfer reports far fewer times than it has chunks',
      () async {
    // 24 MB is ~384 chunks of 64 KB. Unthrottled that is 384 reports; at ten
    // a second it is single digits for a transfer this quick.
    const size = 24 * 1024 * 1024;
    final rand = Random(11);
    await File(p.join(source.path, 'big.bin')).writeAsBytes(
        Uint8List.fromList(List.generate(size, (_) => rand.nextInt(256))));

    final indexed = await FileIndexer().buildResult(
      sessionId: 'throttle',
      paths: [source.path],
      includeChecksums: false,
    );

    server = LocalHttpServer();
    const token = 'throttle-token';
    final port = await server!.startQhtpSession(
      manifest: indexed.manifest,
      itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
      authToken: token,
    );
    final fingerprint = server!.tlsFingerprint!;

    final dio = Dio()
      ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
        final client =
            HttpClient(context: SecurityContext(withTrustedRoots: false));
        client.badCertificateCallback =
            (cert, host, port) => SessionTlsIdentity.matches(cert, fingerprint);
        return client;
      });

    final client =
        QhtpReceiverClient(dioClient: dio, store: _InMemoryStore());

    var transferringReports = 0;
    final result = await client.downloadSession(
      payload: QRPayload(
        version: 2,
        ip: '127.0.0.1',
        port: port,
        token: token,
        fileName: 'big.bin',
        fileSize: size,
        tlsFingerprint: fingerprint,
      ),
      targetBaseDir: target.path,
      onProgress: (progress) {
        if (progress.phase == 'transferring') transferringReports++;
      },
    );

    expect(result.isRight, isTrue, reason: 'the transfer itself must succeed');

    // The exact count depends on how fast the loopback runs; what matters is
    // that it is bounded by time rather than by chunk count.
    const chunksAtSixtyFourK = size ~/ (64 * 1024);
    expect(transferringReports, lessThan(chunksAtSixtyFourK ~/ 4),
        reason: 'reporting is throttled, not once per chunk '
            '($chunksAtSixtyFourK chunks in this transfer)');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the bytes still arrive intact under throttling', () async {
    final payload =
        Uint8List.fromList(List.generate(3 * 1024 * 1024, (i) => i % 251));
    await File(p.join(source.path, 'exact.bin')).writeAsBytes(payload);

    final indexed = await FileIndexer().buildResult(
      sessionId: 'throttle-integrity',
      paths: [source.path],
      includeChecksums: false,
    );

    server = LocalHttpServer();
    const token = 'throttle-integrity-token';
    final port = await server!.startQhtpSession(
      manifest: indexed.manifest,
      itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
      authToken: token,
    );
    final fingerprint = server!.tlsFingerprint!;

    final dio = Dio()
      ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
        final client =
            HttpClient(context: SecurityContext(withTrustedRoots: false));
        client.badCertificateCallback =
            (cert, host, port) => SessionTlsIdentity.matches(cert, fingerprint);
        return client;
      });

    await QhtpReceiverClient(dioClient: dio, store: _InMemoryStore())
        .downloadSession(
      payload: QRPayload(
        version: 2,
        ip: '127.0.0.1',
        port: port,
        token: token,
        fileName: 'exact.bin',
        fileSize: payload.length,
        tlsFingerprint: fingerprint,
      ),
      targetBaseDir: target.path,
    );

    final landed = File(p.join(
        target.path, p.basename(source.path), 'exact.bin'));
    expect(landed.existsSync(), isTrue,
        reason: 'periodic flushing must not lose the tail of a file');
    expect(landed.readAsBytesSync(), equals(payload));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

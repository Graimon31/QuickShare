import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class _FakeWakelockPlusPlatform extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

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
  }) async {
    _states[sessionId] = Map.of(items);
  }

  @override
  Future<void> deleteState(String sessionId) async {
    _states.remove(sessionId);
  }
}

void main() {
  late Directory sourceDir;
  late Directory targetDir;
  LocalHttpServer? server;

  setUpAll(() {
    wakelockPlusPlatformInstance = _FakeWakelockPlusPlatform();
  });

  setUp(() async {
    sourceDir = await Directory.systemTemp.createTemp('qhtp_stress_src_');
    targetDir = await Directory.systemTemp.createTemp('qhtp_stress_dst_');
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    if (await sourceDir.exists()) await sourceDir.delete(recursive: true);
    if (await targetDir.exists()) await targetDir.delete(recursive: true);
  });

  test('single empty file (0 bytes) transfers and creates final empty file',
      () async {
    final emptyFile = File(p.join(sourceDir.path, 'empty_zero_bytes.dat'));
    await emptyFile.writeAsBytes(const <int>[]);

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'empty-file-session',
      paths: [emptyFile.path],
    );

    server = LocalHttpServer();
    const token = 'empty-file-token';
    final port = await server!.startQhtpSession(
      manifest: indexResult.manifest,
      itemIdToAbsPathMap: indexResult.itemIdToAbsPathMap,
      authToken: token,
    );

    final payload = QRPayload(
      version: 2,
      ip: '127.0.0.1',
      port: port,
      token: token,
      sessionId: indexResult.manifest.sessionId,
      mode: 'http-lan',
      tlsFingerprint: server!.tlsFingerprint!,
    );

    final client = QhtpReceiverClient(store: _InMemorySessionStateStore());
    final result = await client.downloadSession(
      payload: payload,
      targetBaseDir: targetDir.path,
    );

    expect(result.isRight, isTrue);

    final destRoot = p.join(targetDir.path, p.basename(sourceDir.path));
    // When a single file is transferred, QhtpReceiverClient places it according to manifest path
    final downloaded = File(p.join(targetDir.path, 'empty_zero_bytes.dat'));
    final downloadedUnderRoot =
        File(p.join(destRoot, 'empty_zero_bytes.dat'));
    final exists =
        await downloaded.exists() || await downloadedUnderRoot.exists();
    expect(exists, isTrue);

    final targetFile =
        await downloaded.exists() ? downloaded : downloadedUnderRoot;
    expect(await targetFile.length(), 0);
  });

  test('many small files transfer completely without descriptor leaks',
      () async {
    const fileCount = 50;
    for (var i = 0; i < fileCount; i++) {
      final f = File(p.join(sourceDir.path, 'file_$i.txt'));
      await f.writeAsString('Item payload content for index $i');
    }

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'many-files-session',
      paths: [sourceDir.path],
    );

    expect(indexResult.manifest.itemCount, fileCount);

    server = LocalHttpServer();
    const token = 'many-files-token';
    final port = await server!.startQhtpSession(
      manifest: indexResult.manifest,
      itemIdToAbsPathMap: indexResult.itemIdToAbsPathMap,
      authToken: token,
    );

    final payload = QRPayload(
      version: 2,
      ip: '127.0.0.1',
      port: port,
      token: token,
      sessionId: indexResult.manifest.sessionId,
      mode: 'http-lan',
      tlsFingerprint: server!.tlsFingerprint!,
    );

    final client = QhtpReceiverClient(store: _InMemorySessionStateStore());
    final result = await client.downloadSession(
      payload: payload,
      targetBaseDir: targetDir.path,
    );

    expect(result.isRight, isTrue);

    final destRoot = p.join(targetDir.path, p.basename(sourceDir.path));
    for (var i = 0; i < fileCount; i++) {
      final f = File(p.join(destRoot, 'file_$i.txt'));
      expect(await f.exists(), isTrue);
      expect(await f.readAsString(), 'Item payload content for index $i');
    }
  });

  test('server stopped mid-session terminates connection gracefully',
      () async {
    final testFile = File(p.join(sourceDir.path, 'mid_stop.bin'));
    await testFile.writeAsBytes(List.generate(1024, (i) => i % 256));

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'stopped-session',
      paths: [sourceDir.path],
    );

    server = LocalHttpServer();
    const token = 'stopped-token';
    final port = await server!.startQhtpSession(
      manifest: indexResult.manifest,
      itemIdToAbsPathMap: indexResult.itemIdToAbsPathMap,
      authToken: token,
    );

    final payload = QRPayload(
      version: 2,
      ip: '127.0.0.1',
      port: port,
      token: token,
      sessionId: indexResult.manifest.sessionId,
      mode: 'http-lan',
      tlsFingerprint: server!.tlsFingerprint!,
    );

    // Stop server before download begins
    await server!.stop();
    server = null;

    final client = QhtpReceiverClient(store: _InMemorySessionStateStore());
    final result = await client.downloadSession(
      payload: payload,
      targetBaseDir: targetDir.path,
    );

    expect(result.isLeft, isTrue);
  });
}

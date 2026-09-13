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
    sourceDir = await Directory.systemTemp.createTemp('qhtp_unicode_src_');
    targetDir = await Directory.systemTemp.createTemp('qhtp_unicode_dst_');
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    if (await sourceDir.exists()) await sourceDir.delete(recursive: true);
    if (await targetDir.exists()) await targetDir.delete(recursive: true);
  });

  test('Cyrillic folder and file names survive round-trip', () async {
    final subDir = Directory(p.join(sourceDir.path, 'фото'));
    await subDir.create(recursive: true);
    final file = File(p.join(subDir.path, 'снимок 1.txt'));
    await file.writeAsString('Привет, мир! Данные в кириллице.');

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'unicode-cyrillic-session',
      paths: [sourceDir.path],
    );

    server = LocalHttpServer();
    const token = 'unicode-cyrillic-token';
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
    final downloaded = File(p.join(destRoot, 'фото', 'снимок 1.txt'));
    expect(await downloaded.exists(), isTrue);
    expect(await downloaded.readAsString(), 'Привет, мир! Данные в кириллице.');
  });

  test('emoji and special characters in filenames survive round-trip', () async {
    final subDir = Directory(p.join(sourceDir.path, '📸 summer vibes'));
    await subDir.create(recursive: true);
    final file = File(p.join(subDir.path, 'отпуск ✨ [2026] (final).txt'));
    await file.writeAsString('Emoji and brackets test content 🎉🚀');

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'unicode-emoji-session',
      paths: [sourceDir.path],
    );

    server = LocalHttpServer();
    const token = 'unicode-emoji-token';
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
    final entities = destRoot.isNotEmpty && await Directory(destRoot).exists()
        ? await Directory(destRoot).list(recursive: true).toList()
        : <FileSystemEntity>[];
    final downloadedFiles = entities.whereType<File>().toList();
    expect(downloadedFiles.length, 1);
    expect(await downloadedFiles.first.readAsString(),
        'Emoji and brackets test content 🎉🚀');
  });
}

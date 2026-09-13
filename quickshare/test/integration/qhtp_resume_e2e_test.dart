import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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

void main() {
  late Directory sourceDir;
  late Directory targetDir;
  late Directory stateDir;
  LocalHttpServer? server;

  setUpAll(() {
    wakelockPlusPlatformInstance = _FakeWakelockPlusPlatform();
  });

  setUp(() async {
    sourceDir = await Directory.systemTemp.createTemp('qhtp_resume_src_');
    targetDir = await Directory.systemTemp.createTemp('qhtp_resume_dst_');
    stateDir = await Directory.systemTemp.createTemp('qhtp_resume_state_');
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    if (await sourceDir.exists()) await sourceDir.delete(recursive: true);
    if (await targetDir.exists()) await targetDir.delete(recursive: true);
    if (await stateDir.exists()) await stateDir.delete(recursive: true);
  });

  test('interrupted download leaves .qs.partial and resumes seamlessly via Range',
      () async {
    final srcFile = File(p.join(sourceDir.path, 'video_resume.bin'));
    final rand = Random(12345);
    final bytes = Uint8List.fromList(
        List.generate(1024 * 1024, (_) => rand.nextInt(256)));
    await srcFile.writeAsBytes(bytes);

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'resume-range-session',
      paths: [sourceDir.path],
    );

    server = LocalHttpServer();
    const token = 'resume-range-token';
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

    // Pre-seed partial file with first 300 KB
    const partialBytesCount = 300 * 1024;
    final destRoot = p.join(targetDir.path, p.basename(sourceDir.path));
    final partialFile =
        File(p.join(destRoot, 'video_resume.bin.qs.partial'));
    await partialFile.create(recursive: true);
    await partialFile.writeAsBytes(bytes.sublist(0, partialBytesCount));

    final store = SessionStateStore(storeDirectory: stateDir.path);
    final observedRanges = <String?>[];
    final observedStatuses = <int>[];

    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onResponse: (response, handler) {
          observedStatuses.add(response.statusCode ?? -1);
          observedRanges
              .add(response.requestOptions.headers['Range'] as String?);
          handler.next(response);
        },
      ));

    final client = QhtpReceiverClient(dioClient: dio, store: store);
    final result = await client.downloadSession(
      payload: payload,
      targetBaseDir: targetDir.path,
    );

    expect(result.isRight, isTrue);

    // Verify 206 Partial Content was returned
    expect(observedStatuses, contains(206));
    expect(
        observedRanges
            .any((h) => h != null && h.startsWith('bytes=$partialBytesCount-')),
        isTrue);

    // Verify final file is intact
    final finalFile = File(p.join(destRoot, 'video_resume.bin'));
    expect(await finalFile.exists(), isTrue);
    expect(await finalFile.readAsBytes(), equals(bytes));

    // Verify .qs.partial is cleaned up
    expect(await partialFile.exists(), isFalse);
  });

  test('SessionStateStore lifecycle on real filesystem saves, loads, and deletes',
      () async {
    final store = SessionStateStore(storeDirectory: stateDir.path);
    const sessionId = 'test-session-persist-123';

    final items = {
      '000001': const QhtpItemState(
        id: '000001',
        path: 'photo.jpg',
        size: 2048,
        status: 'partial',
        partialBytes: 1024,
      ),
    };

    await store.saveState(
      sessionId: sessionId,
      host: '127.0.0.1',
      port: 8080,
      token: 'tok-abc',
      baseDir: '/tmp/test',
      items: items,
    );

    final loaded = await store.loadState(sessionId);
    expect(loaded, isNotNull);
    expect(loaded!['000001']?.path, 'photo.jpg');
    expect(loaded['000001']?.partialBytes, 1024);
    expect(loaded['000001']?.status, 'partial');

    await store.deleteState(sessionId);
    final afterDelete = await store.loadState(sessionId);
    expect(afterDelete, isNull);
  });
}

// Real-socket, real-filesystem end-to-end smoke test for QHTP v1.
//
// This is not a substitute for a real two-device test, but it drives the
// actual sender HTTP server and the actual receiver client over a real
// loopback TCP connection (no mocks on either side of the wire), so it
// verifies the protocol implementation genuinely round-trips: manifest
// fetch, sequential file transfer, HTTP Range resume, and the sender-side
// progress/completion signal.
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

/// `LocalHttpServer` toggles the screen wakelock, which needs a platform
/// channel that doesn't exist under `flutter test`. wakelock_plus exposes
/// this seam specifically so tests can swap in a no-op implementation.
class _FakeWakelockPlusPlatform extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

/// In-memory stand-in for [SessionStateStore] so tests don't depend on
/// path_provider's platform channel (unavailable under `flutter test`).
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
    sourceDir = await Directory.systemTemp.createTemp('qhtp_e2e_src_');
    targetDir = await Directory.systemTemp.createTemp('qhtp_e2e_dst_');
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    if (await sourceDir.exists()) await sourceDir.delete(recursive: true);
    if (await targetDir.exists()) await targetDir.delete(recursive: true);
  });

  test('full folder session transfers byte-for-byte over real loopback HTTP',
      () async {
    final readme = File(p.join(sourceDir.path, 'readme.txt'));
    await readme.writeAsString('hello qhtp');

    final emptyFile = File(p.join(sourceDir.path, 'empty.txt'));
    await emptyFile.writeAsBytes(const <int>[]);

    final subDir = Directory(p.join(sourceDir.path, 'sub'));
    await subDir.create();
    final bigFile = File(p.join(subDir.path, 'big.bin'));
    final rand = Random(42);
    final bigBytes = Uint8List.fromList(
        List.generate(3 * 1024 * 1024, (_) => rand.nextInt(256)));
    await bigFile.writeAsBytes(bigBytes);

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'e2e-session-full',
      paths: [sourceDir.path],
    );

    server = LocalHttpServer();
    const token = 'e2e-token-full';
    final port = await server!.startQhtpSession(
      manifest: indexResult.manifest,
      itemIdToAbsPathMap: indexResult.itemIdToAbsPathMap,
      authToken: token,
    );

    final senderProgress = <double>[];
    final progressSub = server!.transferProgress.listen(senderProgress.add);

    final payload = QRPayload(
      version: 2,
      ip: '127.0.0.1',
      port: port,
      token: token,
      sessionId: indexResult.manifest.sessionId,
      mode: 'http-lan',
    );

    final client = QhtpReceiverClient(store: _InMemorySessionStateStore());
    final phases = <String>[];
    final result = await client.downloadSession(
      payload: payload,
      targetBaseDir: targetDir.path,
      onProgress: (progress) => phases.add(progress.phase),
    );

    result.fold(
      (failure) => fail(
          'Expected successful QHTP session, got failure: ${failure.message}'),
      (_) {},
    );

    final destRoot = p.join(targetDir.path, p.basename(sourceDir.path));
    expect(await File(p.join(destRoot, 'readme.txt')).readAsString(),
        'hello qhtp');
    expect(await File(p.join(destRoot, 'empty.txt')).length(), 0);
    expect(await File(p.join(destRoot, 'sub', 'big.bin')).readAsBytes(),
        equals(bigBytes));

    expect(phases, containsAllInOrder(['connecting', 'manifest']));
    expect(phases.last, 'completed');

    // Regression check: sender must observe real progress and reach 1.0 via
    // the /v2/session/complete signal (previously local_http_server.dart
    // never emitted anything for QHTP sessions, so the sender UI could
    // never leave the "sending" screen).
    await Future.delayed(const Duration(milliseconds: 50));
    expect(senderProgress, isNotEmpty);
    expect(senderProgress.last, 1.0);

    await progressSub.cancel();
  });

  test(
      'resumes a partially-written item via HTTP Range and rejoins bytes correctly',
      () async {
    final dataDir = Directory(p.join(sourceDir.path, 'data'));
    await dataDir.create();
    final srcFile = File(p.join(dataDir.path, 'resume.bin'));
    final rand = Random(7);
    final bytes = Uint8List.fromList(
        List.generate(2 * 1024 * 1024, (_) => rand.nextInt(256)));
    await srcFile.writeAsBytes(bytes);

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'e2e-session-resume',
      paths: [sourceDir.path],
    );

    server = LocalHttpServer();
    const token = 'e2e-token-resume';
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
    );

    // Pre-seed a `.qs.partial` with the first half of the real bytes, as if
    // a previous attempt was interrupted mid-file.
    final destRoot = p.join(targetDir.path, p.basename(sourceDir.path));
    final partialPath = p.join(destRoot, 'data', 'resume.bin.qs.partial');
    await Directory(p.dirname(partialPath)).create(recursive: true);
    final half = bytes.length ~/ 2;
    await File(partialPath).writeAsBytes(bytes.sublist(0, half));

    final observedStatusCodes = <int>[];
    final observedRangeHeaders = <String?>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onResponse: (response, handler) {
          observedStatusCodes.add(response.statusCode ?? -1);
          observedRangeHeaders
              .add(response.requestOptions.headers['Range'] as String?);
          handler.next(response);
        },
      ));

    final client =
        QhtpReceiverClient(dioClient: dio, store: _InMemorySessionStateStore());
    final result = await client.downloadSession(
        payload: payload, targetBaseDir: targetDir.path);

    result.fold(
      (failure) =>
          fail('Expected successful resume, got failure: ${failure.message}'),
      (_) {},
    );

    // Proves an actual Range request went over the wire and the sender
    // replied 206, rather than silently re-downloading the whole file.
    expect(observedStatusCodes, contains(206));
    expect(
        observedRangeHeaders
            .any((h) => h != null && h.startsWith('bytes=$half-')),
        isTrue);

    final finalBytes =
        await File(p.join(destRoot, 'data', 'resume.bin')).readAsBytes();
    expect(finalBytes, equals(bytes));
  });

  test(
      'byte-counted progress never completes the session — only the receiver\'s POST does',
      () async {
    // The sender used to treat "bytes left the socket" as "transfer done"
    // and tore the session down while the receiver was still writing its
    // tail — the 98-100% hang. Retried Range requests also count their
    // bytes twice, so the counter can reach the total *before* the receiver
    // has a single complete file. Only POST /v2/session/complete may take
    // the sender's progress to 1.0.
    final payloadFile = File(p.join(sourceDir.path, 'photo.jpg'));
    await payloadFile.writeAsBytes(
        Uint8List.fromList(List.generate(512 * 1024, (i) => i % 256)));

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'e2e-session-cap',
      paths: [payloadFile.path],
    );

    server = LocalHttpServer();
    const token = 'e2e-token-cap';
    final port = await server!.startQhtpSession(
      manifest: indexResult.manifest,
      itemIdToAbsPathMap: indexResult.itemIdToAbsPathMap,
      authToken: token,
    );

    final senderProgress = <double>[];
    final progressSub = server!.transferProgress.listen(senderProgress.add);

    final dio = Dio();
    final auth = Options(headers: {'Authorization': 'Bearer $token'});

    // Download the item directly, bypassing QhtpReceiverClient so nothing
    // sends the completion POST before this test says so.
    final item = indexResult.manifest.items.single;
    final response = await dio.get<ResponseBody>(
      'http://127.0.0.1:$port/v2/files/${item.id}',
      options: auth.copyWith(responseType: ResponseType.stream),
    );
    await response.data!.stream
        .fold<int>(0, (sum, chunk) => sum + chunk.length);

    await Future.delayed(const Duration(milliseconds: 50));
    expect(senderProgress, isNotEmpty);
    expect(senderProgress.every((v) => v < 1.0), isTrue,
        reason: 'every byte left the socket, yet nothing proves the '
            'receiver has them — progress must hold below 1.0');

    await dio.post(
      'http://127.0.0.1:$port/v2/session/complete',
      data: {
        'sessionId': indexResult.manifest.sessionId,
        'receivedItems': 1,
        'receivedBytes': indexResult.manifest.totalBytes,
        'failedItems': 0,
      },
      options: auth,
    );

    await Future.delayed(const Duration(milliseconds: 50));
    expect(senderProgress.last, 1.0,
        reason: 'the receiver\'s completion POST is the one signal that '
            'releases the sender');

    await progressSub.cancel();
  });

  test('an existing file in the destination is never overwritten', () async {
    // A sender that names its file to match one the user already has must not
    // replace it — the received copy lands beside it as `name (1).ext`.
    final srcFile = File(p.join(sourceDir.path, 'report.pdf'));
    await srcFile.writeAsString('the freshly sent version');

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'e2e-session-noclobber',
      paths: [srcFile.path],
    );

    server = LocalHttpServer();
    const token = 'e2e-token-noclobber';
    final port = await server!.startQhtpSession(
      manifest: indexResult.manifest,
      itemIdToAbsPathMap: indexResult.itemIdToAbsPathMap,
      authToken: token,
    );

    // The user's own file, already sitting where the transfer would land.
    final existing = File(p.join(targetDir.path, 'report.pdf'));
    await existing.writeAsString('the original the user wants kept');

    final result = await QhtpReceiverClient(store: _InMemorySessionStateStore())
        .downloadSession(payload: QRPayload(
          version: 2,
          ip: '127.0.0.1',
          port: port,
          token: token,
          sessionId: indexResult.manifest.sessionId,
          mode: 'http-lan',
        ), targetBaseDir: targetDir.path);

    expect(result.isRight, isTrue);
    expect(await existing.readAsString(), 'the original the user wants kept',
        reason: 'the pre-existing file is untouched');
    expect(await File(p.join(targetDir.path, 'report (1).pdf')).readAsString(),
        'the freshly sent version',
        reason: 'the received copy lands under a free name');
  });
}

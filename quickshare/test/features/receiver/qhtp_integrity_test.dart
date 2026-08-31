// Integrity of a received QHTP item: does a truncated or corrupted transfer
// actually get rejected, rather than renamed into place and reported done?
//
// Drives the real receiver client against the real sender server over loopback,
// with a Dio interceptor standing in for the ways a transfer goes wrong on a
// bad network.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

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
  final _states = <String, Map<String, QhtpItemState>>{};

  @override
  Future<Map<String, QhtpItemState>?> loadState(String id) async => _states[id];

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
  Future<void> deleteState(String id) async => _states.remove(id);
}

void main() {
  setUpAll(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());

  late Directory source;
  late Directory destination;
  late LocalHttpServer server;
  late int port;
  const token = 'integrity-token';

  Future<QRPayload> serve(Map<String, List<int>> files) async {
    for (final entry in files.entries) {
      File(p.join(source.path, entry.key)).writeAsBytesSync(entry.value);
    }
    final indexed = await FileIndexer()
        .buildResult(sessionId: 'integrity', paths: [source.path]);
    port = await server.startQhtpSession(
      manifest: indexed.manifest,
      itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
      authToken: token,
    );
    return QRPayload(
      version: 2,
      ip: '127.0.0.1',
      port: port,
      token: token,
      sessionId: 'integrity',
      mode: 'http-lan',
      tlsFingerprint: server.tlsFingerprint!,
    );
  }

  setUp(() {
    source = Directory.systemTemp.createTempSync('qs_src_');
    destination = Directory.systemTemp.createTempSync('qs_dst_');
    server = LocalHttpServer();
  });

  tearDown(() async {
    await server.stop();
    source.deleteSync(recursive: true);
    destination.deleteSync(recursive: true);
  });

  test('indexer publishes a checksum for an ordinary session', () async {
    File(p.join(source.path, 'a.bin')).writeAsBytesSync([1, 2, 3, 4, 5]);
    final indexed = await FileIndexer()
        .buildResult(sessionId: 's', paths: [source.path]);

    final item = indexed.manifest.items.single;
    expect(item.sha256, isNotNull);
    expect(item.sha256, startsWith('sha256:'));
    // Survives the JSON round trip the manifest actually travels through.
    expect(indexed.manifest.toJson()['items'], isA<List<dynamic>>());
  });

  test('a clean transfer verifies and lands in place', () async {
    final payload = await serve({
      'clean.bin': List<int>.generate(40000, (i) => i % 256),
    });

    final result = await QhtpReceiverClient(store: _InMemoryStore())
        .downloadSession(payload: payload, targetBaseDir: destination.path);

    expect(result.isRight, isTrue, reason: 'clean transfer should succeed');
    final received =
        File(p.join(destination.path, p.basename(source.path), 'clean.bin'));
    expect(received.existsSync(), isTrue);
    expect(received.lengthSync(), equals(40000));
    expect(
      Directory(destination.path)
          .listSync(recursive: true)
          .where((e) => e.path.endsWith('.qs.partial')),
      isEmpty,
      reason: 'no partial should be left behind',
    );
  });

  test('a corrupted body is rejected instead of being renamed into place',
      () async {
    final payload = await serve({
      'corrupt.bin': List<int>.generate(20000, (i) => i % 256),
    });

    // Flip one byte in flight: the length still matches, so only the checksum
    // can catch this. Before the fix the file was renamed and marked complete.
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onResponse: (response, handler) {
          final body = response.data;
          if (body is ResponseBody &&
              response.requestOptions.path.contains('/v2/files/')) {
            var first = true;
            response.data = ResponseBody(
              body.stream.map((chunk) {
                if (!first || chunk.isEmpty) return chunk;
                first = false;
                final copy = Uint8List.fromList(chunk);
                copy[0] = copy[0] ^ 0xFF;
                return copy;
              }),
              body.statusCode,
              headers: body.headers,
            );
          }
          handler.next(response);
        },
      ));

    final result =
        await QhtpReceiverClient(dioClient: dio, store: _InMemoryStore())
            .downloadSession(payload: payload, targetBaseDir: destination.path);

    expect(result.isRight, isFalse, reason: 'corruption must fail the session');
    final received =
        File(p.join(destination.path, p.basename(source.path), 'corrupt.bin'));
    expect(received.existsSync(), isFalse,
        reason: 'a file that failed verification must not be published');
  });

  test('no .qs.partial survives a failed session', () async {
    final payload = await serve({
      'corrupt2.bin': List<int>.generate(20000, (i) => i % 256),
    });

    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onResponse: (response, handler) {
          final body = response.data;
          if (body is ResponseBody &&
              response.requestOptions.path.contains('/v2/files/')) {
            var first = true;
            response.data = ResponseBody(
              body.stream.map((chunk) {
                if (!first || chunk.isEmpty) return chunk;
                first = false;
                final copy = Uint8List.fromList(chunk);
                copy[0] = copy[0] ^ 0xFF;
                return copy;
              }),
              body.statusCode,
              headers: body.headers,
            );
          }
          handler.next(response);
        },
      ));

    await QhtpReceiverClient(dioClient: dio, store: _InMemoryStore())
        .downloadSession(payload: payload, targetBaseDir: destination.path);

    // Each retry deletes the bad partial before starting over, so nothing is
    // left for a later session to resume onto.
    final leftovers = Directory(destination.path)
        .listSync(recursive: true)
        .where((e) => e.path.endsWith('.qs.partial'))
        .toList();
    expect(leftovers, isEmpty);
  });
}

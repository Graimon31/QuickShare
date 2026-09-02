// A user cancelling mid-transfer used to leave the receiver's socket read
// sitting on a 30-second idle timeout before it noticed anything was wrong —
// the server's default graceful close lets an *active* response keep
// streaming, which is right for a transfer finishing on its own but wrong
// for one the user just told to stop. `stop(force: true)` exists for that
// second case; this drives a real loopback download and proves the
// receiving side notices within a couple of seconds, not thirty.
import 'dart:async';
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
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';

class _FakeWakelockPlusPlatform extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

void main() {
  late Directory sourceDir;
  LocalHttpServer? server;

  setUpAll(() {
    wakelockPlusPlatformInstance = _FakeWakelockPlusPlatform();
  });

  setUp(() async {
    sourceDir = await Directory.systemTemp.createTemp('qhtp_cancel_src_');
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    if (await sourceDir.exists()) await sourceDir.delete(recursive: true);
  });

  test(
      'stop(force: true) breaks an in-flight download within seconds, not '
      'the receiver\'s 30s idle timeout', () async {
    // Big enough that it is still streaming, not finished, when the test
    // cancels it a few chunks in.
    final bigFile = File(p.join(sourceDir.path, 'big.bin'));
    final rand = Random(7);
    await bigFile.writeAsBytes(
        Uint8List.fromList(List.generate(64 * 1024 * 1024, (_) => rand.nextInt(256))));

    final indexResult = await FileIndexer().buildResult(
      sessionId: 'cancel-test',
      paths: [bigFile.path],
      includeChecksums: false,
    );

    server = LocalHttpServer();
    const token = 'cancel-test-token';
    final port = await server!.startQhtpSession(
      manifest: indexResult.manifest,
      itemIdToAbsPathMap: indexResult.itemIdToAbsPathMap,
      authToken: token,
    );

    final fingerprint = server!.tlsFingerprint!;
    final dio = Dio()
      ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
        final c = HttpClient(context: SecurityContext(withTrustedRoots: false));
        c.badCertificateCallback =
            (cert, h, p) => SessionTlsIdentity.matches(cert, fingerprint);
        return c;
      });

    final item = indexResult.manifest.items.single;
    final response = await dio.get<ResponseBody>(
      'https://127.0.0.1:$port/v2/files/${item.id}',
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        responseType: ResponseType.stream,
      ),
    );

    var received = 0;
    final streamDone = Completer<void>();
    late final StreamSubscription<Uint8List> sub;
    sub = response.data!.stream.listen(
      (chunk) {
        received += chunk.length;
        // Cancel as soon as the transfer is genuinely under way — not on
        // the very first chunk, so this is a real mid-transfer cancel and
        // not a race with the response headers.
        if (received > 2 * 1024 * 1024 && !streamDone.isCompleted) {
          server!.stop(force: true);
        }
      },
      onDone: () {
        if (!streamDone.isCompleted) streamDone.complete();
      },
      onError: (Object e) {
        if (!streamDone.isCompleted) streamDone.completeError(e);
      },
    );
    addTearDown(sub.cancel);

    final sw = Stopwatch()..start();
    var brokeQuickly = false;
    try {
      await streamDone.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      brokeQuickly = false;
    } catch (_) {
      // Any stream-level error (connection reset/closed) is exactly the
      // fast failure this is testing for.
      brokeQuickly = true;
    }
    if (!streamDone.isCompleted) brokeQuickly = false;

    expect(brokeQuickly, isTrue,
        reason: 'a forced stop should sever the socket almost immediately, '
            'not leave the receiver waiting');
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(received, lessThan(64 * 1024 * 1024),
        reason: 'the transfer must not have been allowed to complete');
  });
}

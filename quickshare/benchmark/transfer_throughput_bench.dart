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

void main() {
  setUpAll(() => wakelockPlusPlatformInstance = _FakeWakelock());
  test('loopback throughput', () async {
    final source = await Directory.systemTemp.createTemp('bench_src_');
    final target = await Directory.systemTemp.createTemp('bench_dst_');
    const size = 400 * 1024 * 1024;
    final rand = Random(3);
    final buf = Uint8List(1 << 20);
    for (var i = 0; i < buf.length; i++) {
      buf[i] = rand.nextInt(256);
    }
    final f = File(p.join(source.path, 'big.bin'));
    final sink = f.openWrite();
    for (var i = 0; i < size ~/ buf.length; i++) {
      sink.add(buf);
    }
    await sink.flush();
    await sink.close();

    final indexed = await FileIndexer().buildResult(
        sessionId: 'b', paths: [source.path], includeChecksums: false);
    final server = LocalHttpServer();
    final port = await server.startQhtpSession(
        manifest: indexed.manifest,
        itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
        authToken: 't');
    final fp = server.tlsFingerprint!;
    final dio = Dio()
      ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
        final c = HttpClient(context: SecurityContext(withTrustedRoots: false));
        c.badCertificateCallback =
            (cert, h, pp) => SessionTlsIdentity.matches(cert, fp);
        return c;
      });
    final sw = Stopwatch()..start();
    final res =
        await QhtpReceiverClient(dioClient: dio, store: SessionStateStore())
            .downloadSession(
      payload: QRPayload(
          version: 2,
          ip: '127.0.0.1',
          port: port,
          token: 't',
          fileName: 'big.bin',
          fileSize: size,
          tlsFingerprint: fp),
      targetBaseDir: target.path,
    );
    sw.stop();
    res.fold((l) => print('BENCH FAILURE: ${l.message}'), (r) {
      final mbps = size / sw.elapsedMilliseconds * 1000 / (1024 * 1024);
      print('BENCH: ${size ~/ (1024 * 1024)} MB in ${sw.elapsedMilliseconds}ms '
          '= ${mbps.toStringAsFixed(1)} MB/s '
          '= ${(mbps * 8).toStringAsFixed(0)} Mbit/s');
    });
    await server.stop();
    await source.delete(recursive: true);
    await target.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

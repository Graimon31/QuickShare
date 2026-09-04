import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:path/path.dart' as pp;
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

void main() {
  test('sha256 throughput', () {
    final buf = Uint8List(1 << 20);
    final sink = AccumulatorSink<Digest>();
    final h = sha256.startChunkedConversion(sink);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 200; i++) {
      h.add(buf);
    }
    h.close();
    sw.stop();
    print('MICRO sha256: 200 MB in ${sw.elapsedMilliseconds}ms = '
        '${(200 / sw.elapsedMilliseconds * 1000).toStringAsFixed(0)} MB/s');
  });

  test('plain TLS socket throughput', () async {
    final tls = SessionTlsIdentity.generate();
    final server = await SecureServerSocket.bind(
        '127.0.0.1', 0, tls.securityContext);
    const total = 400 * 1024 * 1024;
    final block = Uint8List(1 << 20);
    server.listen((s) async {
      for (var i = 0; i < total ~/ block.length; i++) {
        s.add(block);
      }
      await s.flush();
      await s.close();
    });
    final sw = Stopwatch()..start();
    final client = await SecureSocket.connect('127.0.0.1', server.port,
        onBadCertificate: (_) => true);
    var got = 0;
    await for (final chunk in client) {
      got += chunk.length;
    }
    sw.stop();
    print('MICRO tls: $got bytes in ${sw.elapsedMilliseconds}ms = '
        '${(got / sw.elapsedMilliseconds * 1000 / (1 << 20)).toStringAsFixed(0)} MB/s');
    await server.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('plain TCP socket throughput', () async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    const total = 400 * 1024 * 1024;
    final block = Uint8List(1 << 20);
    server.listen((s) async {
      for (var i = 0; i < total ~/ block.length; i++) {
        s.add(block);
      }
      await s.flush();
      await s.close();
    });
    final sw = Stopwatch()..start();
    final client = await Socket.connect('127.0.0.1', server.port);
    var got = 0;
    await for (final chunk in client) {
      got += chunk.length;
    }
    sw.stop();
    print('MICRO tcp: $got bytes in ${sw.elapsedMilliseconds}ms = '
        '${(got / sw.elapsedMilliseconds * 1000 / (1 << 20)).toStringAsFixed(0)} MB/s');
    await server.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('parallel TLS throughput', () async {
    for (final n in [1, 2, 4, 8]) {
      final tls = SessionTlsIdentity.generate();
      final server =
          await SecureServerSocket.bind('127.0.0.1', 0, tls.securityContext);
      const per = 100 * 1024 * 1024;
      final block = Uint8List(1 << 20);
      server.listen((s) async {
        for (var i = 0; i < per ~/ block.length; i++) {
          s.add(block);
        }
        await s.flush();
        await s.close();
      });
      final sw = Stopwatch()..start();
      final futures = <Future<int>>[];
      for (var i = 0; i < n; i++) {
        futures.add(() async {
          final c = await SecureSocket.connect('127.0.0.1', server.port,
              onBadCertificate: (_) => true);
          var got = 0;
          await for (final chunk in c) {
            got += chunk.length;
          }
          return got;
        }());
      }
      final totals = await Future.wait(futures);
      sw.stop();
      final bytes = totals.fold<int>(0, (a, b) => a + b);
      print('MICRO tls x$n: ${(bytes / sw.elapsedMilliseconds * 1000 / (1 << 20)).toStringAsFixed(0)} MB/s aggregate');
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('dart HttpServer/HttpClient over TLS', () async {
    final tls = SessionTlsIdentity.generate();
    final server =
        await HttpServer.bindSecure('127.0.0.1', 0, tls.securityContext);
    const total = 400 * 1024 * 1024;
    final block = Uint8List(1 << 20);
    server.listen((req) async {
      req.response.headers.contentLength = total;
      for (var i = 0; i < total ~/ block.length; i++) {
        req.response.add(block);
      }
      await req.response.close();
    });
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (c, h, p) => true;
    final sw = Stopwatch()..start();
    final res = await (await client.getUrl(
            Uri.parse('https://127.0.0.1:${server.port}/'))) 
        .close();
    var got = 0;
    await for (final chunk in res) {
      got += chunk.length;
    }
    sw.stop();
    print('MICRO http-tls: ${(got / sw.elapsedMilliseconds * 1000 / (1 << 20)).toStringAsFixed(1)} MB/s');
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('QHTP shelf server read by a raw HttpClient', () async {
    wakelockPlusPlatformInstance = _FakeWakelock();
    final dir = await Directory.systemTemp.createTemp('micro_shelf_');
    const total = 400 * 1024 * 1024;
    final block = Uint8List(1 << 20);
    final f = File(pp.join(dir.path, 'big.bin'));
    final sink = f.openWrite();
    for (var i = 0; i < total ~/ block.length; i++) {
      sink.add(block);
    }
    await sink.flush();
    await sink.close();

    final indexed = await FileIndexer()
        .buildResult(sessionId: 'm', paths: [f.path], includeChecksums: false);
    final server = LocalHttpServer();
    final port = await server.startQhtpSession(
        manifest: indexed.manifest,
        itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
        authToken: 't');
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (c, h, p) => true;
    final sw = Stopwatch()..start();
    final req = await client
        .getUrl(Uri.parse('https://127.0.0.1:$port/v2/files/000001'));
    req.headers.set('Authorization', 'Bearer t');
    final res = await req.close();
    var got = 0;
    await for (final chunk in res) {
      got += chunk.length;
    }
    sw.stop();
    print('MICRO shelf-serve: ${(got / sw.elapsedMilliseconds * 1000 / (1 << 20)).toStringAsFixed(1)} MB/s');
    await server.stop();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
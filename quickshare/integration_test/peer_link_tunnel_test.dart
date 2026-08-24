// Does the peer-to-peer link actually carry a QHTP session?
//
//     flutter test integration_test/peer_link_tunnel_test.dart -d macos
//
// Both roles run on one machine on purpose. The radio is not what is being
// checked here — the plumbing is: that `host` forwards a peer to the QHTP
// port, that `join` hands back a localhost port reaching it, and that a whole
// transfer survives the round trip byte for byte. A second device adds the
// one thing this cannot cover (the Wi-Fi link itself) and a great deal that
// would obscure a plumbing bug.
//
// The point of the design is what this test demonstrates: QHTP is untouched.
// It serves on a port and dials a port, exactly as before.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const cache = TransferCache();
  const link = PeerLinkService();

  late Directory source;
  LocalHttpServer? server;
  final staged = <String>[];

  setUp(() async {
    source = await Directory.systemTemp.createTemp('dd_peer_src_');
  });

  tearDown(() async {
    await link.stop();
    await server?.stop();
    server = null;
    if (await source.exists()) await source.delete(recursive: true);
    await cache.discard(staged);
    staged.clear();
  });

  File write(String name, int megabytes) {
    final random = Random(name.hashCode);
    final block = Uint8List(1024 * 1024);
    for (var i = 0; i < block.length; i++) {
      block[i] = random.nextInt(256);
    }
    final file = File(p.join(source.path, name));
    final sink = file.openSync(mode: FileMode.write);
    for (var i = 0; i < megabytes; i++) {
      sink.writeFromSync(block);
    }
    sink.closeSync();
    return file;
  }

  testWidgets('a QHTP session travels the tunnel unchanged', (tester) async {
    expect(PeerLinkService.isSupported, isTrue,
        reason: 'this test only means anything on an Apple platform');

    const sizeMb = 64;
    final payload = write('clip.mp4', sizeMb);

    // ---- sender: an ordinary QHTP server, unaware of any of this ----
    final indexed = await FileIndexer()
        .buildResult(sessionId: 'peerlink-e2e', paths: [payload.path]);
    server = LocalHttpServer();
    const token = 'peerlink-token';
    final qhtpPort = await server!.startQhtpSession(
      manifest: indexed.manifest,
      itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
      authToken: token,
    );

    // ---- the link ----
    const serviceName = 'dd-test-${'peerlink'}';
    await link.host(serviceName: serviceName, localPort: qhtpPort);
    final localPort = await link.join(serviceName: serviceName);

    expect(localPort, isNot(equals(qhtpPort)),
        reason: 'the tunnel end is its own port, not the server itself');
    print('QHTP on :$qhtpPort, reachable through the link on :$localPort');

    // ---- receiver: the existing client, dialling localhost ----
    final session = await cache.sessionDirectory();
    staged.add(session.path);

    final started = DateTime.now();
    final result = await QhtpReceiverClient().downloadSession(
      payload: QRPayload(
        version: 2,
        ip: '127.0.0.1',
        port: localPort,
        token: token,
        sessionId: indexed.manifest.sessionId,
        mode: 'http-lan',
      ),
      targetBaseDir: session.path,
    );
    final elapsed = DateTime.now().difference(started);
    result.fold((failure) => fail('through the tunnel: ${failure.message}'), (_) {});

    final landed = File(p.join(session.path, 'clip.mp4'));
    expect(landed.existsSync(), isTrue);
    expect(landed.lengthSync(), equals(sizeMb * 1024 * 1024));
    expect(landed.readAsBytesSync(), equals(payload.readAsBytesSync()),
        reason: 'a tunnel that corrupts bytes is worse than no tunnel');

    final seconds = elapsed.inMicroseconds / 1000000;
    print('$sizeMb MB through the tunnel in '
        '${seconds.toStringAsFixed(1)} s '
        '(${(sizeMb / seconds).toStringAsFixed(0)} MB/s, loopback — the radio '
        'is not in this measurement)');

    // Staging still works exactly as it does for every other transport.
    final items = TransferCache.itemsIn(session);
    expect(items.single.name, equals('clip.mp4'));
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('joining something that is not there fails rather than hanging',
      (tester) async {
    await expectLater(
      link.join(
        serviceName: 'nobody-is-called-this',
        timeout: const Duration(seconds: 3),
      ),
      throwsA(isA<PeerLinkException>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}

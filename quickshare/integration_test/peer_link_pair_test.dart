// The measurement that matters: two devices, no router, real radio.
//
// Run the Mac first — it serves and waits — then the iPhone:
//
//   flutter test integration_test/peer_link_pair_test.dart -d macos \
//       --dart-define=PEERLINK_ROLE=host
//   flutter test integration_test/peer_link_pair_test.dart -d <iphone> \
//       --dart-define=PEERLINK_ROLE=join
//
// Wi-Fi must be on for both, but neither has to be joined to anything: that
// is the whole point of the link. Whatever number comes out is the honest
// answer to "how fast can these two talk with no network", against 13 KB/s
// over Bluetooth today.
// ignore_for_file: avoid_print
import 'dart:async';
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

const _role = String.fromEnvironment('PEERLINK_ROLE', defaultValue: 'host');
const _service = 'directdrop-pair-test';
const _token = 'pair-test-token';
const _sessionId = 'pair-test-session';
const _sizeMb = 64;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const link = PeerLinkService();
  const cache = TransferCache();

  testWidgets('peer-to-peer Wi-Fi carries a real transfer', (tester) async {
    expect(PeerLinkService.isSupported, isTrue);
    print('role: $_role on ${Platform.operatingSystem}');

    final events = link.events.listen((e) => print('  link: $e'));
    addTearDown(events.cancel);
    addTearDown(link.stop);

    if (_role == 'host') {
      final dir = Directory.systemTemp.createTempSync('dd_pair_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final random = Random(7);
      final block = Uint8List(1024 * 1024);
      for (var i = 0; i < block.length; i++) {
        block[i] = random.nextInt(256);
      }
      final payload = File(p.join(dir.path, 'clip.mp4'));
      final sink = payload.openSync(mode: FileMode.write);
      for (var i = 0; i < _sizeMb; i++) {
        sink.writeFromSync(block);
      }
      sink.closeSync();
      print('serving $_sizeMb MB, sha of first bytes '
          '${payload.readAsBytesSync().take(8).toList()}');

      final indexed = await FileIndexer()
          .buildResult(sessionId: _sessionId, paths: [payload.path]);
      final server = LocalHttpServer();
      addTearDown(server.stop);
      final port = await server.startQhtpSession(
        manifest: indexed.manifest,
        itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
        authToken: _token,
      );

      await link.host(serviceName: _service, localPort: port);
      print('hosting as "$_service", QHTP on :$port — start the other device');

      // Wait for the far side to take the whole thing.
      var last = 0.0;
      final done = Completer<void>();
      final progress = server.transferProgress.listen((value) {
        if (value - last >= 0.1 || value >= 1.0) {
          last = value;
          print('  sent ${(value * 100).toStringAsFixed(0)}%');
        }
        if (value >= 1.0 && !done.isCompleted) done.complete();
      });
      addTearDown(progress.cancel);

      await done.future.timeout(const Duration(minutes: 8),
          onTimeout: () => fail('no peer completed a transfer in time'));
      print('the far side took the whole file');
      return;
    }

    // ---- receiver ----
    final localPort = await link.join(
      serviceName: _service,
      timeout: const Duration(seconds: 60),
    );
    print('linked; the sender is reachable on 127.0.0.1:$localPort');

    final session = await cache.sessionDirectory();
    addTearDown(() => cache.discard([session.path]));

    final started = DateTime.now();
    final result = await QhtpReceiverClient().downloadSession(
      payload: QRPayload(
        version: 2,
        ip: '127.0.0.1',
        port: localPort,
        token: _token,
        sessionId: _sessionId,
        mode: 'http-lan',
      ),
      targetBaseDir: session.path,
    );
    final elapsed = DateTime.now().difference(started);
    result.fold((f) => fail('transfer failed: ${f.message}'), (_) {});

    final landed = File(p.join(session.path, 'clip.mp4'));
    expect(landed.lengthSync(), equals(_sizeMb * 1024 * 1024));

    final seconds = elapsed.inMicroseconds / 1000000;
    final mbPerSecond = _sizeMb / seconds;
    print('');
    print('=== peer-to-peer Wi-Fi, iPhone <- Mac ===');
    print('  $_sizeMb MB in ${seconds.toStringAsFixed(1)} s');
    print('  ${mbPerSecond.toStringAsFixed(1)} MB/s '
        '(${(mbPerSecond * 8).toStringAsFixed(0)} Mbit/s)');
    print('  Bluetooth on this pair measured 0.013 MB/s — '
        '${(mbPerSecond / 0.013).toStringAsFixed(0)}x');
    print('');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

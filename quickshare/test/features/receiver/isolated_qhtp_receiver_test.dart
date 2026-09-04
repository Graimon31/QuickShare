// Receiving belongs off the isolate that draws the screen.
//
// One isolate is one thread, and until now the same one decrypted every
// packet, wrote every block to disk and rebuilt the progress bar sixty times
// a second. On a phone the turns the interface took were turns the transfer
// did not — which is what a Desktop→iOS transfer "hanging" was.
//
// Moving it across is only worth anything if it still behaves: the bytes have
// to land, progress has to come back, cancelling has to stop it, and what the
// worker logs has to reach the journal — which lives on the isolate it just
// left.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/client/isolated_qhtp_receiver.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
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

  late Directory source;
  late Directory target;
  late Directory state;
  LocalHttpServer? server;

  setUp(() async {
    source = await Directory.systemTemp.createTemp('iso_src_');
    target = await Directory.systemTemp.createTemp('iso_dst_');
    state = await Directory.systemTemp.createTemp('iso_state_');
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    for (final dir in [source, target, state]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  /// A session serving [bytes] of random data, and the payload to reach it.
  Future<QRPayload> serve(int bytes, {String name = 'big.bin'}) async {
    final rand = Random(19);
    await File(p.join(source.path, name)).writeAsBytes(
        Uint8List.fromList(List.generate(bytes, (_) => rand.nextInt(256))));

    final indexed = await FileIndexer().buildResult(
      sessionId: 'isolated',
      paths: [source.path],
      includeChecksums: false,
    );
    server = LocalHttpServer();
    const token = 'isolated-token';
    final port = await server!.startQhtpSession(
      manifest: indexed.manifest,
      itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
      authToken: token,
    );
    return QRPayload(
      version: 2,
      ip: '127.0.0.1',
      port: port,
      token: token,
      fileName: name,
      fileSize: bytes,
      tlsFingerprint: server!.tlsFingerprint!,
    );
  }

  IsolatedQhtpReceiver receiver() => IsolatedQhtpReceiver(
        stateDirectory: () async => state.path,
        fallbackDirectory: () async => target.path,
      );

  test('the bytes arrive intact from the other isolate', () async {
    final payload = await serve(6 * 1024 * 1024);
    final original =
        await File(p.join(source.path, 'big.bin')).readAsBytes();

    final reports = <QhtpProgress>[];
    final result = await receiver().downloadSession(
      payload: payload,
      targetBaseDir: target.path,
      onProgress: reports.add,
    );

    expect(result.isRight, isTrue, reason: 'the transfer has to succeed');
    final landed =
        File(p.join(target.path, p.basename(source.path), 'big.bin'));
    expect(landed.existsSync(), isTrue);
    expect(landed.readAsBytesSync(), equals(original));

    expect(reports.any((r) => r.phase == 'transferring'), isTrue,
        reason: 'progress has to cross back, or the screen shows nothing');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('what the worker logs reaches the journal it left behind', () async {
    // The journal's file handle comes from a plugin, so a worker has none of
    // its own. Without the lines coming back, everything a transfer records —
    // the route, the speed, why it failed — vanished, which is the half of
    // the journal anyone actually reads.
    final seen = <String>[];
    final subscription = AppLogger.logStream.listen(seen.add);
    addTearDown(subscription.cancel);

    final payload = await serve(512 * 1024);
    await receiver()
        .downloadSession(payload: payload, targetBaseDir: target.path);
    // The stream is broadcast and asynchronous; let what is in flight land.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(seen.any((line) => line.contains('QHTP')), isTrue,
        reason: 'the worker logs, and the main isolate has to hear it');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('cancelling stops a transfer running in the worker', () async {
    final payload = await serve(64 * 1024 * 1024);
    final worker = receiver();

    final done = worker.downloadSession(
      payload: payload,
      targetBaseDir: target.path,
      onProgress: (progress) {
        // Cancel once bytes are genuinely moving, not before the isolate has
        // even started — the message has to reach a transfer in flight.
        if (progress.phase == 'transferring' && progress.sessionReceived > 0) {
          worker.cancel();
        }
      },
    );

    final result = await done.timeout(const Duration(seconds: 60));
    expect(result.isLeft, isTrue,
        reason: 'a cancelled transfer is not a finished one');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('cancelling before the worker is up is not lost', () async {
    // The isolate takes a few milliseconds to spawn, and a tap on the cancel
    // button does not wait for it. Dropping the message there would run the
    // whole session for a screen nobody is on any more.
    final payload = await serve(32 * 1024 * 1024);
    final worker = receiver();

    final done = worker.downloadSession(
      payload: payload,
      targetBaseDir: target.path,
    );
    worker.cancel();

    final result = await done.timeout(const Duration(seconds: 60));
    expect(result.isLeft, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

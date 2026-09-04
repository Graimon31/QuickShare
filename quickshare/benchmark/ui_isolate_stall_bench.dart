// What a transfer costs the isolate that draws the screen.
//
// The interface lives on one isolate and so, until now, did the whole
// receive: decrypting every packet, hashing it, writing it to disk. They took
// turns, and the turns the interface took were turns the transfer did not —
// which is what a Desktop→iOS transfer "hanging" was, and why the receiving
// screen stopped answering while it did.
//
// Measured the way the device topology actually is: the sender is a different
// machine, so it gets an isolate of its own in *both* runs. What changes
// between them is only where the receiving happens — the main isolate, or a
// worker. The main isolate meanwhile pretends to be a screen: a frame every
// 16 ms with a couple of milliseconds of work in it, which is what a progress
// bar and its animations amount to. A frame that takes longer than its 16 ms
// is a frame the user sees drop.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/features/receiver/data/client/isolated_qhtp_receiver.dart';
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

const int size = 200 * 1024 * 1024;

/// The sender, on an isolate of its own — as it is on a real network.
Future<Map<String, Object>> startSender(SendPort? _, String sourcePath) async {
  wakelockPlusPlatformInstance = _FakeWakelock();
  final indexed = await FileIndexer().buildResult(
      sessionId: 'stall', paths: [sourcePath], includeChecksums: false);
  final server = LocalHttpServer();
  final port = await server.startQhtpSession(
    manifest: indexed.manifest,
    itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
    authToken: 't',
  );
  return {'port': port, 'fingerprint': server.tlsFingerprint!};
}

void _senderWorker(List<Object> args) async {
  final replies = args[0] as SendPort;
  final sourcePath = args[1] as String;
  replies.send(await startSender(null, sourcePath));
  // Held open until the isolate is killed: closing here would take the
  // server down with it.
  await Completer<void>().future;
}

/// How the frames went while [work] ran.
class _Frames {
  final int drawn;
  final int late;
  final Duration worst;
  const _Frames(this.drawn, this.late, this.worst);
}

Future<_Frames> whileDrawing(Future<void> Function() work) async {
  var drawn = 0;
  var late = 0;
  var worst = Duration.zero;
  var running = true;

  Future<void> draw() async {
    while (running) {
      final started = DateTime.now();
      // Stand-in for a frame's own work: laying out and painting a screen
      // with a progress bar on it.
      var sum = 0.0;
      for (var i = 0; i < 400000; i++) {
        sum += sqrt(i.toDouble());
      }
      if (sum < 0) return;
      final took = DateTime.now().difference(started);
      drawn++;
      if (took > const Duration(milliseconds: 16)) late++;
      if (took > worst) worst = took;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  final frames = draw();
  try {
    await work();
  } finally {
    running = false;
    await frames;
  }
  return _Frames(drawn, late, worst);
}

void main() {
  setUpAll(() => wakelockPlusPlatformInstance = _FakeWakelock());

  test('frames on the main isolate, receiving in process versus in a worker',
      () async {
    Future<Directory> makeSource() async {
      final dir = await Directory.systemTemp.createTemp('stall_src_');
      final rand = Random(5);
      final block = Uint8List(1 << 20);
      for (var i = 0; i < block.length; i++) {
        block[i] = rand.nextInt(256);
      }
      final sink = File(p.join(dir.path, 'big.bin')).openWrite();
      for (var i = 0; i < size ~/ block.length; i++) {
        sink.add(block);
      }
      await sink.flush();
      await sink.close();
      return dir;
    }

    for (final inProcess in [true, false]) {
      final source = await makeSource();
      final target = await Directory.systemTemp.createTemp('stall_dst_');
      final state = await Directory.systemTemp.createTemp('stall_state_');

      final replies = ReceivePort();
      final sender = await Isolate.spawn(
          _senderWorker, [replies.sendPort, source.path]);
      final started = await replies.first as Map;
      final payload = QRPayload(
        version: 2,
        ip: '127.0.0.1',
        port: started['port'] as int,
        token: 't',
        fileName: 'big.bin',
        fileSize: size,
        tlsFingerprint: started['fingerprint'] as String,
      );

      final elapsed = Stopwatch()..start();
      final frames = await whileDrawing(() async {
        if (inProcess) {
          await QhtpReceiverClient(
            store: SessionStateStore(storeDirectory: state.path),
            fallbackDirectory: () async => target.path,
          ).downloadSession(payload: payload, targetBaseDir: target.path);
        } else {
          await IsolatedQhtpReceiver(
            stateDirectory: () async => state.path,
            fallbackDirectory: () async => target.path,
          ).downloadSession(payload: payload, targetBaseDir: target.path);
        }
      });
      elapsed.stop();

      final mbps = size / elapsed.elapsedMilliseconds * 1000 / (1 << 20);
      print('STALL ${inProcess ? 'in process' : 'in a worker '}: '
          '${frames.late}/${frames.drawn} frames late, '
          'worst ${frames.worst.inMilliseconds}ms, '
          'transfer ${elapsed.elapsedMilliseconds}ms '
          '(${mbps.toStringAsFixed(1)} MB/s)');

      sender.kill(priority: Isolate.immediate);
      replies.close();
      await source.delete(recursive: true);
      await target.delete(recursive: true);
      await state.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

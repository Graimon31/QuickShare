// How fast can a transfer actually go, and is our own flow control the thing
// holding it back?
//
// A hand-run measurement rather than a test — it prints numbers for a human
// to read and asserts almost nothing, so it does not belong in CI:
//
//     flutter test integration_test/throughput_benchmark.dart -d macos
//
// Both peers run in this process over a real WebRTC DataChannel, so the
// network is loopback and effectively free. Whatever ceiling shows up here is
// ours: chunk size, the backpressure window, and how long the send loop sleeps
// when that window is full.
//
// The suspicion being tested: the send loop may queue at most
// AppConstants.webRtcMaxBufferedAmount (256 KB) before it waits, and
// SendBuffer polls every 50 ms. If the loop actually parks for a full poll
// interval each time, that caps throughput at roughly 256 KB / 50 ms ≈ 5 MB/s
// no matter what the link can carry.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

/// Hands a published payload straight back to the subscriber, so the
/// measurement never depends on anybody's relay being up.
class _LoopbackAnswerChannel implements AnswerChannel {
  final _controller = StreamController<Uint8List>.broadcast();

  @override
  String get name => 'loopback';

  @override
  Stream<Uint8List> get answers => _controller.stream;

  @override
  Future<void> subscribe(String topic) async {}

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    _controller.add(payload);
  }

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

String _rate(int bytes, Duration elapsed) {
  final mb = bytes / (1024 * 1024);
  final seconds = elapsed.inMicroseconds / 1000000;
  return '${(mb / seconds).toStringAsFixed(1)} MB/s '
      '(${mb.toStringAsFixed(0)} MB in ${seconds.toStringAsFixed(1)} s)';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;

  setUpAll(() {
    workspace = Directory.systemTemp.createTempSync('dd_bench_');
  });

  tearDownAll(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  testWidgets('measures what the transfer path can carry', (tester) async {
    // 128 MB: long enough that startup cost is noise, short enough to run in
    // a minute even if the ceiling turns out to be low.
    const sizeBytes = 128 * 1024 * 1024;

    // Built from a repeated block rather than byte-by-byte randomness, which
    // would spend longer generating the file than transferring it. The
    // content does not matter here — the MIME type below keeps compression
    // out of the measurement either way.
    final block = Uint8List(1024 * 1024);
    for (var i = 0; i < block.length; i++) {
      block[i] = (i * 31 + 7) & 0xFF;
    }
    final payload = File(p.join(workspace.path, 'payload.mp4'));
    final sink = payload.openSync(mode: FileMode.write);
    for (var i = 0; i < sizeBytes ~/ block.length; i++) {
      sink.writeFromSync(block);
    }
    sink.closeSync();

    print('\n=== configuration under test ===');
    print('  chunk size          ${AppConstants.webRtcChunkSizeBytes} B');
    print('  backpressure window ${AppConstants.webRtcMaxBufferedAmount} B');
    print('  theoretical ceiling if the loop sleeps a full 50 ms poll each '
        'time it fills:');
    print('    ${(AppConstants.webRtcMaxBufferedAmount / (1024 * 1024) / 0.05).toStringAsFixed(1)} MB/s');

    // ---- baseline: how fast the file can even be read ----
    final readStarted = DateTime.now();
    final raf = payload.openSync();
    var read = 0;
    while (read < sizeBytes) {
      final chunk = raf.readSync(AppConstants.webRtcChunkSizeBytes);
      if (chunk.isEmpty) break;
      read += chunk.length;
    }
    raf.closeSync();
    final readElapsed = DateTime.now().difference(readStarted);
    print('\n=== baseline ===');
    print('  disk read, same chunk size: ${_rate(read, readElapsed)}');

    // ---- the real thing ----
    final destination = Directory(p.join(workspace.path, 'incoming'))
      ..createSync();
    final channel = _LoopbackAnswerChannel();
    final sender = WebRtcTransferTransport();
    final receiver = WebRtcReceiverTransport();
    addTearDown(() async {
      await sender.stopSharing();
      await channel.close();
    });

    await sender.initialize();
    await sender.startSharingServerless(FileMetadata(
      name: 'payload.mp4',
      path: payload.path,
      size: sizeBytes,
      // Video: shouldCompressForTransfer skips it, so this measures the
      // transport rather than gzip.
      mimeType: 'video/mp4',
    ));

    final offerSdp = await sender.createLocalOfferSdp();
    expect(offerSdp, isNotNull);

    final qr = ServerlessQr(
      seed: SealedEnvelope.newSeed(),
      offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(offerSdp!)),
    );
    final topic = await qr.topic;
    await channel.subscribe(topic);

    channel.answers.listen((sealed) async {
      final opened = await SealedEnvelope.open(
        envelope: sealed,
        seed: qr.seed,
        offerFingerprint: qr.offerFingerprint,
      );
      await sender.handleDirectAnswer(
          CompactSdp.fromBytes(opened).toSdp(isOffer: false), 'answer');
    });

    // Timed from the first byte that actually moves, so connection setup and
    // ICE do not get counted as transfer time.
    DateTime? firstByteAt;
    final progressSub = receiver.progressStream.listen((e) {
      if (e.phase == 'transferring' && e.received > 0) {
        firstByteAt ??= DateTime.now();
      }
    });
    addTearDown(progressSub.cancel);

    await receiver.receiveWithSdpOffer(
      qr.offer.toSdp(isOffer: true),
      targetDir: destination.path,
      deliverAnswer: (answerSdp) async {
        await channel.publish(
          topic,
          await SealedEnvelope.seal(
            plaintext:
                ServerlessQr.trimForQr(CompactSdp.fromSdp(answerSdp)).toBytes(),
            seed: qr.seed,
            offerFingerprint: qr.offerFingerprint,
          ),
        );
      },
    );
    final finishedAt = DateTime.now();

    final landed = File(receiver.receivedPaths.single);
    expect(landed.lengthSync(), equals(sizeBytes),
        reason: 'a short file would make the rate meaningless');

    final transferElapsed = finishedAt.difference(firstByteAt ?? finishedAt);
    print('\n=== over a real DataChannel, loopback ===');
    print('  ${_rate(sizeBytes, transferElapsed)}');

    final mbPerSecond =
        (sizeBytes / (1024 * 1024)) / (transferElapsed.inMicroseconds / 1000000);
    const ceiling = AppConstants.webRtcMaxBufferedAmount / (1024 * 1024) / 0.05;
    print('\n=== reading ===');
    if (mbPerSecond < ceiling * 1.2) {
      print('  At or below the ${ceiling.toStringAsFixed(1)} MB/s the window '
          'and poll interval imply — our own flow control is the limit here, '
          'not the link.');
    } else {
      print('  Above the ${ceiling.toStringAsFixed(1)} MB/s that a full 50 ms '
          'sleep per fill would allow, so the loop is not parking for whole '
          'poll intervals.');
    }
    print('  On a real network, whichever is lower — this or the link — wins.\n');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

// The WebRTC receiver, driven frame by frame.
//
// DD-24 — progress fired once per 64 KB chunk. Every one of those crossed
// into the bloc, emitted a state and rebuilt the receiving screen, on the
// same isolate that runs the write loop. It is the same shape as a
// Desktop→iOS transfer "hanging". The QHTP client has been throttled to 10 Hz
// for exactly this reason; this brings the other transport into line.
//
// DD-26 — `file-end` always sealed the file: fsync, then rename the partial
// into its real name. There was no per-file length check, only the session
// total at the very end. A file truncated in the middle of a folder — an
// early `file-end`, a dropped chunk — landed under its real name with the
// rest of the transfer looking fine, and nobody goes looking for what is
// missing.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';

void main() {
  late WebRtcReceiverTransport transport;
  late Directory dest;

  setUp(() {
    transport = WebRtcReceiverTransport();
    dest = Directory.systemTemp.createTempSync('dd_webrtc_recv_');
  });

  tearDown(() {
    if (dest.existsSync()) dest.deleteSync(recursive: true);
  });

  RTCDataChannelMessage text(String s) => RTCDataChannelMessage(s);
  RTCDataChannelMessage binary(int n) =>
      RTCDataChannelMessage.fromBinary(Uint8List(n));

  TransferItem item(String path, int size) =>
      TransferItem(
        name: p.basename(path),
        size: size,
        mimeType: 'application/octet-stream',
        path: path,
        compressed: false,
      );

  Future<void> feed(RTCDataChannelMessage m) =>
      transport.deliverForTest(m, baseDir: dest.path);

  group('DD-24 — progress is throttled', () {
    test('a burst of chunks does not emit a state per chunk', () async {
      final events = <String>[];
      final sub = transport.progressStream.listen((e) => events.add(e.phase));
      addTearDown(sub.cancel);

      await feed(text(TransferProtocol.buildManifest([item('big.bin', 200000)])));
      await feed(text(TransferProtocol.buildFileStart(0)));

      // Twenty 10 KB chunks back to back — well under the 100 ms window, so
      // an unthrottled receiver emits twenty 'transferring' states.
      for (var i = 0; i < 20; i++) {
        await feed(binary(10000));
      }

      final transferring = events.where((e) => e == 'transferring').length;
      expect(transferring, lessThan(20),
          reason: 'each chunk emitted its own progress state');
      expect(transferring, greaterThanOrEqualTo(1),
          reason: 'but the screen still moves');
    });

    test('the chunk that completes a file still reports it', () async {
      final events = <String>[];
      final sub = transport.progressStream.listen((e) => events.add(e.phase));
      addTearDown(sub.cancel);

      await feed(text(TransferProtocol.buildManifest([item('a.bin', 30000)])));
      await feed(text(TransferProtocol.buildFileStart(0)));
      await feed(binary(30000));
      await feed(text(TransferProtocol.buildFileEnd(0)));
      await transport.completionForTest;
      await Future<void>.delayed(Duration.zero);

      // A full byte count is completion in its own right, throttle or not.
      expect(events, contains('completed'));
    });
  });

  group('DD-26 — a short item does not land under its real name', () {
    test('an early file-end fails the transfer, leaves no named file',
        () async {
      await feed(text(TransferProtocol.buildManifest([item('report.pdf', 50000)])));
      await feed(text(TransferProtocol.buildFileStart(0)));
      await feed(binary(20000)); // only 20 KB of the announced 50 KB
      await feed(text(TransferProtocol.buildFileEnd(0)));

      await expectLater(transport.completionForTest, throwsA(anything));

      final landed = dest
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .toList();
      expect(landed, isNot(contains('report.pdf')),
          reason: 'half a file under the right name is worse than none');
      expect(landed.where((n) => !n.endsWith('.qs.partial')), isEmpty);
    });

    test('a file at exactly its announced size is kept', () async {
      await feed(text(TransferProtocol.buildManifest([item('ok.bin', 40000)])));
      await feed(text(TransferProtocol.buildFileStart(0)));
      await feed(binary(40000));
      await feed(text(TransferProtocol.buildFileEnd(0)));

      final saved = File(p.join(dest.path, 'ok.bin'));
      expect(saved.existsSync(), isTrue);
      expect(saved.lengthSync(), equals(40000));
    });

    test('one short item in a folder fails the whole transfer', () async {
      // The folder is staged and only committed once every item is verified,
      // so a short second file must stop the first from being published too.
      await feed(text(TransferProtocol.buildManifest([
        item('Trip/one.bin', 10000),
        item('Trip/two.bin', 10000),
      ])));

      await feed(text(TransferProtocol.buildFileStart(0)));
      await feed(binary(10000));
      await feed(text(TransferProtocol.buildFileEnd(0)));

      await feed(text(TransferProtocol.buildFileStart(1)));
      await feed(binary(3000)); // short
      await feed(text(TransferProtocol.buildFileEnd(1)));

      await expectLater(transport.completionForTest, throwsA(anything));

      // The folder is never committed: nothing lands at its real path. What
      // is left is a `.qs.partial` staging directory, which is debris the
      // sweep clears — the same shape as any interrupted transfer.
      expect(Directory(p.join(dest.path, 'Trip')).existsSync(), isFalse,
          reason: 'a partly-delivered folder is not published');
      final committed = dest
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => !n.endsWith('.qs.partial'));
      expect(committed, isEmpty);
    });
  });
}

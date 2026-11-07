import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/webrtc/resume/reconnect_policy.dart';
import 'package:quickshare/core/webrtc/resume/resumable_sender.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';

class _Link implements SenderLink {
  // Closed by test teardown.
  // ignore: close_sinks
  final messages = StreamController<String>();
  final ended = Completer<String>();
  final completeSent = Completer<void>();
  @override
  int get generation => 1;
  @override
  bool get isOpen => true;
  @override
  Stream<String> get incoming => messages.stream;
  @override
  Future<String> get closed => ended.future;
  @override
  void sendText(String frame) {
    if ((jsonDecode(frame) as Map)['type'] == TransferProtocol.complete) {
      completeSent.complete();
    }
  }

  @override
  void sendBinary(Uint8List bytes) {}
  @override
  Future<void> waitForRoom(int limit, {required Duration stallTimeout}) async {}
  @override
  Future<void> close() async {}
}

void main() {
  test('ignores a hello from another link and waits for receiver confirmation',
      () async {
    final dir = await Directory.systemTemp.createTemp('sender-test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/file');
    await file.writeAsBytes([1, 2, 3]);
    final link = _Link();
    addTearDown(link.messages.close);
    final progress = <double>[];
    final sender = ResumableSender(
      items: [
        SendItem(
            const TransferItem(
                name: 'file',
                size: 3,
                mimeType: 'application/octet-stream',
                compressed: false),
            file.path)
      ],
      firstLink: link,
      reconnect: (_, __, ___) => throw StateError('unexpected reconnect'),
      sendWindow: 1024,
      stall: const StallPolicy(legacyHelloWait: Duration(seconds: 1)),
      forceInlineDigest: true,
      onProgress: progress.add,
    );
    final run = sender.run();
    link.messages.add(TransferProtocol.buildHello(generation: 2));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(sender.receiverSpeaksV2, isFalse);
    link.messages.add(TransferProtocol.buildHello(generation: 1));
    await link.completeSent.future;
    expect(progress, isNotEmpty);
    expect(progress.last, lessThan(1));
    link.messages.add(TransferProtocol.buildDone(ok: true));
    await run;
    expect(progress.last, 1);
  });
}

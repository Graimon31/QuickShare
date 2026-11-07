import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/webrtc/resume/receiver_link.dart';
import 'package:quickshare/core/webrtc/resume/reconnect_policy.dart';
import 'package:quickshare/core/webrtc/resume/resumable_sender.dart';
import 'package:quickshare/core/webrtc/resume/resume_keys.dart';
import 'package:quickshare/core/webrtc/resume/resume_signaling.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';

import '../../support/fake_mailbox.dart';
import '../../support/link_pipe.dart';

const stall = StallPolicy(
  sendNoDrain: Duration(milliseconds: 100),
  receiveSilence: Duration(milliseconds: 250),
  suspectAfter: Duration(milliseconds: 50),
  pingEvery: Duration(milliseconds: 30),
  helloWait: Duration(seconds: 1),
  doneWait: Duration(milliseconds: 200),
  legacyHelloWait: Duration(milliseconds: 200),
);
const policy = ReconnectPolicy(
  attemptTimeout: Duration(seconds: 2),
  totalBudget: Duration(seconds: 10),
  pauseBetweenAttempts: [],
  progressBytes: 1,
);

class _CountingFile extends DurableFile {
  _CountingFile(super.finalPath,
      {super.staged, super.base, required this.onCommit});
  final void Function() onCommit;

  @override
  Future<String> commit() async {
    final result = await super.commit();
    onCommit();
    return result;
  }
}

void main() {
  late Directory root;
  late Directory dest;
  late FakeMailboxHub hub;
  late ResumeKeys keys;
  late ResumeSenderSignaling signal;
  late List<LinkPipe> pipes;
  late Map<int, Completer<ReceiverLink>> ready;
  late WebRtcReceiverTransport receiver;
  late File source;
  late Uint8List content;
  late int commits;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('webrtc_resume_');
    dest = await Directory(p.join(root.path, 'dest')).create();
    content = Uint8List.fromList(List.generate(16384, (i) => i % 251));
    source = File(p.join(root.path, 'source.bin'));
    await source.writeAsBytes(content);
    hub = FakeMailboxHub();
    keys = ResumeKeys.derive(
        seed: List.filled(16, 7),
        offerFingerprint: sha256.convert([1, 2, 3]).bytes);
    signal = ResumeSenderSignaling(
        mailbox: hub.endpoint('sender'),
        keys: keys,
        republishEvery: const Duration(milliseconds: 30));
    await signal.open();
    pipes = [LinkPipe(1)];
    ready = {};
    commits = 0;
    receiver = WebRtcReceiverTransport(
      debugFileFactory: (path, {required staged, required base}) =>
          _CountingFile(path,
              staged: staged, base: base, onCommit: () => commits++),
      stall: stall,
      reconnectPolicy: policy,
      forceInlineDigest: true,
      completionGrace: const Duration(seconds: 4),
      debugLinkOpener: (offer) async {
        final pipe = pipes.singleWhere((p) => p.generation == offer.generation);
        return ReceiverLinkAttempt(
            answerSdp: Uint8List.fromList([2]),
            ready: ready[offer.generation]!.future,
            abandon: pipe.receiver.close);
      },
    );
    receiver.attachLinkForTest(pipes.first.receiver,
        baseDir: dest.path,
        resume: ResumeSetup(
            keys: keys, mailboxFactory: () => hub.endpoint('receiver')));
  });

  tearDown(() async {
    await receiver.cancel();
    await signal.close();
    for (final pipe in pipes) {
      await pipe.dispose();
    }
    await root.delete(recursive: true);
  });

  ResumableSender sender() => ResumableSender(
        items: [
          SendItem(
              TransferItem(
                  name: 'out.bin',
                  size: content.length,
                  mimeType: 'application/octet-stream',
                  compressed: false),
              source.path)
        ],
        firstLink: pipes.first.sender,
        sendWindow: 1024,
        chunkSize: 512,
        stall: stall,
        policy: policy,
        forceInlineDigest: true,
        reconnect: (generation, attempt, timeout) async {
          final pipe = LinkPipe(generation);
          pipes.add(pipe);
          ready[generation] = Completer<ReceiverLink>();
          await signal.offer(
              generation: generation,
              offerSdp: Uint8List.fromList([1]),
              timeout: timeout);
          ready[generation]!.complete(pipe.receiver);
          return pipe.sender;
        },
      );

  for (final cut in [PipeCut.blackhole, PipeCut.close]) {
    test('resumes exact bytes after ${cut.name} halfway through a file',
        () async {
      pipes.first.cutKind = cut;
      pipes.first.cutAfterBinaryBytes = 2048;
      await sender().run().timeout(const Duration(seconds: 8));
      await receiver.completionForTest;
      expect(await File(p.join(dest.path, 'out.bin')).readAsBytes(), content);
      expect(pipes.length, greaterThan(1));
    });
  }

  test('lost completion acknowledgment is recovered without rewriting',
      () async {
    pipes.first.cutAfterFrame = (f) => f.type == TransferProtocol.fileEnd;
    await sender().run().timeout(const Duration(seconds: 8));
    await receiver.completionForTest;
    expect(await File(p.join(dest.path, 'out.bin')).readAsBytes(), content);
    expect(pipes.length, greaterThan(1));
    expect(commits, 1, reason: 'the committed file must not be rewritten');
  });

  test('bad digest rejects and removes a complete-sized file', () async {
    pipes.first.sender.incoming.listen((_) {});
    Future<void> text(String s) =>
        receiver.deliverForTest(RTCDataChannelMessage(s));
    final failed =
        expectLater(receiver.completionForTest, throwsA(isA<Exception>()));
    await text(TransferProtocol.buildManifest([
      const TransferItem(
          name: 'bad.bin',
          size: 3,
          mimeType: 'application/octet-stream',
          compressed: false)
    ], sessionId: '0123456789abcdef0123456789abcdef'));
    await text(TransferProtocol.buildFileStart(0));
    await receiver.deliverForTest(
        RTCDataChannelMessage.fromBinary(Uint8List.fromList([1, 2, 3])));
    await text(TransferProtocol.buildFileEnd(0, sha256: '0' * 64));
    await failed;
    expect(File(p.join(dest.path, 'bad.bin')).existsSync(), isFalse);
    expect(File(p.join(dest.path, 'bad.bin.qs.partial')).existsSync(), isFalse);
  });

  test('an unavailable recovery mailbox does not break a completed transfer',
      () async {
    receiver.attachLinkForTest(pipes.first.receiver,
        baseDir: dest.path,
        resume: ResumeSetup(
            keys: keys,
            mailboxFactory: () => throw StateError('no channels configured')));
    await sender().run().timeout(const Duration(seconds: 8));
    await receiver.completionForTest;
    expect(await File(p.join(dest.path, 'out.bin')).readAsBytes(), content);
    expect(commits, 1);
  });
}

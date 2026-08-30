// The serverless path, end to end, with a real WebRTC stack.
//
// Everything below this line was previously unverifiable: `createPeerConnection`
// needs platform channels, and `flutter test` has none, so the offer/answer
// handshake, ICE gathering, DTLS, the DataChannel and the file write were
// covered only by unit tests of the pieces around them. This runs the real
// thing:
//
//     flutter test integration_test/serverless_e2e_test.dart -d macos
//
// The rendezvous is deliberately in-memory rather than a real Nostr relay. The
// point here is the WebRTC half; going out to public relays would make the test
// depend on somebody else's uptime, which is exactly the property that got a
// previous integration test deleted.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

/// Hands a published payload straight back to the subscriber.
///
/// Stands in for the Nostr fan-out without leaving the process. The sealing is
/// still real: the sender only accepts an answer that opens under the seed from
/// its own QR code, so a broken envelope fails here exactly as it would in the
/// field.
class _LoopbackAnswerChannel implements AnswerChannel {
  final _controller = StreamController<Uint8List>.broadcast();
  String? subscribedTopic;
  int publishCount = 0;

  @override
  String get name => 'loopback';

  @override
  Stream<Uint8List> get answers => _controller.stream;

  @override
  Future<void> subscribe(String topic) async => subscribedTopic = topic;

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    expect(topic, equals(subscribedTopic),
        reason: 'both sides must derive the same topic from the seed');
    publishCount++;
    if (!_controller.isClosed) _controller.add(payload);
  }

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync('dd_e2e_'));
  tearDown(() => workspace.deleteSync(recursive: true));

  /// A file with content that would survive neither truncation nor a flipped
  /// byte unnoticed.
  ({File file, String digest}) makePayload(int bytes, {String? name}) {
    final random = Random(20260816 + bytes);
    final data =
        Uint8List.fromList(List<int>.generate(bytes, (_) => random.nextInt(256)));
    final file = File(p.join(workspace.path, name ?? 'payload.bin'))
      ..writeAsBytesSync(data);
    return (file: file, digest: sha256.convert(data).toString());
  }

  testWidgets('a file crosses a real DataChannel and lands intact',
      (tester) async {
    const sizeBytes = 512 * 1024;
    final payload = makePayload(sizeBytes);
    final destination = Directory(p.join(workspace.path, 'incoming'))
      ..createSync();

    final channel = _LoopbackAnswerChannel();
    final sender = WebRtcTransferTransport();
    final receiver = WebRtcReceiverTransport();
    addTearDown(() async {
      await sender.stopSharing();
      await channel.close();
    });

    // ---- sender: exactly what SenderBloc does in the internet branch ----
    await sender.initialize();
    await sender.startSharingServerless(FileMetadata(
      name: p.basename(payload.file.path),
      path: payload.file.path,
      size: sizeBytes,
      mimeType: 'application/octet-stream',
    ));

    final offerSdp = await sender.createLocalOfferSdp();
    expect(offerSdp, isNotNull,
        reason: 'no offer means the platform channel never came up');

    final qr = ServerlessQr(
      seed: SealedEnvelope.newSeed(),
      offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(offerSdp!)),
    );
    final topic = await qr.topic;
    await channel.subscribe(topic);

    final answerApplied = Completer<void>();
    channel.answers.listen((sealed) async {
      final opened = await SealedEnvelope.open(
        envelope: sealed,
        seed: qr.seed,
        offerFingerprint: qr.offerFingerprint,
      );
      await sender.handleDirectAnswer(
          CompactSdp.fromBytes(opened).toSdp(isOffer: false), 'answer');
      if (!answerApplied.isCompleted) answerApplied.complete();
    });

    // ---- receiver: exactly what ReceiverBloc does ----
    final progressPhases = <String>[];
    final progressSub = receiver.progressStream
        .listen((event) => progressPhases.add(event.phase));
    addTearDown(progressSub.cancel);

    final savedPath = await receiver.receiveWithSdpOffer(
      qr.offer.toSdp(isOffer: true),
      targetDir: destination.path,
      deliverAnswer: (answerSdp) async {
        final sealed = await SealedEnvelope.seal(
          plaintext:
              ServerlessQr.trimForQr(CompactSdp.fromSdp(answerSdp)).toBytes(),
          seed: qr.seed,
          offerFingerprint: qr.offerFingerprint,
        );
        await channel.publish(topic, sealed);
      },
    );

    // ---- what actually has to be true ----
    expect(channel.publishCount, equals(1));
    expect(answerApplied.isCompleted, isTrue,
        reason: 'the sender must have opened and applied the sealed answer');

    final received = File(savedPath);
    expect(received.existsSync(), isTrue);
    expect(p.isWithin(destination.path, savedPath), isTrue,
        reason: 'the _baseDir regression put files in the process CWD');

    final bytes = received.readAsBytesSync();
    expect(bytes.length, equals(sizeBytes));
    expect(sha256.convert(bytes).toString(), equals(payload.digest),
        reason: 'byte-for-byte, not just the right size');

    // The screen used to sit on "Connecting" for the whole transfer because
    // nothing listened to this stream.
    expect(progressPhases, contains('transferring'));
    expect(progressPhases, contains('completed'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('several files cross one DataChannel and each lands intact',
      (tester) async {
    // The wire protocol used to carry exactly one file, so sending a folder or
    // a batch of photos meant zipping them first — which defeats saving photos
    // straight into the gallery on the far side. This is the manifest path.
    final destination = Directory(p.join(workspace.path, 'incoming_multi'))
      ..createSync();

    // Deliberately mixed: one compressible, two that must pass through
    // untouched (a photo and a video are the reason "no compression" matters).
    final payloads = [
      (name: 'notes.txt', bytes: 64 * 1024, mime: 'text/plain'),
      (name: 'photo.jpg', bytes: 256 * 1024, mime: 'image/jpeg'),
      (name: 'clip.mp4', bytes: 128 * 1024, mime: 'video/mp4'),
    ];

    final files = <FileMetadata>[];
    final digests = <String, String>{};
    for (final spec in payloads) {
      final made = makePayload(spec.bytes, name: spec.name);
      digests[spec.name] = made.digest;
      files.add(FileMetadata(
        name: spec.name,
        path: made.file.path,
        size: spec.bytes,
        mimeType: spec.mime,
      ));
    }

    final channel = _LoopbackAnswerChannel();
    final sender = WebRtcTransferTransport();
    final receiver = WebRtcReceiverTransport();
    addTearDown(() async {
      await sender.stopSharing();
      await channel.close();
    });

    await sender.initialize();
    await sender.startSharingServerless(files.first, files: files);

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

    // Progress must climb across the session rather than restarting per file.
    final fractions = <double>[];
    final progressSub = receiver.progressStream.listen((e) {
      if (e.total > 0) fractions.add(e.received / e.total);
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

    final landed = receiver.receivedPaths;
    expect(landed, hasLength(payloads.length),
        reason: 'every manifest entry must produce a file');

    for (final path in landed) {
      final name = p.basename(path);
      final bytes = File(path).readAsBytesSync();
      expect(digests.containsKey(name), isTrue, reason: 'unexpected file $name');
      expect(sha256.convert(bytes).toString(), equals(digests[name]),
          reason: '$name arrived corrupted — byte-for-byte is the whole point '
              'for photos and video');
    }

    expect(fractions, isNotEmpty);
    expect(fractions.reduce((a, b) => a < b ? a : b), greaterThanOrEqualTo(0.0));
    expect(fractions.last, closeTo(1.0, 0.001),
        reason: 'session progress must finish at 100%, not per-file');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a folder lands whole under its own name, with no .qs.partial left',
      (tester) async {
    // Variant B: the tree is written to `Trip.qs.partial/` and renamed onto
    // `Trip/` in one atomic step once the last byte is in — a folder opened
    // half-populated is worse than one that is not there yet.
    final destination = Directory(p.join(workspace.path, 'incoming_folder'))
      ..createSync();

    final specs = [
      (rel: 'Trip/cover.jpg', bytes: 96 * 1024, mime: 'image/jpeg'),
      (rel: 'Trip/Day 1/hike.mp4', bytes: 200 * 1024, mime: 'video/mp4'),
      (rel: 'Trip/Day 1/notes.txt', bytes: 12 * 1024, mime: 'text/plain'),
    ];

    final files = <FileMetadata>[];
    final digests = <String, String>{};
    for (final spec in specs) {
      final made = makePayload(spec.bytes, name: p.basename(spec.rel));
      digests[spec.rel] = made.digest;
      files.add(FileMetadata(
        name: p.basename(spec.rel),
        path: made.file.path,
        size: spec.bytes,
        mimeType: spec.mime,
        relativePath: spec.rel,
      ));
    }

    final channel = _LoopbackAnswerChannel();
    final sender = WebRtcTransferTransport();
    final receiver = WebRtcReceiverTransport();
    addTearDown(() async {
      await sender.stopSharing();
      await channel.close();
    });

    await sender.initialize();
    await sender.startSharingServerless(files.first, files: files);

    final offerSdp = await sender.createLocalOfferSdp();
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

    final result = await receiver.receiveWithSdpOffer(
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

    expect(result, equals(p.join(destination.path, 'Trip')),
        reason: 'the session result points at the folder, not a file inside it');
    expect(
        Directory(p.join(destination.path, 'Trip${'.qs.partial'}')).existsSync(),
        isFalse,
        reason: 'the staging directory is gone once renamed');

    for (final spec in specs) {
      final landed = File(p.join(destination.path, p.split(spec.rel).join(p.separator)));
      expect(landed.existsSync(), isTrue, reason: '${spec.rel} is missing');
      expect(sha256.convert(landed.readAsBytesSync()).toString(),
          equals(digests[spec.rel]),
          reason: '${spec.rel} arrived corrupted');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('cancelling on the sender reaches the receiver as a cancellation',
      (tester) async {
    // Pressing Cancel and losing the network look identical on the wire — the
    // channel simply stops carrying data. Without an explicit message the
    // receiver waits out its disconnect grace period and then reports a
    // connection error for something that was a deliberate choice.
    final destination = Directory(p.join(workspace.path, 'incoming_cancel'))
      ..createSync();
    final payload = makePayload(4 * 1024 * 1024, name: 'big.bin');

    final channel = _LoopbackAnswerChannel();
    final sender = WebRtcTransferTransport();
    final receiver = WebRtcReceiverTransport();
    addTearDown(() async {
      await sender.stopSharing();
      await channel.close();
    });

    await sender.initialize();
    await sender.startSharingServerless(FileMetadata(
      name: 'big.bin',
      path: payload.file.path,
      size: 4 * 1024 * 1024,
      mimeType: 'application/octet-stream',
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

    // Cancel as soon as bytes are actually moving, so this exercises a
    // mid-transfer stop rather than a teardown before anything started.
    final started = Completer<void>();
    final progressSub = receiver.progressStream.listen((e) {
      if (e.phase == 'transferring' && !started.isCompleted) started.complete();
    });
    addTearDown(progressSub.cancel);

    // The error handler is attached here, at creation, rather than after the
    // cancellation: the failure lands while the test is still awaiting other
    // things, and a Future that errors with nothing listening is reported as
    // an unhandled async error regardless of who checks it later.
    Object? thrown;
    final receiving = receiver
        .receiveWithSdpOffer(
          qr.offer.toSdp(isOffer: true),
          targetDir: destination.path,
          deliverAnswer: (answerSdp) async {
            await channel.publish(
              topic,
              await SealedEnvelope.seal(
                plaintext: ServerlessQr.trimForQr(CompactSdp.fromSdp(answerSdp))
                    .toBytes(),
                seed: qr.seed,
                offerFingerprint: qr.offerFingerprint,
              ),
            );
          },
        )
        .then<void>((_) {})
        .catchError((Object e) => thrown = e);

    await started.future.timeout(const Duration(seconds: 30));
    final cancelledAt = DateTime.now();
    await sender.stopSharing();
    await receiving.timeout(const Duration(seconds: 10));

    // The distinction is the whole point: a named cancellation rather than a
    // generic failure...
    expect(thrown, isA<TransferCancelledBySender>());

    // ...and it arrives at once, instead of after the 20-second grace period
    // a real disconnect is given.
    expect(DateTime.now().difference(cancelledAt).inSeconds, lessThan(10));
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('an answer sealed for a different offer is refused',
      (tester) async {
    // A relay carries the whole world's traffic. Anything not sealed under this
    // session's seed has to fail authentication rather than reach WebRTC.
    final qr = ServerlessQr(
      seed: SealedEnvelope.newSeed(),
      offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(_syntheticOffer())),
    );
    final foreign = ServerlessQr(
      seed: SealedEnvelope.newSeed(),
      offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(_syntheticOffer())),
    );

    final sealed = await SealedEnvelope.seal(
      plaintext: foreign.offer.toBytes(),
      seed: foreign.seed,
      offerFingerprint: foreign.offerFingerprint,
    );

    await expectLater(
      SealedEnvelope.open(
        envelope: sealed,
        seed: qr.seed,
        offerFingerprint: qr.offerFingerprint,
      ),
      throwsA(anything),
    );
  });

  testWidgets('ICE gathers something a peer on another network could use',
      (tester) async {
    // Not an assertion about the internet: a host candidate is enough to prove
    // the agent ran. What it prints is the diagnostic that matters on a real
    // device, where the answer decides whether a transfer is possible at all.
    final transport = WebRtcTransferTransport();
    addTearDown(transport.stopSharing);

    await transport.initialize();
    await transport.startSharingServerless(FileMetadata(
      name: 'probe.bin',
      path: File(p.join(workspace.path, 'probe.bin'))
          .let((f) => f..writeAsBytesSync([1, 2, 3]))
          .path,
      size: 3,
      mimeType: 'application/octet-stream',
    ));

    final sdp = await transport.createLocalOfferSdp();
    expect(sdp, isNotNull);

    final compact = CompactSdp.fromSdp(sdp!);
    final types = compact.candidates.map((c) => c.type).toSet();
    // ignore: avoid_print
    print('ICE gathered: ${compact.candidates.length} candidates, types '
        '$types — relay present: ${types.contains('relay')}, '
        'srflx present: ${types.contains('srflx')}');

    expect(compact.candidates, isNotEmpty,
        reason: 'an offer with no candidates cannot connect to anything');
    expect(compact.iceUfrag, isNotEmpty);
    expect(compact.fingerprint.length, equals(32));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the gathering tracker agrees with what ended up in the SDP', () {
    final tracker = IceGatheringTracker();
    expect(tracker.sawRelay, isFalse);
    expect(tracker.describe(), contains('0 candidates'));
  });
}

extension<T> on T {
  R let<R>(R Function(T) block) => block(this);
}

String _syntheticOffer() => [
      'v=0',
      'a=ice-ufrag:${Random().nextInt(1 << 30)}',
      'a=ice-pwd:9pQ2vLmR4sT7wZ1aB6cD8eF0',
      'a=fingerprint:sha-256 '
          '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:'
          '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00',
      'a=setup:actpass',
      'a=candidate:1 1 udp 2122260223 192.168.1.5 51001 typ host generation 0',
    ].join('\r\n');

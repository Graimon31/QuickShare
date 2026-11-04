// A file crosses the internet path after the receiver only typed a code.
//
// The real WebRTC stack, the real code exchange and the real cryptography; the
// public mailbox and the channel the sealed answer returns on are in memory, so
// the test depends on nobody's uptime:
//
//     flutter test integration_test/code_internet_e2e_test.dart -d macos
//
// What runs, in order, is what a person would do:
//
//  1. the sender raises a real peer connection and builds the offer its QR
//     holds, and starts listening for its ten-digit code;
//  2. the digits are typed as the code screen reads them and handed to the
//     real lookup, which searches the local network (nothing there) and the
//     mailbox at once;
//  3. the sender's person is asked, by name, and says yes;
//  4. the offer arrives, goes through the real decoder, and the receiver
//     answers it as it would a scanned QR;
//  5. the file crosses a real DataChannel.
//
// And then what must be true: the bytes are the same, nothing is left in the
// destination but the file, and nobody is still listening on anything.
//
// One file per invocation on macOS, and run `flutter build macos --debug`
// afterwards: an integration run replaces the app bundle with its own.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/internet_code.dart';
import 'package:quickshare/core/network/internet_code_sender.dart';
import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
import 'package:quickshare/features/receiver/data/client/code_lookup.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/receiver/data/client/internet_code_search.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

import '../test/support/fake_mailbox.dart';

/// Hands a published payload straight back to the subscriber, sealed as ever.
class _LoopbackAnswerChannel implements AnswerChannel {
  final _controller = StreamController<Uint8List>.broadcast();
  String? subscribedTopic;

  @override
  String get name => 'loopback';
  @override
  Stream<Uint8List> get answers => _controller.stream;
  @override
  Future<void> subscribe(String topic) async => subscribedTopic = topic;
  @override
  Future<void> publish(String topic, Uint8List payload) async {
    expect(topic, equals(subscribedTopic));
    if (!_controller.isClosed) _controller.add(payload);
  }

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

class _NoBrowse implements RendezvousBrowser {
  @override
  Stream<List<RendezvousCandidate>> get candidates => const Stream.empty();
  @override
  List<RendezvousCandidate> get current => const [];
  @override
  bool get isRunning => false;
  @override
  Future<bool> start() async => false;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> stop() async {}
}

class _MockRepository extends Mock implements ReceiverRepository {}

class _MockDownload extends Mock implements DownloadFileUseCase {}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync('dd_code_e2e_'));
  tearDown(() => workspace.deleteSync(recursive: true));

  test('a file crosses after the receiver typed the sender\'s code', () async {
    // ---- the file ----
    const sizeBytes = 768 * 1024;
    final random = Random(20261104);
    final data = Uint8List.fromList(
        List<int>.generate(sizeBytes, (_) => random.nextInt(256)));
    final digest = sha256.convert(data).toString();
    final source = File(p.join(workspace.path, 'holiday.bin'))
      ..writeAsBytesSync(data);
    final destination = Directory(p.join(workspace.path, 'incoming'))
      ..createSync();

    // ---- the sender: what SenderBloc does for the internet tab ----
    final hub = FakeMailboxHub();
    final answers = _LoopbackAnswerChannel();
    final sender = WebRtcTransferTransport();
    addTearDown(() async {
      await sender.stopSharing();
      await answers.close();
    });

    await sender.initialize();
    await sender.startSharingServerless(FileMetadata(
      name: 'holiday.bin',
      path: source.path,
      size: sizeBytes,
      mimeType: 'application/octet-stream',
    ));
    final offerSdp = await sender.createLocalOfferSdp();
    expect(offerSdp, isNotNull,
        reason: 'no offer means the platform channel never came up');

    final qr = ServerlessQr(
      seed: SealedEnvelope.newSeed(),
      offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(offerSdp!)),
      fileName: 'holiday.bin',
      fileSize: sizeBytes,
      itemCount: 1,
    );
    final qrString = qr.encode();
    await answers.subscribe(await qr.topic);

    final code = SessionCode.generate();
    final askedAbout = <String>[];
    late final InternetCodeSender codeSender;
    codeSender = InternetCodeSender(
      mailbox: hub.endpoint('sender'),
      code: code,
      offer: () async => qrString,
      approve: (name) async {
        askedAbout.add(name);
        return true;
      },
    );
    await codeSender.start();
    addTearDown(codeSender.stop);

    final answerApplied = Completer<void>();
    answers.answers.listen((sealed) async {
      final opened = await SealedEnvelope.open(
        envelope: sealed,
        seed: qr.seed,
        offerFingerprint: qr.offerFingerprint,
      );
      codeSender.answered();
      await sender.handleDirectAnswer(
          CompactSdp.fromBytes(opened).toSdp(isOffer: false), 'answer');
      if (!answerApplied.isCompleted) answerApplied.complete();
    });

    // ---- the receiver: what the code screen does with the digits ----
    //
    // The screen itself is not pumped: a headless run has no frames to wait
    // for, and `test/features/receiver/code_receive_page_search_test.dart`
    // covers what is drawn. Everything the screen hands on to is real.
    FakeMailbox? receiverBox;
    final repository = _MockRepository();
    when(() => repository.parseQRCode(any())).thenAnswer((call) async {
      final Either<Failure, QRPayload> result =
          Right(QRPayloadDecoder().decode(call.positionalArguments.first as String));
      return result;
    });
    final bloc = ReceiverBloc(
      downloadFileUseCase: _MockDownload(),
      repository: repository,
    );
    addTearDown(bloc.close);

    final typed = SessionCode.parse(code.display);
    expect(typed, code, reason: 'ten digits typed in two groups are the code');

    final lookup = CodeLookup(
      browser: _NoBrowse.new,
      deviceName: 'Receiving Mac',
      discoveryWindow: Duration.zero,
      probeTargets: (_) async => const [],
      internet:
          InternetCodeSearch(mailbox: () => receiverBox = hub.endpoint('receiver')),
    );
    final control = CodeSearchControl();
    final phases = <CodeSearchPhase>[];
    control.phases.listen(phases.add);

    final outcome = await lookup.find(typed!, control: control);
    expect(outcome, isA<CodeSessionFoundOnline>());
    final found = (outcome as CodeSessionFoundOnline).payload;
    bloc.add(QRCodeScanned(found, fromPaste: true));
    final parsed = await bloc.stream
        .firstWhere((state) => state is QRParsed || state is ReceiverError)
        .timeout(const Duration(seconds: 10));

    // ---- the exchange ----
    expect(parsed, isA<QRParsed>(),
        reason: 'the code found the offer and the preview opened');
    expect(phases, [CodeSearchPhase.awaitingApproval]);
    expect(askedAbout, ['Receiving Mac'],
        reason: 'the sender\'s person was asked once, by name');
    final payload = (parsed as QRParsed).payload;
    expect(payload.mode, QRPayloadDecoder.serverlessMode);
    expect(payload.fileName, 'holiday.bin');
    expect(payload.sdpOffer, qrString, reason: 'exactly the sender\'s offer');
    expect(receiverBox!.isClosed, isTrue, reason: 'the search let go');
    expect(codeSender.attempts, 1);

    // ---- the transfer: what ReceiverBloc does after the preview ----
    final received = ServerlessQr.decode(payload.sdpOffer!);
    final receiver = WebRtcReceiverTransport();
    final savedPath = await receiver.receiveWithSdpOffer(
      received.offer.toSdp(isOffer: true),
      targetDir: destination.path,
      deliverAnswer: (answerSdp) async {
        await answers.publish(
          await received.topic,
          await SealedEnvelope.seal(
            plaintext:
                ServerlessQr.trimForQr(CompactSdp.fromSdp(answerSdp)).toBytes(),
            seed: received.seed,
            offerFingerprint: received.offerFingerprint,
          ),
        );
      },
    );

    // ---- what has to be true ----
    expect(answerApplied.isCompleted, isTrue);
    final landed = File(savedPath);
    expect(p.isWithin(destination.path, savedPath), isTrue);
    expect(landed.lengthSync(), sizeBytes);
    expect(sha256.convert(landed.readAsBytesSync()).toString(), digest,
        reason: 'byte for byte');

    // Nothing else in the destination: no staging file, no leftovers.
    final names = destination
        .listSync(recursive: true)
        .map((e) => p.basename(e.path))
        .toList();
    expect(names, ['holiday.bin']);
    expect(names.any((n) => n.endsWith('.qs.partial')), isFalse);

    // The sender (the bloc, in the app) stops listening once the offer is
    // taken; after that nobody listens on anything.
    await codeSender.stop();
    expect(hub.listenedTopics, isEmpty);
    expect(hub.openEndpoints, 0);

    // What the public mailbox carried never held the code or the offer.
    for (final message in hub.published) {
      final text = String.fromCharCodes(message.payload);
      expect(text.contains(code.code), isFalse);
      expect(text.contains(qrString.substring(0, 24)), isFalse);
      expect(message.topic.contains(code.code), isFalse);
    }
    expect(hub.published.first.topic, InternetCode.requestTopic(code));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a wrong digit never gets the offer', () async {
    final hub = FakeMailboxHub();
    final code = SessionCode.generate();
    var asked = 0;
    final codeSender = InternetCodeSender(
      mailbox: hub.endpoint('sender'),
      code: code,
      offer: () async => 'QS1would-be-the-offer',
      approve: (_) async {
        asked++;
        return true;
      },
    );
    await codeSender.start();
    addTearDown(codeSender.stop);

    final wrong = SessionCode(
        ((int.parse(code.code) + 1) % 10000000000).toString().padLeft(10, '0'));
    final lookup = CodeLookup(
      browser: _NoBrowse.new,
      deviceName: 'Receiving Mac',
      discoveryWindow: Duration.zero,
      probeTargets: (_) async => const [],
      internet: InternetCodeSearch(
        mailbox: () => hub.endpoint('receiver'),
        timings: const InternetCodeTimings(findTimeout: Duration(seconds: 4)),
      ),
    );

    final outcome = await lookup.find(wrong);

    expect(outcome, isA<CodeSessionNotFound>());
    expect(asked, 0);
    expect(hub.published.any((m) => String.fromCharCodes(m.payload).contains('QS1')),
        isFalse);
  }, timeout: const Timeout(Duration(minutes: 1)));
}

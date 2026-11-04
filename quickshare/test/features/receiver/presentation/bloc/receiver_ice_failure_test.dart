// NET-02 — what the RECEIVER says when the connection cannot be made.
//
// The receiver used to fail with `Serverless transfer failed: Exception:
// receiveWithSdpOffer failed: ...` whatever the cause. It fetches its own relay
// credentials from the Worker, so it knows its own side of the story: whether
// the relay was rate-limited, unreachable, switched off, or available and
// still not enough. That reason now travels from ICE setup, through the
// transport's typed failure, to the code the screen translates.
//
// The transport itself calls `createPeerConnection`, which has no platform
// channel under `flutter test`, so it is replaced by a mock that fails the way
// the real one now does; the bloc, the failure code and the translation are
// the real ones.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/l10n/localized_labels.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
import 'package:quickshare/core/webrtc/relay_availability.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class _MockDownload extends Mock implements DownloadFileUseCase {}

class _MockRepository extends Mock implements ReceiverRepository {}

class _MockTransport extends Mock implements WebRtcReceiverTransport {}

const _offer = '''v=0
o=- 4611731400430051336 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=ice-ufrag:F7gI
a=ice-pwd:x9cO/TDwjM9zPCTFEJUUS9nJ
a=fingerprint:sha-256 8F:BF:9A:F5:5A:AE:1C:2C:1D:BE:1E:1A:33:6C:A1:9B:11:B2:CE:1B:4A:36:1E:4B:1B:6A:1C:F1:0E:2B:3A:5C
a=setup:actpass
a=mid:0
a=sctp-port:5000
a=candidate:0 1 udp 2122260223 192.168.3.1 40000 typ host generation 0
a=candidate:1 1 udp 1686052607 203.0.113.9 40001 typ srflx generation 0
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late _MockTransport transport;
  late ReceiverBloc bloc;
  late QRPayload payload;

  setUpAll(() {
    final qr = ServerlessQr(
      seed: SealedEnvelope.newSeed(),
      offer: CompactSdp.fromSdp(_offer),
      fileName: 'photo.jpg',
      fileSize: 1024,
      itemCount: 1,
    ).encode();
    payload = QRPayload(
      version: 2,
      ip: '',
      port: 0,
      token: '',
      mode: QRPayloadDecoder.serverlessMode,
      sdpOffer: qr,
    );
  });

  setUp(() {
    // path_provider has no platform side under `flutter test`; the receiver
    // asks for a destination folder before it ever reaches the transport.
    sandbox = Directory.systemTemp.createTempSync('receiver_ice_failure');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => sandbox.path,
    );

    transport = _MockTransport();
    when(() => transport.progressStream).thenAnswer((_) => const Stream.empty());
    when(() => transport.cancel()).thenAnswer((_) async {});

    bloc = ReceiverBloc(
      downloadFileUseCase: _MockDownload(),
      repository: _MockRepository(),
      serverlessTransportFactory: () => transport,
    );
  });

  tearDown(() async {
    await bloc.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    sandbox.deleteSync(recursive: true);
  });

  void failWith(Object error) {
    when(() => transport.receiveWithSdpOffer(
          any(),
          targetDir: any(named: 'targetDir'),
          deliverAnswer: any(named: 'deliverAnswer'),
        )).thenThrow(error);
  }

  Future<ReceiverError> runAndGetError() async {
    final error = bloc.stream
        .firstWhere((s) => s is ReceiverError)
        .timeout(const Duration(seconds: 10));
    bloc.add(StartDownload(payload: payload));
    return await error as ReceiverError;
  }

  group('the receiver names the relay\'s state in its own failure', () {
    const cases = <String, ({NoPathDiagnosis diagnosis, String code})>{
      'rate limited': (
        diagnosis: NoPathDiagnosis(
          relayUnavailable: RelayUnavailable(RelayUnavailableReason.rateLimited,
              retryAfter: Duration(seconds: 60), statusCode: 429),
          candidates: '2 candidates (srflx: true, relay: false)',
          selectedPair: 'none',
        ),
        code: FailureCode.noPathRelayLimited,
      ),
      'unreachable': (
        diagnosis: NoPathDiagnosis(
          relayUnavailable: RelayUnavailable(RelayUnavailableReason.timeout),
        ),
        code: FailureCode.noPathRelayUnreachable,
      ),
      'switched off': (
        diagnosis: NoPathDiagnosis(
          relayUnavailable:
              RelayUnavailable(RelayUnavailableReason.relayUnconfigured),
        ),
        code: FailureCode.noPathRelayOff,
      ),
      'relay was available': (
        diagnosis: NoPathDiagnosis(selectedPair: 'none'),
        code: FailureCode.noPathRelayWasAvailable,
      ),
    };

    for (final entry in cases.entries) {
      test('${entry.key}: ReceiverError carries ${entry.value.code}', () async {
        failWith(IceNegotiationFailed(entry.value.diagnosis));

        final error = await runAndGetError();

        expect(error.code, equals(entry.value.code));
        // English for the log and the copied diagnostics, with the evidence.
        expect(error.message, contains('selected pair'));
      });
    }

    test('a failure that is not about ICE keeps its own text and no code',
        () async {
      failWith(Exception('disk full'));

      final error = await runAndGetError();

      expect(error.code, isNull);
      expect(error.message, contains('disk full'));
    });
  });

  group('what the screen shows for each of them', () {
    late AppLocalizations en;
    late AppLocalizations ru;

    setUpAll(() async {
      en = await AppLocalizations.delegate.load(const Locale('en'));
      ru = await AppLocalizations.delegate.load(const Locale('ru'));
    });

    String shown(AppLocalizations l10n, String code) =>
        localizedFailure(l10n, code: code, fallback: 'FELL BACK');

    const codes = [
      FailureCode.noPathRelayLimited,
      FailureCode.noPathRelayUnreachable,
      FailureCode.noPathRelayOff,
      FailureCode.noPathRelayWasAvailable,
    ];

    test('four causes, four different sentences, in both languages', () {
      expect({for (final c in codes) shown(en, c)}, hasLength(4));
      expect({for (final c in codes) shown(ru, c)}, hasLength(4));
      for (final c in codes) {
        expect(shown(en, c), isNot('FELL BACK'));
      }
    });

    test('a limited relay says to try again in about a minute', () {
      expect(shown(en, FailureCode.noPathRelayLimited),
          contains('about a minute'));
    });

    test('an unreachable relay service says so', () {
      expect(shown(en, FailureCode.noPathRelayUnreachable),
          contains('could not be reached'));
    });

    test('a relay that is off says it is switched off or not configured', () {
      final text = shown(en, FailureCode.noPathRelayOff);
      expect(text, contains('switched off'));
      expect(text, contains('not configured'));
    });

    test('a relay that was available does not blame the relay', () {
      final text = shown(en, FailureCode.noPathRelayWasAvailable);
      expect(text, contains('relay was available'));
      expect(text, isNot(contains('could not be reached')));
      expect(text, isNot(contains('about a minute')));
      expect(text, isNot(contains('switched off')));
    });
  });
}

// What the receiving screen is told when the disk, not the network, stops a
// transfer: a full volume, a link in the destination, a session that cannot
// fit. The transports raise a coded `FileException`; the bloc has to carry the
// code to the screen unchanged, because the code is what becomes a sentence in
// the user's language — and the generic "Serverless transfer failed: Exception:
// ..." / "Bluetooth transfer failed" is exactly what a person cannot act on.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/l10n/localized_labels.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/storage/receive_destination.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_session.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

import '../../../../support/scratch_path_provider.dart';

class _MockDownload extends Mock implements DownloadFileUseCase {}

class _MockRepository extends Mock implements ReceiverRepository {}

class _MockTransport extends Mock implements WebRtcReceiverTransport {}

class _MockSession extends Mock implements BluetoothReceiverSession {}

class _FakeDestination extends Fake implements ReceiveDestination {}

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
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late _MockTransport transport;
  late _MockSession session;
  late ReceiverBloc bloc;
  late QRPayload webrtcPayload;
  late AppLocalizations ru;

  setUpAll(() async {
    registerFallbackValue(_FakeDestination());
    ru = await AppLocalizations.delegate.load(const Locale('ru'));
    final qr = ServerlessQr(
      seed: SealedEnvelope.newSeed(),
      offer: CompactSdp.fromSdp(_offer),
      fileName: 'photo.jpg',
      fileSize: 1024,
      itemCount: 1,
    ).encode();
    webrtcPayload = QRPayload(
      version: 2,
      ip: '',
      port: 0,
      token: '',
      mode: QRPayloadDecoder.serverlessMode,
      sdpOffer: qr,
    );
  });

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('receiver_storage_failure');
    answerPathProviderWith(sandbox.path);

    transport = _MockTransport();
    when(() => transport.progressStream).thenAnswer((_) => const Stream.empty());
    when(() => transport.cancel()).thenAnswer((_) async {});
    session = _MockSession();
    when(() => session.cancel()).thenAnswer((_) async {});

    bloc = ReceiverBloc(
      downloadFileUseCase: _MockDownload(),
      repository: _MockRepository(),
      serverlessTransportFactory: () => transport,
      bluetoothSessionFactory: () => session,
    );
  });

  tearDown(() async {
    await bloc.close();
    sandbox.deleteSync(recursive: true);
  });

  Future<ReceiverError> runAndGetError(QRPayload payload) async {
    final error = bloc.stream
        .firstWhere((s) => s is ReceiverError)
        .timeout(const Duration(seconds: 10));
    bloc.add(StartDownload(payload: payload));
    return await error as ReceiverError;
  }

  group('over the internet', () {
    test('a full disk reaches the screen as the full-disk code', () async {
      when(() => transport.receiveWithSdpOffer(
            any(),
            targetDir: any(named: 'targetDir'),
            deliverAnswer: any(named: 'deliverAnswer'),
          )).thenThrow(const FileException('The disk is full', FailureCode.diskFull));

      final error = await runAndGetError(webrtcPayload);

      expect(error.code, FailureCode.diskFull);
      expect(error.message, 'The disk is full');
      expect(
          localizedFailure(ru, code: error.code, fallback: error.message),
          isNot(error.message));
    });

    test('a session that cannot fit carries both sizes to the screen',
        () async {
      final code = FailureCode.notEnoughSpaceFor(5 * 1000 * 1000 * 1000, 2000000);
      when(() => transport.receiveWithSdpOffer(
            any(),
            targetDir: any(named: 'targetDir'),
            deliverAnswer: any(named: 'deliverAnswer'),
          )).thenThrow(FileException('Not enough free space', code));

      final error = await runAndGetError(webrtcPayload);

      final shown = localizedFailure(ru, code: error.code, fallback: 'RAW');
      expect(shown, contains('5.0 GB'));
      expect(shown, contains('2.0 MB'));
    });
  });

  group('over Bluetooth', () {
    const payload = QRPayload(
      version: 2,
      ip: 'bt',
      port: 0,
      token: 'tok',
      sessionId: 'pub',
      mode: QRPayloadDecoder.bluetoothMode,
    );

    void sessionFails(Object error) {
      when(() => session.run(
            token: any(named: 'token'),
            publicId: any(named: 'publicId'),
            destination: any(named: 'destination'),
            onProgress: any(named: 'onProgress'),
            onVerifying: any(named: 'onVerifying'),
          )).thenThrow(error);
    }

    test('a storage problem keeps its own code', () async {
      sessionFails(const FileException(
          'Refusing to write', FailureCode.unsafeDestination));

      final error = await runAndGetError(payload);

      expect(error.code, FailureCode.unsafeDestination);
      expect(error.message, 'Refusing to write');
    });

    test('anything else is still the generic Bluetooth failure', () async {
      sessionFails(Exception('lost the sender'));

      final error = await runAndGetError(payload);

      expect(error.code, isNull,
          reason: 'unchanged: the screen shows the message itself');
      expect(error.message, contains('lost the sender'));
    });
  });
}

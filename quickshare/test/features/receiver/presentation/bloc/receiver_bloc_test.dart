import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/errors/failures.dart';

import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_session.dart';

class MockDownloadFileUseCase extends Mock implements DownloadFileUseCase {}
class MockReceiverRepository extends Mock implements ReceiverRepository {}
class MockWebRtcReceiverTransport extends Mock implements WebRtcReceiverTransport {}
class MockBluetoothReceiverSession extends Mock implements BluetoothReceiverSession {}

void main() {
  late ReceiverBloc receiverBloc;
  late MockDownloadFileUseCase mockDownloadFileUseCase;
  late MockReceiverRepository mockReceiverRepository;

  const tPayload = QRPayload(
    version: 1,
    ip: '192.168.1.100',
    port: 8080,
    token: 'test_token',
    fileName: 'test.jpg',
    fileSize: 1024,
    checksum: 'abc',
  );

  setUpAll(() {
    registerFallbackValue(tPayload);
  });

  setUp(() {
    mockDownloadFileUseCase = MockDownloadFileUseCase();
    mockReceiverRepository = MockReceiverRepository();
    receiverBloc = ReceiverBloc(
      downloadFileUseCase: mockDownloadFileUseCase,
      repository: mockReceiverRepository,
    );
  });

  tearDown(() {
    receiverBloc.close();
  });

  test('initial state should be ReceiverInitial', () {
    expect(receiverBloc.state, equals(ReceiverInitial()));
  });

  test('should emit Scanning when StartScanning event is added', () {
    receiverBloc.add(StartScanning());
    expectLater(
      receiverBloc.stream,
      emitsInOrder([Scanning()]),
    );
  });

  test('should emit QRParsed when valid QR code is scanned', () async {
    const rawQr = 'quickshare://192.168.1.100:8080/test.jpg';
    when(() => mockReceiverRepository.parseQRCode(rawQr))
        .thenAnswer((_) async => const Right(tPayload));

    receiverBloc.add(const QRCodeScanned(rawQr));

    await expectLater(
      receiverBloc.stream,
      emitsInOrder([const QRParsed(tPayload)]),
    );
  });

  test('should emit ReceiverError when invalid QR code is scanned', () async {
    const rawQr = 'invalid_qr_string';
    when(() => mockReceiverRepository.parseQRCode(rawQr))
        .thenAnswer((_) async => const Left(ServerFailure('Invalid QR format')));

    receiverBloc.add(const QRCodeScanned(rawQr));

    await expectLater(
      receiverBloc.stream,
      emitsInOrder([
        isA<ReceiverError>().having(
          (e) => e.message,
          'message',
          contains('Invalid QR Code'),
        ),
      ]),
    );
  });

  test('paste failures do not tell the user to point a camera', () async {
    const raw = 'directdrop://join?p=not-a-payload';
    when(() => mockReceiverRepository.parseQRCode(raw))
        .thenAnswer((_) async => const Left(FileFailure('Invalid QR Code')));

    final seen = expectLater(
      receiverBloc.stream,
      emits(isA<ReceiverError>().having(
        (e) => e.message,
        'message',
        contains('share link'),
      )),
    );
    receiverBloc.add(const QRCodeScanned(raw, fromPaste: true));
    await seen;
  });

  test('a second failed paste still emits so the Receive button unsticks',
      () async {
    const raw = 'nope';
    when(() => mockReceiverRepository.parseQRCode(raw))
        .thenAnswer((_) async => const Left(FileFailure('Invalid QR Code')));

    final first = expectLater(
      receiverBloc.stream,
      emits(isA<ReceiverError>()),
    );
    receiverBloc.add(const QRCodeScanned(raw, fromPaste: true));
    await first;

    final second = expectLater(
      receiverBloc.stream,
      emitsInOrder([
        isA<ReceiverInitial>(),
        isA<ReceiverError>(),
      ]),
    );
    receiverBloc.add(const QRCodeScanned(raw, fromPaste: true));
    await second;
  });

  test('should emit ReceiverInitial when CancelDownload event is added', () async {
    when(() => mockReceiverRepository.cancelDownload()).thenReturn(null);

    final expectation = expectLater(
      receiverBloc.stream,
      emitsInOrder([ReceiverInitial()]),
    );

    receiverBloc.add(CancelDownload());

    await expectation;
    verify(() => mockReceiverRepository.cancelDownload()).called(1);
  });

  test('CancelDownload cancels active serverless transport', () async {
    final mockTransport = MockWebRtcReceiverTransport();
    when(() => mockTransport.cancel()).thenAnswer((_) async {});
    when(() => mockReceiverRepository.cancelDownload()).thenReturn(null);

    receiverBloc.serverlessTransport = mockTransport;
    receiverBloc.add(CancelDownload());

    await expectLater(
      receiverBloc.stream,
      emits(ReceiverInitial()),
    );

    verify(() => mockTransport.cancel()).called(1);
    expect(receiverBloc.serverlessTransport, isNull);
  });

  test('should emit QRParsed with preview when Bluetooth QR code is scanned', () async {
    const btPayload = QRPayload(
      version: 2,
      ip: 'bt',
      port: 0,
      token: 'token123',
      sessionId: 'cid123',
      mode: 'bluetooth',
      fileName: 'Docs',
      fileSize: 2048,
      itemCount: 3,
      senderName: 'Sender Mac',
    );
    const rawQr = 'quickshare-bt:v1:...';
    when(() => mockReceiverRepository.parseQRCode(rawQr))
        .thenAnswer((_) async => const Right(btPayload));

    final expectation = expectLater(
      receiverBloc.stream,
      emitsInOrder([
        predicate<ReceiverState>((state) {
          if (state is! QRParsed) return false;
          return state.payload == btPayload &&
              state.qhtpPreview?.itemCount == 3 &&
              state.qhtpPreview?.totalBytes == 2048 &&
              state.qhtpPreview?.senderName == 'Sender Mac';
        }),
      ]),
    );

    receiverBloc.add(const QRCodeScanned(rawQr));

    await expectation;
    verifyNever(() => mockReceiverRepository.fetchQhtpSessionPreview(any()));
  });

  test('CancelDownload cancels active bluetooth session', () async {
    final mockBtSession = MockBluetoothReceiverSession();
    when(() => mockBtSession.cancel()).thenAnswer((_) => Future<void>.value());
    when(() => mockReceiverRepository.cancelDownload()).thenReturn(null);

    receiverBloc.bluetoothSession = mockBtSession;
    receiverBloc.add(CancelDownload());

    await expectLater(
      receiverBloc.stream,
      emits(ReceiverInitial()),
    );

    verify(() => mockBtSession.cancel()).called(1);
    expect(receiverBloc.bluetoothSession, isNull);
  });
}

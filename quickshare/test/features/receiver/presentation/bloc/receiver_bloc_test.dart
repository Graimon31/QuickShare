import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/errors/failures.dart';

class MockDownloadFileUseCase extends Mock implements DownloadFileUseCase {}
class MockReceiverRepository extends Mock implements ReceiverRepository {}

void main() {
  late ReceiverBloc receiverBloc;
  late MockDownloadFileUseCase mockDownloadFileUseCase;
  late MockReceiverRepository mockReceiverRepository;

  final tPayload = QRPayload(
    version: 1,
    ip: '192.168.1.100',
    port: 8080,
    token: 'test_token',
    fileName: 'test.jpg',
    fileSize: 1024,
    checksum: 'abc',
  );

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
        .thenAnswer((_) async => Right(tPayload));

    receiverBloc.add(const QRCodeScanned(rawQr));

    await expectLater(
      receiverBloc.stream,
      emitsInOrder([QRParsed(tPayload)]),
    );
  });

  test('should emit ReceiverError when invalid QR code is scanned', () async {
    const rawQr = 'invalid_qr_string';
    when(() => mockReceiverRepository.parseQRCode(rawQr))
        .thenAnswer((_) async => Left(const ServerFailure('Invalid QR format')));

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
}

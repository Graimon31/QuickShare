// Scanning a Bluetooth QR is how a phone receives over Bluetooth, and the QR is
// the only thing that starts it: what it carries — the session token and the
// public identifier the sender advertises — is what the receiving session is
// started with, and nothing else is set going before the scan.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/storage/receive_destination.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_session.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

import '../../support/scratch_path_provider.dart';

class _MockDownload extends Mock implements DownloadFileUseCase {}

class _MockRepository extends Mock implements ReceiverRepository {}

class _MockSession extends Mock implements BluetoothReceiverSession {}

class _FakeDestination extends Fake implements ReceiveDestination {}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const bluetooth = MethodChannel('quickshare/bluetooth');

  late Directory sandbox;
  late List<String> radioCalls;
  late _MockRepository repository;
  late _MockSession session;
  late ReceiverBloc bloc;

  setUpAll(() => registerFallbackValue(_FakeDestination()));

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('bt_qr_session');
    radioCalls = [];
    answerPathProviderWith(sandbox.path);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(bluetooth, (call) async {
      radioCalls.add(call.method);
      return null;
    });

    repository = _MockRepository();
    session = _MockSession();
    when(() => session.cancel()).thenAnswer((_) async {});
    bloc = ReceiverBloc(
      downloadFileUseCase: _MockDownload(),
      repository: repository,
      bluetoothSessionFactory: () => session,
    );
  });

  tearDown(() async {
    await bloc.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(bluetooth, null);
    sandbox.deleteSync(recursive: true);
  });

  test('the token and the identifier in the QR are what the session is '
      'started with', () async {
    // A real QR, through the real decoder: the values below are the ones the
    // sender put in it.
    final raw = const BluetoothQrPayload(
      token: 'token-from-the-qr',
      locator: 'id-from-the-qr',
      fileName: 'Holiday photos',
      fileSize: 4096,
      itemCount: 2,
      senderName: 'Sender Mac',
    ).encode();
    final payload = QRPayloadDecoder().decode(raw);
    when(() => repository.parseQRCode(raw))
        .thenAnswer((_) async => Right(payload));
    when(() => session.run(
          token: any(named: 'token'),
          locator: any(named: 'locator'),
          destination: any(named: 'destination'),
          onProgress: any(named: 'onProgress'),
          onVerifying: any(named: 'onVerifying'),
        )).thenAnswer((_) async => BluetoothReceiverSessionResult(
          preferredPath: sandbox.path,
          displayName: 'Holiday photos',
          items: const [],
          placed: false,
        ));

    bloc.add(QRCodeScanned(raw));
    await bloc.stream.firstWhere((s) => s is QRParsed);
    expect(radioCalls, isEmpty,
        reason: 'reading a QR is not yet a reason to touch the radio');
    verifyNever(() => session.run(
          token: any(named: 'token'),
          locator: any(named: 'locator'),
          destination: any(named: 'destination'),
          onProgress: any(named: 'onProgress'),
          onVerifying: any(named: 'onVerifying'),
        ));

    bloc.add(const StartDownload());
    await bloc.stream
        .firstWhere((s) => s is DownloadComplete)
        .timeout(const Duration(seconds: 10));

    verify(() => session.run(
          token: 'token-from-the-qr',
          locator: 'id-from-the-qr',
          destination: any(named: 'destination'),
          onProgress: any(named: 'onProgress'),
          onVerifying: any(named: 'onVerifying'),
        )).called(1);
  });
}

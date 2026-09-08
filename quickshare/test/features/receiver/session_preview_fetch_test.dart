// What the accept screen says a session holds, when the session itself said
// nothing.
//
// A scanned QR spells out the name, the size and the count, so the screen can
// draw them straight away. A typed code spells out ten digits, and the
// announcement it is matched against carries no numbers either — deliberately,
// since a TXT record is readable by everyone on the network. So the screen was
// asking somebody to accept a transfer while showing them nothing about it.
//
// The numbers are asked for over the session instead, behind the token, and
// after the screen is already up: fetching them first is what used to freeze
// the scanner for twenty seconds on a network that would not answer.
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_session_preview.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class _MockDownloadFileUseCase extends Mock implements DownloadFileUseCase {}

class _MockReceiverRepository extends Mock implements ReceiverRepository {}

void main() {
  late ReceiverBloc bloc;
  late _MockReceiverRepository repository;

  /// What a typed code produces: enough to open a socket, and nothing to draw.
  const fromCode = QRPayload(
    version: 2,
    ip: '192.168.3.5',
    port: 8000,
    token: 'session-token',
    mode: 'http-lan',
    sessionId: 'session-token',
    tlsFingerprint: 'sender-cert',
  );

  /// What a scanned QR produces: the numbers travel in the payload.
  const fromQr = QRPayload(
    version: 2,
    ip: '192.168.3.5',
    port: 8000,
    token: 'session-token',
    mode: 'http-lan',
    sessionId: 'session-token',
    tlsFingerprint: 'sender-cert',
    fileName: 'Holiday',
    fileSize: 4200000,
    itemCount: 12,
  );

  setUpAll(() => registerFallbackValue(fromCode));

  setUp(() {
    repository = _MockReceiverRepository();
    bloc = ReceiverBloc(
      downloadFileUseCase: _MockDownloadFileUseCase(),
      repository: repository,
    );
  });

  tearDown(() => bloc.close());

  test('a session opened from a code asks the sender what it is sending',
      () async {
    when(() => repository.parseQRCode(any()))
        .thenAnswer((_) async => const Right(fromCode));
    when(() => repository.fetchQhtpSessionPreview(any())).thenAnswer(
      (_) async => const Right(QhtpSessionPreview(itemCount: 12, totalBytes: 4200000)),
    );

    bloc.add(const QRCodeScanned('anything', fromPaste: true));

    await expectLater(
      bloc.stream,
      emitsInOrder([
        // Up first, with nothing — navigation never waits on the network.
        const QRParsed(fromCode),
        // Then the answer, drawn into the screen already on show.
        const QRParsed(fromCode,
            qhtpPreview:
                QhtpSessionPreview(itemCount: 12, totalBytes: 4200000)),
      ]),
    );
  });

  test('a scanned QR is not asked, because it already said', () async {
    // The call this avoids is the one that froze the scanner. A payload
    // carrying its own numbers must never make it.
    when(() => repository.parseQRCode(any()))
        .thenAnswer((_) async => const Right(fromQr));

    bloc.add(const QRCodeScanned('anything'));

    await expectLater(
      bloc.stream,
      emitsInOrder([
        const QRParsed(fromQr,
            qhtpPreview: QhtpSessionPreview(itemCount: 12, totalBytes: 4200000)),
      ]),
    );
    verifyNever(() => repository.fetchQhtpSessionPreview(any()));
  });

  test('a sender that will not say still leaves the transfer usable', () async {
    // The numbers are a courtesy. Turning a missing subtitle into an error
    // would stop a transfer that works perfectly well.
    when(() => repository.parseQRCode(any()))
        .thenAnswer((_) async => const Right(fromCode));
    when(() => repository.fetchQhtpSessionPreview(any())).thenAnswer(
      (_) async => const Left(NetworkFailure('Failed to connect to sender.')),
    );

    bloc.add(const QRCodeScanned('anything', fromPaste: true));

    await expectLater(bloc.stream, emitsInOrder([const QRParsed(fromCode)]));
    // Still on the accept screen, with the payload it can transfer from.
    expect(bloc.state, equals(const QRParsed(fromCode)));
  });

  test('an answer for a session the user has left is dropped', () async {
    // The fetch outlives the screen that started it. Drawing its answer would
    // put one session's numbers over whatever replaced it.
    when(() => repository.parseQRCode(any()))
        .thenAnswer((_) async => const Right(fromCode));
    when(() => repository.fetchQhtpSessionPreview(any())).thenAnswer(
      (_) async => const Right(QhtpSessionPreview(itemCount: 1, totalBytes: 1)),
    );

    bloc.add(const QRCodeScanned('anything', fromPaste: true));
    await expectLater(bloc.stream, emits(const QRParsed(fromCode)));

    bloc.add(const QhtpPreviewFetched(
      QhtpSessionPreview(itemCount: 99, totalBytes: 99),
      fromQr, // a different session
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      (bloc.state as QRParsed).qhtpPreview?.itemCount,
      isNot(equals(99)),
      reason: 'the answer named another session',
    );
  });
}

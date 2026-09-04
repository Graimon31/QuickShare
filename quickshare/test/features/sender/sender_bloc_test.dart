import 'dart:async';
import 'dart:io';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';

import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';

import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';

class MockSenderRepository extends Mock implements SenderRepository {}

void main() {
  late MockSenderRepository mockRepository;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(const FileMetadata(
      name: 'dummy',
      path: '/tmp/dummy',
      size: 0,
      mimeType: 'text/plain',
    ));
    registerFallbackValue(TransportType.internet);
    registerFallbackValue(TransferSession(
      id: 'dummy',
      fileMetadata: const FileMetadata(
        name: 'dummy',
        path: '/tmp/dummy',
        size: 0,
        mimeType: 'text/plain',
      ),
      serverPort: 8080,
      authToken: 'dummy',
      localIp: '127.0.0.1',
      startedAt: DateTime.now(),
    ));
  });

  setUp(() {
    mockRepository = MockSenderRepository();
    when(() => mockRepository.transferProgress)
        .thenAnswer((_) => const Stream.empty());
    when(() => mockRepository.statusStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => mockRepository.stopServer())
        .thenAnswer((_) async => const Right(null));
    when(() => mockRepository.stopServer(force: true))
        .thenAnswer((_) async => const Right(null));
  });

  group('SenderBloc', () {
    blocTest<SenderBloc, SenderState>(
      'emits [SenderError] when pickFile fails',
      build: () {
        when(() => mockRepository.pickFile()).thenAnswer(
            (_) async => const Left(FileFailure('No file selected')));
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) => bloc.add(PickFile()),
      expect: () => [isA<SenderError>()],
    );

    blocTest<SenderBloc, SenderState>(
      'emits [FileSelected] when pickFile succeeds',
      build: () {
        when(() => mockRepository.pickFile())
            .thenAnswer((_) async => const Right(
                  FileMetadata(
                    name: 'test.txt',
                    path: '/tmp/test.txt',
                    size: 100,
                    mimeType: 'text/plain',
                  ),
                ));
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) => bloc.add(PickFile()),
      expect: () => [isA<FileSelected>()],
    );

    blocTest<SenderBloc, SenderState>(
      'emits [FileSelected] when pickMedia succeeds',
      build: () {
        when(() => mockRepository.pickMedia())
            .thenAnswer((_) async => const Right(
                  FileMetadata(
                    name: 'video.mov',
                    path: '/tmp/video.mov',
                    size: 100,
                    mimeType: 'video/quicktime',
                  ),
                ));
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) => bloc.add(PickMedia()),
      expect: () => [
        const FileSelected(
          FileMetadata(
            name: 'video.mov',
            path: '/tmp/video.mov',
            size: 100,
            mimeType: 'video/quicktime',
          ),
        ),
      ],
      verify: (_) => verify(() => mockRepository.pickMedia()).called(1),
    );

    final testDir = Directory.systemTemp.createTempSync('quickshare_test_folder');
    File('${testDir.path}/test_file.txt').writeAsStringSync('hello world');

    blocTest<SenderBloc, SenderState>(
      'emits [ServerStarting, QRReady] when StartQhtpSend succeeds for Wifi mode',
      build: () {
        final dummySession = TransferSession(
          id: 'test_session',
          fileMetadata: const FileMetadata(
            name: 'folder',
            path: '/tmp/folder',
            size: 100,
            mimeType: 'application/octet-stream',
          ),
          serverPort: 8080,
          authToken: 'test_token',
          localIp: '192.168.1.100',
          startedAt: DateTime.now(),
        );
        when(() => mockRepository.startQhtpTransfer(any(),
                onIndexProgress: any(named: 'onIndexProgress')))
            .thenAnswer((_) async => Right(dummySession));
        when(() => mockRepository.generateQRPayload(any()))
            .thenAnswer((_) async => const Right('quickshare://join?room=123456'));
        return SenderBloc(repository: mockRepository);
      },
      act: (bloc) => bloc.add(StartQhtpSend([testDir.path], mode: TransportType.wifi)),
      expect: () => [
        isA<ServerStarting>(),
        isA<QRReady>(),
      ],
    );

    blocTest<SenderBloc, SenderState>(
      // The receiver's socket read only fails fast if the server is torn
      // down forced — see [LocalHttpServer.stop]. A plain stopServer() here
      // used to leave an active download's stream blocked on a 30-second
      // idle timeout before it ever noticed the sender was gone.
      'CancelSending force-closes the server rather than closing it gracefully',
      build: () => SenderBloc(repository: mockRepository),
      act: (bloc) => bloc.add(CancelSending()),
      verify: (_) =>
          verify(() => mockRepository.stopServer(force: true)).called(1),
    );

    // Everything below exercises the transfer-history record a completed,
    // cancelled, or failed Wi-Fi send leaves behind — the "Recent Transfers"
    // list on the settings screen reads exactly this file back.
    late Directory diagDir;
    late TransferDiagnostics diagnostics;
    late StreamController<double> progress;

    setUp(() {
      diagDir = Directory.systemTemp.createTempSync('quickshare_diag_test_');
      diagnostics = TransferDiagnostics(overrideDir: () => diagDir);
      progress = StreamController<double>.broadcast();
      when(() => mockRepository.transferProgress)
          .thenAnswer((_) => progress.stream);
    });

    tearDown(() async {
      await progress.close();
      if (await diagDir.exists()) await diagDir.delete(recursive: true);
    });

    TransferSession wifiSession({int size = 123456789}) => TransferSession(
          id: 'diag-session',
          fileMetadata: FileMetadata(
            name: '3 items',
            path: '/tmp/folder',
            size: size,
            mimeType: 'application/octet-stream',
          ),
          serverPort: 8000,
          authToken: 'diag-token',
          localIp: '192.168.1.50',
          startedAt: DateTime.now(),
        );

    blocTest<SenderBloc, SenderState>(
      // `_sessionFiles` is only ever populated on the Bluetooth/internet
      // branch, which flattens folders itself; QHTP indexes server-side, so
      // a plain Wi-Fi send left it null and the report recorded 0 bytes for
      // a transfer that moved 123 MB. The total has to come from the
      // session the server actually opened instead.
      'a completed Wi-Fi send records its real byte count and both addresses '
      '— not zero bytes and a guessed route',
      build: () {
        when(() => mockRepository.startQhtpTransfer(any(),
                onIndexProgress: any(named: 'onIndexProgress')))
            .thenAnswer((_) async => Right(wifiSession()));
        when(() => mockRepository.generateQRPayload(any()))
            .thenAnswer((_) async => const Right('qr-payload'));
        when(() => mockRepository.lastQhtpClientAddress)
            .thenReturn(InternetAddress('192.168.1.77'));
        return SenderBloc(repository: mockRepository, diagnostics: diagnostics);
      },
      act: (bloc) async {
        bloc.add(const StartQhtpSend(['/tmp/whatever'], mode: TransportType.wifi));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        progress.add(0.4);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        progress.add(1.0);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      verify: (_) async {
        final recorded = await diagnostics.recent();
        expect(recorded, isNotEmpty);
        final report = recorded.first;
        expect(report.succeeded, isTrue);
        expect(report.bytes, 123456789);
        expect(report.route, 'Local network',
            reason: 'a real (non-loopback) client address means the plain '
                'network carried it, not the direct link');
        expect(report.peerAddress, '192.168.1.77');
        expect(report.localAddress, '192.168.1.50:8000');
      },
    );

    blocTest<SenderBloc, SenderState>(
      'a Wi-Fi send actually carried by the direct link is labelled that way',
      build: () {
        when(() => mockRepository.startQhtpTransfer(any(),
                onIndexProgress: any(named: 'onIndexProgress')))
            .thenAnswer((_) async => Right(wifiSession()));
        when(() => mockRepository.generateQRPayload(any()))
            .thenAnswer((_) async => const Right('qr-payload'));
        // Loopback is what the receiver's dio connects to when it goes
        // through the peer-link bridge instead of the plain LAN address —
        // the one fact that used to be guessed from whether hosting merely
        // succeeded, which says nothing about which route the receiver
        // actually took.
        when(() => mockRepository.lastQhtpClientAddress)
            .thenReturn(InternetAddress.loopbackIPv4);
        return SenderBloc(repository: mockRepository, diagnostics: diagnostics);
      },
      act: (bloc) async {
        bloc.add(const StartQhtpSend(['/tmp/whatever'], mode: TransportType.wifi));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        progress.add(1.0);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      verify: (_) async {
        final report = (await diagnostics.recent()).first;
        expect(report.route, 'Direct Wi-Fi link');
      },
    );

    blocTest<SenderBloc, SenderState>(
      // Cancelling mid-transfer used to leave no trace at all: `_reportSend`
      // was only ever called from the completion path. A cancelled send is
      // still a fact worth a line in the history, with a real reason instead
      // of the screen simply going back to the start as if nothing had run.
      'cancelling mid-transfer still leaves a record, not silence',
      build: () {
        when(() => mockRepository.startQhtpTransfer(any(),
                onIndexProgress: any(named: 'onIndexProgress')))
            .thenAnswer((_) async => Right(wifiSession()));
        when(() => mockRepository.generateQRPayload(any()))
            .thenAnswer((_) async => const Right('qr-payload'));
        when(() => mockRepository.lastQhtpClientAddress)
            .thenReturn(InternetAddress('192.168.1.77'));
        return SenderBloc(repository: mockRepository, diagnostics: diagnostics);
      },
      act: (bloc) async {
        bloc.add(const StartQhtpSend(['/tmp/whatever'], mode: TransportType.wifi));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // A receiver has to have actually started pulling bytes for this to
        // count as a transfer worth recording — an untouched QR the user
        // dismisses is not a failed transfer, it is a change of mind.
        progress.add(0.2);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bloc.add(CancelSending());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      verify: (_) async {
        final report = (await diagnostics.recent()).first;
        expect(report.succeeded, isFalse);
        expect(report.peerAddress, '192.168.1.77');
      },
    );
  });
}

import 'dart:async';
import 'dart:io';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
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
        when(() => mockRepository.startQhtpTransfer(any()))
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
  });
}

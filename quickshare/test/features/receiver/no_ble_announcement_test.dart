// A receiver is not on the air.
//
// Devices connect by a QR code or a typed code and by nothing else, so a
// receiving screen must not light up as a "nearby" device for a sender to pick,
// and must not go looking for senders either. Building the bloc, or opening
// the scanner, used to start a Bluetooth announcement: advertise as a waiting
// receiver and scan for senders. Nothing here may touch the radio until a
// scanned QR asks for a session.
//
// The check is made at the platform channel, as the radio would see it, with
// the Apple bridge selected, so it does not depend on what the Dart classes
// are called.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';

class _MockDownload extends Mock implements DownloadFileUseCase {}

class _MockRepository extends Mock implements ReceiverRepository {}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('quickshare/bluetooth');
  const events = MethodChannel('quickshare/bluetooth/events');

  late List<String> methodCalls;
  late List<String> eventCalls;

  setUp(() {
    methodCalls = [];
    eventCalls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, (call) async {
      methodCalls.add(call.method);
      return null;
    });
    // An EventChannel is a method channel underneath: `listen` is the moment a
    // Dart object starts hearing the radio.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, (call) async {
      eventCalls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    group('on ${platform.name}', () {
      test('creating the receiving bloc does not announce or scan', () async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final bloc = ReceiverBloc(
            downloadFileUseCase: _MockDownload(),
            repository: _MockRepository(),
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(methodCalls, isEmpty,
              reason: 'no Bluetooth call may be made by a bloc that was only '
                  'created');
          expect(eventCalls, isEmpty, reason: 'nobody listens to the radio');
          await bloc.close();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

      test('opening the scanner does not announce or scan either', () async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final bloc = ReceiverBloc(
            downloadFileUseCase: _MockDownload(),
            repository: _MockRepository(),
          );
          bloc.add(StartScanning());
          await expectLater(bloc.stream, emits(Scanning()));
          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(methodCalls, isEmpty);
          expect(eventCalls, isEmpty);
          await bloc.close();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

      test('cancelling a download does not put the receiver on the air',
          () async {
        debugDefaultTargetPlatformOverride = platform;
        final repository = _MockRepository();
        when(() => repository.cancelDownload()).thenReturn(null);
        try {
          final bloc = ReceiverBloc(
            downloadFileUseCase: _MockDownload(),
            repository: repository,
          );
          bloc.add(CancelDownload());
          await expectLater(bloc.stream, emits(ReceiverInitial()));
          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(methodCalls, isEmpty,
              reason: 'going back to the start must not start an announcement');
          expect(eventCalls, isEmpty);
          await bloc.close();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    });
  }
}

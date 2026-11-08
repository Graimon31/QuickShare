// What the code-entry screen shows while a code is looked for, on the local
// network and on the internet at once: that it is looking, that it is waiting
// for a person over there, that the person can give up at any moment, and what
// it says when the search ends — one sentence for each ending, none of them
// promising a Wi-Fi network.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/receiver/data/client/code_lookup.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/receiver/presentation/pages/code_receive_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

import '../../support/sample_offer.dart';

class _MockRepository extends Mock implements ReceiverRepository {}

class _MockDownload extends Mock implements DownloadFileUseCase {}

/// A lookup the test finishes by hand, and that can tell the screen how far
/// it has got.
class _Lookup extends CodeLookup {
  _Lookup() : super(lanOnly: true);

  final asked = <SessionCode>[];
  CodeSearchControl? control;
  var _outcome = Completer<CodeSessionOutcome>();

  void finish(CodeSessionOutcome outcome) => _outcome.complete(outcome);
  Completer<CodeSessionOutcome> get pending => _outcome;

  @override
  Future<CodeSessionOutcome> find(SessionCode code,
      {CodeSearchControl? control}) {
    asked.add(code);
    this.control = control;
    _outcome = Completer<CodeSessionOutcome>();
    return _outcome.future;
  }
}

void main() {
  late _Lookup lookup;
  late ReceiverBloc bloc;
  late _MockRepository repository;

  setUp(() {
    lookup = _Lookup();
    repository = _MockRepository();
    Future<Either<Failure, QRPayload>> parse(String raw) async {
      try {
        return Right(QRPayloadDecoder().decode(raw));
      } catch (_) {
        return const Left(FileFailure('Invalid QR Code'));
      }
    }

    when(() => repository.parseQRCode(any()))
        .thenAnswer((call) => parse(call.positionalArguments.first as String));
    bloc = ReceiverBloc(
      downloadFileUseCase: _MockDownload(),
      repository: repository,
    );
  });

  tearDown(() => bloc.close());

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider<ReceiverBloc>.value(
        value: bloc,
        child: CodeReceivePage(lookup: lookup),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// The bloc's event queue runs on the real event loop, which the test's
  /// fake clock does not turn.
  Future<void> settleBloc(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), '1234567890');
    await tester.pump();
    await tester.tap(find.text('Receive'));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('while it looks: says so, and offers to give up', (tester) async {
    await mount(tester);
    expect(find.text('Cancel'), findsNothing);

    await submit(tester);

    expect(find.text('Looking for the sender…'), findsOneWidget);
    expect(find.byKey(const ValueKey('code-search-cancel')), findsOneWidget);
    expect(lookup.asked, [const SessionCode('1234567890')]);
    expect(lookup.control, isNotNull);
    expect(lookup.control!.isCancelled, isFalse);
  });

  testWidgets('and says so when the other device is waiting for its person',
      (tester) async {
    await mount(tester);
    await submit(tester);

    lookup.control!.reportForTesting(CodeSearchPhase.awaitingApproval);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Waiting for the sender to confirm…'), findsOneWidget);
    expect(find.text('Looking for the sender…'), findsNothing);
  });

  testWidgets(
      'giving up stops the search, returns the field, and an answer '
      'that arrives afterwards says nothing', (tester) async {
    await mount(tester);
    await submit(tester);
    final control = lookup.control!;

    await tester.tap(find.byKey(const ValueKey('code-search-cancel')));
    await tester.pump();

    expect(control.isCancelled, isTrue);
    expect(find.text('Receive'), findsOneWidget);
    expect(find.byKey(const ValueKey('code-search-cancel')), findsNothing);

    lookup.finish(const CodeSessionNotFound());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Check the code: it changes'), findsNothing,
        reason: 'the person has moved on');
    expect(find.text('Receive'), findsOneWidget);
  });

  testWidgets('giving up works while waiting for the other person too',
      (tester) async {
    await mount(tester);
    await submit(tester);
    lookup.control!.reportForTesting(CodeSearchPhase.awaitingApproval);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey('code-search-cancel')));
    await tester.pump();

    expect(lookup.control!.isCancelled, isTrue);
    expect(find.text('Waiting for the sender to confirm…'), findsNothing);
  });

  testWidgets('leaving the screen stops the search', (tester) async {
    await mount(tester);
    await submit(tester);
    final control = lookup.control!;

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    expect(control.isCancelled, isTrue);
  });

  testWidgets('after giving up, the same code can be tried again',
      (tester) async {
    await mount(tester);
    await submit(tester);
    await tester.tap(find.byKey(const ValueKey('code-search-cancel')));
    await tester.pump();

    await tester.tap(find.text('Receive'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(lookup.asked, hasLength(2));
    expect(lookup.control!.isCancelled, isFalse, reason: 'a fresh search');
  });

  for (final staleError in [false, true]) {
    testWidgets(
        'a cancelled search returning ${staleError ? 'an error' : 'an offer'} '
        'cannot replace a fresh search', (tester) async {
      await mount(tester);
      await submit(tester);
      final previous = lookup.pending;
      await tester.tap(find.byKey(const ValueKey('code-search-cancel')));
      await tester.pump();
      await tester.tap(find.text('Receive'));
      await tester.pump(const Duration(milliseconds: 100));
      final current = lookup.pending;
      expect(identical(previous, current), isFalse);
      if (staleError) {
        previous.completeError(StateError('old search failed late'));
      } else {
        previous.complete(CodeSessionFoundOnline(sampleOffer(name: 'old.bin')));
      }
      await settleBloc(tester);
      expect(find.text('Looking for the sender…'), findsOneWidget);
      expect(find.text('old.bin'), findsNothing);
      expect(bloc.state, isA<ReceiverInitial>());
      expect(lookup.control!.isCancelled, isFalse);
      current.complete(CodeSessionFoundOnline(sampleOffer(name: 'fresh.bin')));
      await settleBloc(tester);
      expect(bloc.state, isA<QRParsed>());
      expect((bloc.state as QRParsed).payload.fileName, 'fresh.bin');
      expect(find.text('fresh.bin'), findsOneWidget);
    });
  }

  group('when it ends', () {
    Future<void> endsWith(
        WidgetTester tester, CodeSessionOutcome outcome) async {
      await mount(tester);
      await submit(tester);
      lookup.finish(outcome);
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets(
        'not found: check the code, it changes every five minutes, '
        'and a local network needs both devices on it — no Wi-Fi promise',
        (tester) async {
      await endsWith(tester, const CodeSessionNotFound());

      expect(
          find.text('Sender not found. Check the code: it changes every 5 '
              'minutes. For Nearby transfer, enable Bluetooth and keep devices nearby. '
              'For local network transfer, connect both devices to the same network.'),
          findsOneWidget);
      expect(find.textContaining('Wi-Fi'), findsNothing);
      expect(find.text('Receive'), findsOneWidget,
          reason: 'and it can be tried again');
    });

    testWidgets('no network: says that, and not that the code is wrong',
        (tester) async {
      await endsWith(tester, const CodeSessionNoNetwork());

      expect(find.textContaining('internet service is unavailable'),
          findsOneWidget);
      expect(find.textContaining('Check the code: it changes'), findsNothing);
    });

    testWidgets('refused: declined', (tester) async {
      await endsWith(tester, const CodeSessionDeclined());
      expect(find.text('Declined'), findsOneWidget);
    });

    testWidgets('another version: update', (tester) async {
      await endsWith(tester, const CodeSessionUpdateRequired());
      expect(find.textContaining('different version of DirectDrop'),
          findsOneWidget);
    });

    testWidgets('proved and then silent: could not reach that device',
        (tester) async {
      await endsWith(tester, const CodeSessionUnreachable());
      expect(find.text('Could not reach that device'), findsOneWidget);
    });

    testWidgets('each ending is a different sentence, in both languages',
        (tester) async {
      for (final locale in const [Locale('en'), Locale('ru')]) {
        final l10n = await AppLocalizations.delegate.load(locale);
        final sentences = {
          l10n.codeReceiveNotFound,
          l10n.codeReceiveNoNetwork,
          l10n.inviteDeclined,
          l10n.codeReceiveUpdateRequired,
          l10n.inviteUnreachable,
        };
        expect(sentences, hasLength(5), reason: '$locale');
        expect(sentences.every((s) => s.trim().isNotEmpty), isTrue);
      }
    });

    testWidgets('the Russian sentences say what the English ones do',
        (tester) async {
      final ru = await AppLocalizations.delegate.load(const Locale('ru'));
      expect(
          ru.codeReceiveNotFound,
          'Отправитель не найден. Проверьте код: он меняется каждые 5 минут. '
          'Для «Аналога AirDrop» включите Bluetooth и держите устройства рядом. '
          'Для локальной сети подключите оба устройства к одной сети.');
      expect(ru.codeReceiveNotFound, isNot(contains('Wi-Fi')));
      expect(ru.codeReceiveNoNetwork, contains('интернет'));
      expect(ru.codeReceiveAwaitingApproval, contains('подтвержд'));
      expect(ru.codeReceiveSearching, contains('Ищем'));
    });
  });

  testWidgets(
      'an offer found over the internet goes the way a scan goes: the '
      'real decoder, then the preview of what is coming', (tester) async {
    await mount(tester);
    await submit(tester);

    lookup.finish(CodeSessionFoundOnline(sampleOffer(name: 'trip.mov')));
    await settleBloc(tester);

    expect(bloc.state, isA<QRParsed>());
    final payload = (bloc.state as QRParsed).payload;
    expect(payload.mode, QRPayloadDecoder.serverlessMode);
    expect(payload.fileName, 'trip.mov');
    expect(find.text('File found'), findsOneWidget);
    expect(find.text('trip.mov'), findsOneWidget);
  });

  testWidgets('a Bluetooth code result decodes to the QR offer preview',
      (tester) async {
    await mount(tester);
    await submit(tester);
    final offer = const BluetoothQrPayload(
            token: 'random-token',
            locator: 'random-id',
            fileName: 'nearby.mov',
            fileSize: 1024,
            itemCount: 1,
            senderName: 'Sender')
        .encode();
    lookup.finish(CodeSessionFoundBluetooth(offer));
    await settleBloc(tester);
    expect(bloc.state, isA<QRParsed>());
    final payload = (bloc.state as QRParsed).payload;
    expect(payload.mode, QRPayloadDecoder.bluetoothMode);
    expect(payload.token, 'random-token');
    expect(payload.sessionId, 'random-id');
    expect(payload.fileName, 'nearby.mov');
    expect(find.text('File found'), findsOneWidget);
    expect(find.text('nearby.mov'), findsOneWidget);
  });

  testWidgets(
      'an offer that cannot be read is an error with the code in it, '
      'not a camera or a link', (tester) async {
    await mount(tester);
    await submit(tester);

    lookup.finish(const CodeSessionFoundOnline('QS1this-is-not-an-offer'));
    await settleBloc(tester);

    expect(bloc.state, isA<ReceiverError>());
    final message = (bloc.state as ReceiverError).message;
    expect(message, contains('code'));
    expect(message, isNot(contains('camera')));
    expect(message, isNot(contains('link')));
  });
}

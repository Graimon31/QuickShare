// Coming back to the picker has to leave it usable.
//
// `/send/qr` is a route under `/send`, so the QR screen is pushed on top of
// this page rather than replacing it: the State object survives the whole
// trip and still holds what it held when the session started — "a selection
// is in flight". Every button on the page returns at its first line while
// that is true, so popping back revealed a screen that looked alive and
// answered nothing. Leaving the QR screen cancels the session, so the bloc
// returning to its initial state is the signal that the page is usable again.
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/features/sender/presentation/pages/file_picker_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

class _MockSenderBloc extends MockBloc<SenderEvent, SenderState>
    implements SenderBloc {}

void main() {
  const folderChannel = MethodChannel('quickshare/folder_picker');

  setUpAll(() {
    registerFallbackValue(StartQhtpSend(const ['/tmp/anything']));
  });

  setUp(() {
    // The native picker stands in for the system dialog: the point of the
    // test is whether the tap reaches the handler at all.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(folderChannel, (call) async {
      if (call.method == 'pickFolders') return <String>['/tmp/trip'];
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(folderChannel, null);
  });

  Future<_MockSenderBloc> pumpPage(
    WidgetTester tester,
    Stream<SenderState> states,
  ) async {
    final bloc = _MockSenderBloc();
    whenListen(bloc, states, initialState: SenderInitial());

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider<SenderBloc>.value(
        value: bloc,
        child: const FilePickerPage(),
      ),
    ));
    // Not pumpAndSettle: the phase loader shimmers forever by design, so a
    // "wait until nothing is animating" would simply never return while a
    // session is being set up.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return bloc;
  }

  testWidgets('the folder button works again after a session is cancelled',
      (tester) async {
    final bloc = await pumpPage(
      tester,
      // A session starts, then ends the way leaving the QR screen ends it.
      Stream<SenderState>.fromIterable([ServerStarting(), SenderInitial()]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select Folder'));
    await tester.pumpAndSettle();

    verify(() => bloc.add(any(that: isA<StartQhtpSend>()))).called(1);
  });

  testWidgets('a session still being set up keeps the page to itself',
      (tester) async {
    final bloc = await pumpPage(
      tester,
      Stream<SenderState>.fromIterable([ServerStarting()]),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // Nothing to tap: while a session is starting the screen is the phase
    // loader, which is the one case the guard exists for.
    expect(find.text('Select Folder'), findsNothing);
    expect(find.text('Indexing selection…'), findsOneWidget);
    verifyNever(() => bloc.add(any(that: isA<StartQhtpSend>())));
  });
}

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
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/storage/folder_picker.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/features/sender/presentation/pages/file_picker_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

class _MockSenderBloc extends MockBloc<SenderEvent, SenderState>
    implements SenderBloc {}

/// Stands in for the plugin on the platforms that still fall back to it.
///
/// Windows and Linux have no single dialog that returns files and folders
/// together, so the page keeps two entry points there and both go through
/// `file_picker` — whose Linux implementation shells out to `zenity`. Under
/// `flutter test` that is neither present nor wanted: what is being tested is
/// whether the tap reaches the handler at all.
class _StubFilePicker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult(
          [PlatformFile(name: 'trip.txt', size: 4, path: '/tmp/trip.txt')]);

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async =>
      '/tmp/trip';
}

void main() {
  const folderChannel = MethodChannel('quickshare/folder_picker');

  // What the selection card is called depends on whether the platform can
  // browse for files and folders in one dialog. macOS and iOS can, and get
  // the single "Send Files" entry; Windows and Linux — where these tests run
  // in CI — cannot, and keep the pair the platform forces on them.
  final selectionLabel =
      FolderPicker.supportsUnifiedPick ? 'Send Files' : 'Select File';

  setUpAll(() {
    registerFallbackValue(const StartQhtpSend(['/tmp/anything']));
  });

  setUp(() {
    FilePicker.platform = _StubFilePicker();
    // The native picker stands in for the system dialog: the point of the
    // test is whether the tap reaches the handler at all.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(folderChannel, (call) async {
      if (call.method == 'pickItems' || call.method == 'pickFolders') {
        return <String>['/tmp/trip'];
      }
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

  testWidgets('the selection button works again after a session is cancelled',
      (tester) async {
    final bloc = await pumpPage(
      tester,
      // A session starts, then ends the way leaving the QR screen ends it.
      Stream<SenderState>.fromIterable([const ServerStarting(), SenderInitial()]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(selectionLabel));
    await tester.pumpAndSettle();

    verify(() => bloc.add(any(that: isA<StartQhtpSend>()))).called(1);
  });

  testWidgets('a session still being set up keeps the page to itself',
      (tester) async {
    final bloc = await pumpPage(
      tester,
      Stream<SenderState>.fromIterable([const ServerStarting()]),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // Nothing to tap: while a session is starting the screen is the phase
    // loader, which is the one case the guard exists for.
    expect(find.text(selectionLabel), findsNothing);
    expect(find.text('Indexing selection…'), findsOneWidget);
    verifyNever(() => bloc.add(any(that: isA<StartQhtpSend>())));
  });

  // Indexing is the one step here that can take minutes — a folder on a
  // phone's file provider is one slow directory read after another — and it
  // used to be unescapable: no back button, no cancel, and every control
  // underneath disabled behind the in-flight guard. Whatever the cause, the
  // only way out was to kill the app.
  testWidgets('a session being set up can be abandoned from the screen',
      (tester) async {
    final bloc = await pumpPage(
      tester,
      Stream<SenderState>.fromIterable([const ServerStarting()]),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Cancel'));
    await tester.pump();

    verify(() => bloc.add(any(that: isA<CancelSending>()))).called(1);
  });

  testWidgets('the indexing screen says how far it has got', (tester) async {
    await pumpPage(
      tester,
      Stream<SenderState>.fromIterable([
        const ServerStarting(indexedItems: 812, indexedBytes: 3 * 1024 * 1024),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('812'), findsOneWidget);
  });
}

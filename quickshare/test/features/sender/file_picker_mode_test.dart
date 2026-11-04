// The file screen sends over the transport the home screen chose.
//
// It used to open with a list of transports to pick from; that question is
// asked on the home screen now. What stays true of this screen:
//  * it is titled with the way it sends, and has no tiles to change it;
//  * everything it starts is started over that transport;
//  * the transport is checked before the file dialog opens, not only after a
//    file has been chosen, so nobody browses for files a transport cannot
//    carry — and the check still runs when files arrive some other way (a
//    drop), because that is the one route that cannot be checked earlier;
//  * the pages that sit on top of it (the QR code, the progress screen) do
//    not change what it sends over.
import 'package:bloc_test/bloc_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/storage/folder_picker.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/features/sender/presentation/pages/file_picker_page.dart';
import 'package:quickshare/features/sender/presentation/widgets/transport_preconditions.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

class _MockSenderBloc extends MockBloc<SenderEvent, SenderState>
    implements SenderBloc {}

class _Radio extends UniversalBlePlatform {
  _Radio(this.state);
  final AvailabilityState state;
  @override
  Future<bool> enableBluetooth() async => true;
  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async => state;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _Wifi extends PeerLinkService {
  const _Wifi();
  @override
  Future<bool> get wifiReady async => true;
  @override
  Future<bool> enableWifi() async => true;
  @override
  Future<bool> openWifiSettings() async => true;
}

class _Network extends NetworkInfoService {
  @override
  Future<bool> hasWifiTransportNetwork() async => true;
  @override
  Future<bool> hasAnyActiveConnection() async => true;
}

/// The dialog on Windows and Linux, which have no unified pick to call through
/// the folder channel.
class _FilesDialog extends FilePicker {
  _FilesDialog(this.onOpened);
  final void Function() onOpened;

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
  }) async {
    onOpened();
    return FilePickerResult(
        [PlatformFile(name: 'trip', size: 4, path: '/tmp/trip')]);
  }
}

void main() {
  const folderChannel = MethodChannel('quickshare/folder_picker');

  // macOS and iOS browse for files and folders in one dialog and call the
  // button "Send Files"; Windows and Linux keep the pair the platform forces.
  final selectionLabel =
      FolderPicker.supportsUnifiedPick ? 'Send Files' : 'Select File';

  final realNetwork = TransportPreconditions.networkInfo;
  final realPeerLink = TransportPreconditions.peerLink;

  /// Calls the system file dialog received. The point of asking: a refusal has
  /// to happen *before* it, so this must stay at zero.
  var dialogCalls = 0;

  setUpAll(() {
    registerFallbackValue(const StartQhtpSend(['/tmp/anything']));
  });

  setUp(() {
    dialogCalls = 0;
    TransportPreconditions.networkInfo = _Network();
    TransportPreconditions.peerLink = const _Wifi();
    UniversalBle.setInstance(_Radio(AvailabilityState.poweredOn));
    FilePicker.platform = _FilesDialog(() => dialogCalls++);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(folderChannel, (call) async {
      if (call.method == 'pickItems' || call.method == 'pickFolders') {
        dialogCalls++;
        return <String>['/tmp/trip'];
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(folderChannel, null);
    TransportPreconditions.networkInfo = realNetwork;
    TransportPreconditions.peerLink = realPeerLink;
  });

  Widget host(_MockSenderBloc bloc, Widget page, {Locale? locale}) {
    return MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider<SenderBloc>.value(value: bloc, child: page),
    );
  }

  Future<_MockSenderBloc> pumpPage(
    WidgetTester tester,
    FilePickerPage page, {
    Locale? locale,
  }) async {
    final bloc = _MockSenderBloc();
    whenListen(bloc, const Stream<SenderState>.empty(),
        initialState: SenderInitial());
    await tester.pumpWidget(host(bloc, page, locale: locale));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return bloc;
  }

  group('it is titled with the way it sends', () {
    const titles = {
      'en': {
        TransportType.wifi: 'Local network transfer',
        TransportType.bluetooth: 'AirDrop alternative',
        TransportType.internet: 'Over the internet',
      },
      'ru': {
        TransportType.wifi: 'Передача по локальной сети',
        TransportType.bluetooth: 'Аналог AirDrop',
        TransportType.internet: 'Через интернет',
      },
    };

    for (final code in titles.keys) {
      for (final MapEntry(key: mode, value: title) in titles[code]!.entries) {
        testWidgets('$code, ${mode.name}: "$title"', (tester) async {
          await pumpPage(tester, FilePickerPage(mode: mode),
              locale: Locale(code));

          expect(
              find.descendant(
                  of: find.byType(AppBar), matching: find.text(title)),
              findsOneWidget);
        });
      }
    }

    testWidgets('and has no tiles to change it', (tester) async {
      await pumpPage(tester, const FilePickerPage(mode: TransportType.wifi));

      expect(find.byType(Radio<TransportType>), findsNothing);
      expect(find.byType(RadioGroup<TransportType>), findsNothing);
      expect(find.textContaining('Transfer Method'), findsNothing);
      expect(find.text('Wi-Fi / Local Network'), findsNothing);
      expect(find.text('Internet Link'), findsNothing);
      expect(find.text('Bluetooth'), findsNothing);
      // What is left is choosing what to send.
      expect(find.text('Choose What to Share'), findsOneWidget);
      expect(find.text(selectionLabel), findsOneWidget);
    });
  });

  group('everything it starts is started over its transport', () {
    for (final mode in TransportType.values) {
      testWidgets('picking files on the ${mode.name} screen', (tester) async {
        final bloc = await pumpPage(tester, FilePickerPage(mode: mode));

        await tester.tap(find.text(selectionLabel));
        await tester.pumpAndSettle();

        final sent = verify(() => bloc.add(captureAny(
            that: isA<StartQhtpSend>()))).captured.single as StartQhtpSend;
        expect(sent.mode, mode);
        expect(sent.paths, ['/tmp/trip']);
      });

      testWidgets('files that arrive already chosen (a drop) on the '
          '${mode.name} screen', (tester) async {
        final bloc = await pumpPage(
            tester, FilePickerPage(mode: mode, qhtpPaths: const ['/tmp/dropped']));
        await tester.pumpAndSettle();

        final sent = verify(() => bloc.add(captureAny(
            that: isA<StartQhtpSend>()))).captured.single as StartQhtpSend;
        expect(sent.mode, mode);
        expect(sent.paths, ['/tmp/dropped']);
        expect(dialogCalls, 0, reason: 'nothing to browse for: it was dropped');
      });
    }
  });

  group('the transport is checked before any file is asked for', () {
    testWidgets('Bluetooth off: the dialog appears and the file dialog does '
        'not', (tester) async {
      UniversalBle.setInstance(_Radio(AvailabilityState.poweredOff));
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final bloc =
          await pumpPage(tester, const FilePickerPage(mode: TransportType.bluetooth));

      await tester.tap(find.text(selectionLabel));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(l10n.precondBluetoothTitle), findsOneWidget);
      expect(dialogCalls, 0, reason: 'refused before the file dialog opened');
      verifyNever(() => bloc.add(any(that: isA<StartQhtpSend>())));

      // Cancelling leaves the screen usable: turn Bluetooth on and go again.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      UniversalBle.setInstance(_Radio(AvailabilityState.poweredOn));
      await tester.tap(find.text(selectionLabel));
      await tester.pumpAndSettle();

      expect(dialogCalls, 1);
      final sent = verify(() => bloc.add(captureAny(
          that: isA<StartQhtpSend>()))).captured.single as StartQhtpSend;
      expect(sent.mode, TransportType.bluetooth);
    });

    testWidgets('no local network: the same, for the Wi-Fi screen',
        (tester) async {
      TransportPreconditions.networkInfo = _NoLan();
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final bloc = await pumpPage(
          tester, const FilePickerPage(mode: TransportType.wifi));

      await tester.tap(find.text(selectionLabel));
      await tester.pumpAndSettle();

      expect(find.text(l10n.precondWifiTitle), findsOneWidget);
      expect(dialogCalls, 0);
      verifyNever(() => bloc.add(any(that: isA<StartQhtpSend>())));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('no connection at all: the same, for the internet screen',
        (tester) async {
      TransportPreconditions.networkInfo = _Offline();
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final bloc = await pumpPage(
          tester, const FilePickerPage(mode: TransportType.internet));

      await tester.tap(find.text(selectionLabel));
      await tester.pumpAndSettle();

      expect(find.text(l10n.precondInternetBlocked), findsOneWidget);
      expect(dialogCalls, 0);
      verifyNever(() => bloc.add(any(that: isA<StartQhtpSend>())));
    });

    testWidgets('a dropped file on a transport that cannot run starts '
        'nothing — it is the one route that cannot be checked earlier',
        (tester) async {
      UniversalBle.setInstance(_Radio(AvailabilityState.poweredOff));
      final bloc = await pumpPage(
          tester,
          const FilePickerPage(
              mode: TransportType.bluetooth, qhtpPaths: ['/tmp/dropped']));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      verifyNever(() => bloc.add(any(that: isA<StartQhtpSend>())));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('the radio switched off while the file dialog was open is '
        'still caught afterwards', (tester) async {
      final bloc = await pumpPage(
          tester, const FilePickerPage(mode: TransportType.bluetooth));

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(folderChannel, (call) async {
        // Bluetooth goes off while the person is looking at the dialog.
        UniversalBle.setInstance(_Radio(AvailabilityState.poweredOff));
        return <String>['/tmp/trip'];
      });
      FilePicker.platform = _FilesDialog(
          () => UniversalBle.setInstance(_Radio(AvailabilityState.poweredOff)));
      await tester.tap(find.text(selectionLabel));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      verifyNever(() => bloc.add(any(that: isA<StartQhtpSend>())));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
  });

  group('what sits on top of the screen does not change its transport', () {
    testWidgets('a rebuild with no mode keeps it; one with a mode changes it',
        (tester) async {
      final bloc = _MockSenderBloc();
      whenListen(bloc, const Stream<SenderState>.empty(),
          initialState: SenderInitial());
      String? title() {
        final bar = find.byType(AppBar);
        return tester
            .widgetList<Text>(
                find.descendant(of: bar, matching: find.byType(Text)))
            .map((t) => t.data)
            .firstWhere((t) => t != null, orElse: () => null);
      }

      // The page's own entrance animation starts a timer; give it the time.
      Future<void> show(FilePickerPage page) async {
        await tester.pumpWidget(host(bloc, page));
        await tester.pump(const Duration(milliseconds: 400));
      }

      await show(const FilePickerPage(mode: TransportType.internet));
      expect(title(), 'Over the internet');

      // The router builds the page again for /send/qr, which carries no mode.
      await show(const FilePickerPage());
      expect(title(), 'Over the internet');

      await show(const FilePickerPage(mode: TransportType.wifi));
      expect(title(), 'Local network transfer');
    });
  });

  group('nothing overflows', () {
    for (final code in ['en', 'ru']) {
      for (final mode in TransportType.values) {
        testWidgets('$code, ${mode.name}, 375 × 812, text ×1.3',
            (tester) async {
          tester.view
            ..physicalSize = const Size(375, 812)
            ..devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final bloc = _MockSenderBloc();
          whenListen(bloc, const Stream<SenderState>.empty(),
              initialState: SenderInitial());
          await tester.pumpWidget(MaterialApp(
            locale: Locale(code),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: BlocProvider<SenderBloc>.value(
                value: bloc, child: FilePickerPage(mode: mode)),
          ));
          await tester.pump(const Duration(milliseconds: 400));

          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}

class _NoLan extends _Network {
  @override
  Future<bool> hasWifiTransportNetwork() async => false;
}

class _Offline extends _Network {
  @override
  Future<bool> hasAnyActiveConnection() async => false;
}

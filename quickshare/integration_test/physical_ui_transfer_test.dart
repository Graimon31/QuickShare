// Real Mac sender -> physical iPhone receiver using production widgets.
// PAIR_UI_ROLE=sender on Mac, receiver on iPhone. The user scans the Mac QR
// with the actual iPhone camera and grants native permissions. A generated
// blue 32x32 PNG named directdrop-ui-test.png remains in Photos on success.
// Sender uses the production qhtpPaths entry used for desktop drag/drop;
// it does not exercise the native drag gesture or OS picker. Production main
// performs its usual expired-cache and expired-session housekeeping.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:quickshare/core/router/app_router.dart';
import 'package:quickshare/core/router/send_routes.dart';
import 'package:quickshare/features/receiver/presentation/pages/code_receive_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/complete_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/qr_scan_page.dart';
import 'package:quickshare/features/receiver/presentation/pages/transfer_preview_page.dart';
import 'package:quickshare/features/receiver/presentation/widgets/received_items_list.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/features/sender/presentation/pages/qr_display_page.dart';
import 'package:quickshare/features/sender/presentation/pages/sender_progress_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/main.dart' as app;

import 'physical_test_config.dart';

final role = physicalString(
    'PAIR_UI_ROLE', const String.fromEnvironment('PAIR_UI_ROLE'));
final input = physicalString('PAIR_UI_INPUT',
    const String.fromEnvironment('PAIR_UI_INPUT', defaultValue: 'camera'));
final code = physicalString(
    'PAIR_UI_CODE', const String.fromEnvironment('PAIR_UI_CODE'));
const fixtureName = 'directdrop-ui-test.png';
const fixtureBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAL0lEQVR4nO3OIQEAAAgDMPLQln50gRg3E/Ornr2kEhAQEBAQEBAQEBAQEBAQSAce3vxYlx5WjHMAAAAASUVORK5CYII=';

Future<void> waitFor(WidgetTester tester, bool Function() ready,
    {required Duration timeout, required String description}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: 'timed out waiting for $description');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real Mac to iPhone UI, camera and photo save', (tester) async {
    expect(['sender', 'receiver'], contains(role));
    expect(['camera', 'code'], contains(input));
    if (role == 'receiver' && input == 'code') {
      expect(RegExp(r'^\d{10}$').hasMatch(code), isTrue,
          reason: 'PAIR_UI_CODE must be the current ten-digit sender code');
    }
    expect(role == 'sender' ? Platform.isMacOS : Platform.isIOS, isTrue,
        reason: 'sender must be Mac and receiver must be physical iPhone');
    final expected = base64Decode(fixtureBase64);
    final expectedHash = sha256.convert(expected).toString();
    app.main();
    await waitFor(tester, () => AppRouter.navigatorKey.currentContext != null,
        timeout: const Duration(seconds: 30), description: 'home navigator');
    final homeLabels =
        AppLocalizations.of(AppRouter.navigatorKey.currentContext!);
    await waitFor(tester,
        () => find.text(homeLabels.homeReceiveTitle).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 30), description: 'home screen');
    if (role == 'sender') {
      final dir = await Directory.systemTemp.createTemp('dd_ui_fixture_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File(p.join(dir.path, fixtureName));
      await file.writeAsBytes(expected, flush: true);
      AppRouter.router.push(SendRoutes.filesFor(TransportType.wifi), extra: {
        'qhtpPaths': [file.path]
      });
      await waitFor(tester, () {
        if (find.byType(QRDisplayPage).evaluate().isEmpty ||
            find.byType(QrImageView).evaluate().isEmpty) {
          return false;
        }
        return tester
            .element(find.byType(QRDisplayPage))
            .read<SenderBloc>()
            .state is QRReady;
      },
          timeout: const Duration(seconds: 90),
          description: 'actual LAN QR offer');
      final ready = tester
          .element(find.byType(QRDisplayPage))
          .read<SenderBloc>()
          .state as QRReady;
      final actualCode = ready.code?.code;
      expect(actualCode, isNotNull, reason: 'Wi-Fi offer must expose a code');
      expect(RegExp(r'^\d{10}$').hasMatch(actualCode!), isTrue);
      print('PAIR_UI_CODE=$actualCode');
      print('UI_PAIR_QR_READY');
      if (input == 'code') {
        final accept = find.text(homeLabels.inviteAccept);
        await waitFor(tester, () => accept.evaluate().isNotEmpty,
            timeout: const Duration(minutes: 3),
            description: 'sender approval dialog for code lookup');
        await tester.tap(accept);
        print('UI_PAIR_SENDER_APPROVED');
      }
      await waitFor(tester, () {
        if (find.byType(SenderProgressPage).evaluate().isEmpty) return false;
        return tester
            .element(find.byType(SenderProgressPage))
            .read<SenderBloc>()
            .state is TransferComplete;
      },
          timeout: const Duration(minutes: 5),
          description: 'sender transfer completion');
      final context = tester.element(find.byType(SenderProgressPage));
      expect(
          find.text(AppLocalizations.of(context).senderProgressCompleteTitle),
          findsOneWidget);
      print('UI_PAIR_SENDER_COMPLETE');
      return;
    }
    if (input == 'camera') {
      print(
          'UI_PAIR_CAMERA_REQUEST: allow camera if prompted, then point at the Mac QR');
      await tester.tap(find.text(homeLabels.homeReceiveTitle));
      await waitFor(tester, () => find.byType(QRScanPage).evaluate().isNotEmpty,
          timeout: const Duration(minutes: 2),
          description: 'camera scanner screen');
      await waitFor(
          tester, () => find.byType(MobileScanner).evaluate().isNotEmpty,
          timeout: const Duration(minutes: 2),
          description: 'native camera scanner');
      print('UI_PAIR_SCANNER_READY');
      await waitFor(
          tester, () => find.byType(TransferPreviewPage).evaluate().isNotEmpty,
          timeout: const Duration(minutes: 5),
          description: 'physical camera QR scan and preview');
      final preview = tester.element(find.byType(TransferPreviewPage));
      final receive = find.descendant(
          of: find.byType(TransferPreviewPage),
          matching:
              find.text(AppLocalizations.of(preview).codeReceiveReceiveButton));
      await waitFor(tester, () => receive.evaluate().isNotEmpty,
          timeout: const Duration(seconds: 30),
          description: 'receive approval button');
      await tester.ensureVisible(receive);
      await tester.tap(receive);
    } else {
      // This is the same production route reached by the scanner's Enter Code
      // button, without opening the camera or triggering its permission dialog.
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      AppRouter.router.go('/receive/code');
      await waitFor(
          tester, () => find.byType(CodeReceivePage).evaluate().isNotEmpty,
          timeout: const Duration(seconds: 30), description: 'code entry page');
      final page = find.byType(CodeReceivePage);
      final field = find.descendant(of: page, matching: find.byType(TextField));
      await waitFor(tester, () => field.evaluate().isNotEmpty,
          timeout: const Duration(seconds: 30), description: 'code input');
      await tester.enterText(field, code);
      final pageContext = tester.element(page);
      final labels = AppLocalizations.of(pageContext);
      final search = find.descendant(
          of: page, matching: find.text(labels.codeReceiveReceiveButton));
      await tester.ensureVisible(search);
      await tester.tap(search);
      print('UI_PAIR_CODE_SUBMITTED');
      final download = find.descendant(
          of: page, matching: find.text(labels.codeReceiveDownloadButton));
      await waitFor(tester, () => download.evaluate().isNotEmpty,
          timeout: const Duration(minutes: 3),
          description: 'code lookup and incoming file confirmation');
      // A typed-code LAN payload intentionally carries no filename. The
      // confirmation may initially show generic incoming-transfer text; the
      // exact filename and bytes are verified on the completion screen below.
      expect(find.text(labels.codeReceiveFileFound), findsOneWidget);
      await tester.ensureVisible(download);
      await tester.tap(download);
    }
    print('UI_PAIR_RECEIVE_APPROVED: allow Photos access if prompted');
    await waitFor(tester, () => find.byType(CompletePage).evaluate().isNotEmpty,
        timeout: const Duration(minutes: 3),
        description: 'received completion screen');
    final page = tester.widget<CompletePage>(find.byType(CompletePage));
    expect(page.placed, isFalse);
    expect(page.items, hasLength(1));
    expect(page.items.single.name, fixtureName);
    final received = File(page.items.single.cachePath);
    expect(await received.exists(), isTrue);
    expect(await received.length(), expected.length);
    final actualHash =
        (await sha256.bind(received.openRead()).first).toString();
    expect(actualHash, expectedHash);
    print('UI_PAIR_SHA256=$actualHash');
    await waitFor(tester, () {
      final lists = find.byType(ReceivedItemsList);
      if (lists.evaluate().isEmpty) return false;
      final items = tester.widget<ReceivedItemsList>(lists.first).items;
      return items.length == 1 && items.single.savedPath == 'gallery';
    },
        timeout: const Duration(minutes: 2),
        description: 'actual automatic Photos save');
    final complete = tester.element(find.byType(CompletePage));
    expect(find.text(AppLocalizations.of(complete).completeSavedCount(1)),
        findsOneWidget);
    print(
        'UI_PAIR_PHOTOS_SAVED: one generated blue test image remains in Photos');
    print('UI_PAIR_RECEIVER_COMPLETE');
  }, timeout: const Timeout(Duration(minutes: 12)));
}

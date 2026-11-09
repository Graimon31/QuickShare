// Native-device navigation smoke test for the shipped app widget tree.
//
// Run separately on each physical target:
//   flutter test integration_test/physical_ui_navigation_test.dart -d macos
//   flutter drive --no-pub -d <iphone-device-id> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/physical_ui_navigation_test.dart --publish-port
//
// This calls the production main() entry point and uses the real service
// locator, platform channels, permission status, and persistent locale store.
// It deliberately does not start a transfer or touch cache/save preferences.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/localization/locale_controller.dart';
import 'package:quickshare/core/localization/locale_store.dart';
import 'package:quickshare/core/permissions/permission_service.dart';
import 'package:quickshare/l10n/gen/app_localizations_en.dart';
import 'package:quickshare/l10n/gen/app_localizations_ru.dart';
import 'package:quickshare/main.dart' as directdrop;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('production app navigation and locale work on this device',
      (tester) async {
    final platform = Platform.operatingSystem;
    const localeStore = LocaleStore();
    final savedLanguage = await localeStore.read();
    print('UI_CHECK START platform=$platform');

    directdrop.main();
    final initialLabels = _labelsFor(savedLanguage);
    await _pumpUntil(tester, find.text(initialLabels.receive));
    expect(find.byTooltip(initialLabels.settingsTooltip), findsOneWidget);
    expect(find.text(initialLabels.receive), findsOneWidget,
        reason: 'the production home screen should finish its entrance');
    print('UI_CHECK PASS production main launched home on $platform');

    try {
      await tester.tap(find.text('AirDrop'));
      final homeL10n = savedLanguage == AppLanguage.russian ||
              (savedLanguage == null &&
                  WidgetsBinding
                          .instance.platformDispatcher.locale.languageCode ==
                      'ru')
          ? AppLocalizationsRu()
          : AppLocalizationsEn();
      await _pumpUntil(tester, find.text(homeL10n.homeLocalNetworkTitle));
      expect(
          find.text(homeL10n.homeAirdropAltTitle('AirDrop')), findsOneWidget);
      print('UI_CHECK PASS AirDrop expands to local and Bluetooth options');

      await tester.tap(find.text('AirDrop'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text(homeL10n.homeLocalNetworkTitle), findsNothing,
          reason: 'the second tap should collapse the AirDrop options');
      print('UI_CHECK PASS AirDrop options collapse');

      await tester.tap(find.byTooltip(initialLabels.settingsTooltip));
      await _pumpUntil(tester, find.text(initialLabels.settings));
      await _ensureVisible(tester, find.text(initialLabels.language));
      expect(find.text(initialLabels.language), findsOneWidget);
      print('UI_CHECK PASS home settings navigation');

      await _tapVisible(tester, find.text('English'));
      await _pumpUntil(tester, find.text('Settings'));
      await _ensureVisible(tester, find.text('LANGUAGE'));
      expect(find.text('LANGUAGE'), findsOneWidget);
      print('UI_CHECK PASS English selected through settings UI');

      await _tapVisible(tester, find.text('Русский'));
      await _pumpUntil(tester, find.text('Настройки'));
      await _ensureVisible(tester, find.text('ЯЗЫК'));
      expect(find.text('ЯЗЫК'), findsOneWidget);
      print('UI_CHECK PASS Russian selected through settings UI');

      if (savedLanguage == AppLanguage.english) {
        await _tapVisible(tester, find.text('English'));
        await _pumpUntil(tester, find.text('Settings'));
      } else if (savedLanguage == AppLanguage.russian) {
        await _tapVisible(tester, find.text('Русский'));
        await _pumpUntil(tester, find.text('Настройки'));
      } else {
        // The app has no “follow system” row. Restore the original unset value
        // through the same controller/store used by the UI.
        await sl<LocaleController>().setLanguage(null);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await localeStore.read(), savedLanguage,
          reason:
              'the saved language must be exactly as it was before this run');
      print('UI_CHECK PASS original saved locale restored');

      final currentLabels = _labelsFor(savedLanguage);
      await _tapVisible(tester, find.text(currentLabels.logs));
      await _pumpUntil(tester, find.byIcon(Icons.copy_rounded));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text(currentLabels.logs), findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      print('UI_CHECK PASS logs route opened');

      await tester.tap(find.byIcon(Icons.arrow_back).first);
      await tester.pump(const Duration(milliseconds: 350));
      await _pumpUntil(tester, find.text(currentLabels.settings));
      await tester.tap(find.byIcon(Icons.arrow_back).first);
      await tester.pump(const Duration(milliseconds: 350));
      await _pumpUntil(tester, find.byTooltip(currentLabels.settingsTooltip));
      expect(find.text(currentLabels.receive), findsOneWidget);
      print('UI_CHECK PASS back navigation logs -> settings -> home');

      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        await tester.tap(find.text(currentLabels.receive));
        await _pumpUntil(tester, find.byType(TextField));
        expect(find.text(currentLabels.codeTitle), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        await tester.enterText(find.byType(TextField), '123');
        await tester.tap(find.text(currentLabels.receiveAction));
        await _pumpUntil(tester, find.text(currentLabels.invalidCode));
        expect(find.text(currentLabels.invalidCode), findsOneWidget,
            reason: 'a partial code must be rejected locally without a search');
        print('UI_CHECK PASS desktop code entry rejects incomplete code');
      } else if (Platform.isIOS) {
        final cameraGranted =
            await sl<PermissionService>().hasCameraPermission();
        if (!cameraGranted) {
          print('UI_CHECK PENDING iPhone scanner: camera permission is not '
              'already granted; receive was not tapped to avoid an unanswered '
              'native permission prompt');
        } else {
          await tester.tap(find.text(currentLabels.receive));
          await _pumpUntil(
            tester,
            find.text(currentLabels.scannerReady),
            timeout: const Duration(seconds: 12),
          );
          expect(find.text(currentLabels.scannerReady), findsOneWidget);
          print('UI_CHECK PASS iPhone receive scanner opened with existing '
              'camera permission');
        }
      }
    } finally {
      // Restore even if an assertion or UI action above fails.
      await sl<LocaleController>().setLanguage(savedLanguage);
      expect(await localeStore.read(), savedLanguage);
      print('UI_CHECK CLEANUP saved locale unchanged');
    }
  });
}

({
  String settings,
  String settingsTooltip,
  String language,
  String logs,
  String receive,
  String codeTitle,
  String receiveAction,
  String invalidCode,
  String scannerReady
}) _labelsFor(AppLanguage? language) {
  final ru = language == AppLanguage.russian ||
      (language == null &&
          WidgetsBinding.instance.platformDispatcher.locale.languageCode ==
              'ru');
  final l10n = ru ? AppLocalizationsRu() : AppLocalizationsEn();
  return (
    settings: l10n.settingsTitle,
    settingsTooltip: l10n.homeSettingsTooltip,
    language: l10n.settingsLanguage.toUpperCase(),
    logs: l10n.settingsLogs,
    receive: l10n.homeReceiveTitle,
    codeTitle: l10n.codeReceiveTitle,
    receiveAction: l10n.codeReceiveReceiveButton,
    invalidCode: l10n.codeReceiveCodeInvalid,
    scannerReady: l10n.qrScanPointCamera,
  );
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _ensureVisible(tester, finder);
  await tester.tap(finder);
}

Future<void> _ensureVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final listView = find.byType(ListView);
    expect(listView, findsOneWidget,
        reason: 'offscreen settings rows must live in the settings ListView');
    final scrollable =
        find.descendant(of: listView, matching: find.byType(Scrollable));
    expect(scrollable, findsOneWidget,
        reason: 'settings ListView must expose its real Scrollable');
    // Locale headers may be above the language row just tapped. Return to
    // the start with actual drags before searching a lazily built list.
    for (var i = 0; i < 20; i++) {
      final position = tester.state<ScrollableState>(scrollable).position;
      if (position.pixels <= position.minScrollExtent + 1) break;
      await tester.drag(scrollable, const Offset(0, 720));
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.scrollUntilVisible(
      finder,
      240,
      scrollable: scrollable,
      maxScrolls: 12,
    );
  }
  await _pumpUntil(tester, finder);
  await tester.ensureVisible(finder);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = tester.binding.clock.now().add(timeout);
  while (finder.evaluate().isEmpty &&
      tester.binding.clock.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets,
      reason: 'timed out waiting for a real UI element: $finder');
}

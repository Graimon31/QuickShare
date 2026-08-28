// The settings button is drawn *behind* the home screen's scrolling content.
//
// A Stack paints its children in order and hit-tests them in reverse, so the
// last child wins the tap. The gear was declared before the main content,
// whose SingleChildScrollView fills the screen and takes every pointer that
// does not land on one of its own buttons — including the top-right corner
// where the gear is. On the phone this read as "the button does nothing".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/router/app_router.dart';
import 'package:quickshare/features/settings/presentation/pages/settings_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

void main() {
  setUp(() async {
    await ServiceLocator.init();
  });

  tearDown(() async {
    await sl.reset();
  });

  testWidgets('tapping the gear on the home screen opens settings',
      (tester) async {
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: AppRouter.router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ));
    // Not pumpAndSettle(): the home screen animates its background forever.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    AppRouter.router.go('/');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final gear = find.byTooltip('Settings');
    expect(gear, findsOneWidget, reason: 'the button has to be there at all');

    // warnIfMissed is what this test is really about: it fails when the tap
    // lands on something else painted on top.
    await tester.tap(gear);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(SettingsPage), findsOneWidget,
        reason: 'the gear should have navigated to the settings screen');
  });
}

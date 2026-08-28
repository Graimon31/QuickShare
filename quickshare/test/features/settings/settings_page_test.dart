// An empty history and a build without the feature look identical if the
// section is hidden — which is precisely the question somebody asked while
// staring at this screen.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/localization/locale_controller.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/features/settings/presentation/pages/settings_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('dd_settings_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsPage(
        cache: TransferCache(overrideRoot: () => root),
        diagnostics: TransferDiagnostics(overrideDir: () => root),
        // Constructed directly rather than resolved through the service
        // locator: this test never calls ServiceLocator.init(), and the
        // language picker is not what it is checking.
        localeController: LocaleController(),
      ),
    ));
    // Not pumpAndSettle(): the app carries decorative animations that repeat
    // forever, and settling waits on them indefinitely. A handful of fixed
    // frames is enough for the page to load its history and paint.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the section is there before anything has been transferred',
      (tester) async {
    await pump(tester);
    // The Language section pushed this card below the fold on the test
    // viewport's default size, so it is not built until the list scrolls to
    // it — a plain ListView only materializes children near the viewport.
    await tester.drag(find.byType(Scrollable), const Offset(0, -1000));
    await tester.pump();
    expect(find.text('LAST TRANSFERS'), findsOneWidget);
    expect(find.text('No transfers yet'), findsOneWidget);
  });

  // Deliberately no test for a populated list here. `pump` advances fake
  // time while the history is read from a real file on the real event loop,
  // so the page paints before the data arrives — fighting that in a widget
  // test costs more than it proves. What the list does with a report is
  // covered by the store's own tests; what matters here is that the section
  // exists before there is anything in it.
}

// The fallback screen only offers what the platform can actually do.
//
// DD-16. "Put both devices on one network" carried the line "This device can
// create that network itself if there is no router around." On iOS and macOS
// the button that does that is hidden — no app there may host a network — so
// the sentence pointed at a control that was not on the screen. It now
// appears only when the create-network action is present.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/features/sender/presentation/pages/network_fallback_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

void main() {
  Future<void> pump(WidgetTester tester, {VoidCallback? onCreateNetwork}) {
    return tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: NetworkFallbackPage(
        onCreateNetwork: onCreateNetwork,
      ),
    ));
  }

  testWidgets('with a create-network button, the copy mentions creating one',
      (tester) async {
    await pump(tester, onCreateNetwork: () {});

    expect(find.textContaining('create that network itself'), findsOneWidget);
    expect(find.text('Create a network for this transfer'), findsOneWidget);
  });

  testWidgets('without the button, the copy does not claim this device can host',
      (tester) async {
    await pump(tester, onCreateNetwork: null);

    expect(find.textContaining('create that network itself'), findsNothing);
    expect(find.text('Create a network for this transfer'), findsNothing);
    // The always-true half of the message is still there.
    expect(find.textContaining('no size limit'), findsOneWidget);
  });
}

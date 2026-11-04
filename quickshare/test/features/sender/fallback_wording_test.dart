// The fallback screen only offers what the platform can actually do.
//
// DD-16. "Put both devices on one network" carried the line "This device can
// create that network itself if there is no router around." On iOS and macOS
// the button that does that is hidden — no app there may host a network — so
// the sentence pointed at a control that was not on the screen. It now
// appears only when the create-network action is present.
//
// NET-02. The page used to say "no relay was reachable" for every cause. It now
// says which of four things happened, and the fourth — a relay WAS available
// and the connection still failed — is a different cause that must not blame
// the relay.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/features/sender/presentation/pages/network_fallback_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

void main() {
  Future<void> pump(WidgetTester tester,
      {VoidCallback? onCreateNetwork,
      String? noPathCode,
      Locale locale = const Locale('en')}) {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    return tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: NetworkFallbackPage(
        onCreateNetwork: onCreateNetwork,
        noPathCode: noPathCode,
      ),
    ));
  }

  /// The explanation paragraph: the second text on the page, under the title.
  String explanation(WidgetTester tester) {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((t) => t.isNotEmpty)
        .toList();
    return texts[1];
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

  group('NET-02: the page says which thing happened', () {
    const codes = [
      FailureCode.noPathRelayLimited,
      FailureCode.noPathRelayUnreachable,
      FailureCode.noPathRelayOff,
      FailureCode.noPathRelayWasAvailable,
    ];

    testWidgets('each cause has its own explanation', (tester) async {
      final seen = <String, String>{};
      for (final code in codes) {
        await pump(tester, noPathCode: code);
        seen[code] = explanation(tester);
      }
      expect(seen.values.toSet(), hasLength(4),
          reason: 'four causes, four different sentences: $seen');
    });

    testWidgets('a rate-limited relay says to try again in about a minute',
        (tester) async {
      await pump(tester, noPathCode: FailureCode.noPathRelayLimited);
      expect(explanation(tester), contains('about a minute'));
    });

    testWidgets('an unreachable relay service says it could not be reached',
        (tester) async {
      await pump(tester, noPathCode: FailureCode.noPathRelayUnreachable);
      expect(explanation(tester), contains('could not be reached'));
    });

    testWidgets('a relay that is off says it is switched off or unconfigured',
        (tester) async {
      await pump(tester, noPathCode: FailureCode.noPathRelayOff);
      expect(explanation(tester), contains('switched off'));
      expect(explanation(tester), contains('not configured'));
    });

    testWidgets('a relay that was available is not blamed', (tester) async {
      await pump(tester, noPathCode: FailureCode.noPathRelayWasAvailable);
      final text = explanation(tester);
      expect(text, contains('relay was available'));
      expect(text, isNot(contains('could not be reached')));
      expect(text, isNot(contains('about a minute')));
      expect(text, isNot(contains('switched off')));
    });

    testWidgets('with no cause known it does not claim the relay failed',
        (tester) async {
      await pump(tester);
      expect(explanation(tester), isNot(contains('no relay was reachable')));
      expect(explanation(tester), contains('Nothing has been sent yet'));
    });

    testWidgets('every cause is also explained in Russian', (tester) async {
      final cyrillic = RegExp(r'[Ѐ-ӿ]');
      final seen = <String>{};
      for (final code in codes) {
        await pump(tester, noPathCode: code, locale: const Locale('ru'));
        final text = explanation(tester);
        expect(cyrillic.hasMatch(text), isTrue, reason: '$code reads "$text"');
        seen.add(text);
      }
      expect(seen, hasLength(4));
    });

    testWidgets('the way out is offered whatever the cause', (tester) async {
      for (final code in codes) {
        await pump(tester, noPathCode: code, onCreateNetwork: () {});
        expect(find.text('Create a network for this transfer'), findsOneWidget,
            reason: code);
        expect(find.text('Put both devices on one network'), findsOneWidget);
      }
    });
  });
}

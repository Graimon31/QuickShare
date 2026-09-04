// The question only earns its place when it can change something.
//
// Wi-Fi already usable, or a platform with no direct link to offer, or a radio
// that can simply be switched on — none of those are decisions, and putting
// them to a person is just an obstacle between them and their file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/features/sender/presentation/widgets/wifi_speed_prompt.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

class _FakeLink extends PeerLinkService {
  final bool ready;
  final bool canEnable;
  final bool platformHasLink;
  final List<String> calls;

  const _FakeLink({
    required this.ready,
    required this.canEnable,
    required this.calls,
    this.platformHasLink = true,
  });

  // The behaviour under test only exists on iOS and macOS, and CI runs on
  // Linux — where the real answer is false and every one of these tests
  // silently asserted nothing at all.
  @override
  bool get supported => platformHasLink;

  @override
  Future<bool> get wifiReady async => ready;

  @override
  Future<bool> enableWifi() async {
    calls.add('enable');
    return canEnable;
  }

  @override
  Future<bool> openWifiSettings() async {
    calls.add('settings');
    return true;
  }
}

void main() {
  Future<List<String>> run(
    WidgetTester tester, {
    required bool ready,
    required bool canEnable,
    bool platformHasLink = true,
    String? tapLabel,
  }) async {
    final calls = <String>[];
    final prompt = WifiSpeedPrompt(
      link: _FakeLink(
        ready: ready,
        canEnable: canEnable,
        calls: calls,
        platformHasLink: platformHasLink,
      ),
    );

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => prompt.ask(context),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    if (tapLabel != null) {
      await tester.tap(find.text(tapLabel));
      await tester.pumpAndSettle();
    }
    return calls;
  }

  testWidgets('says nothing when Wi-Fi is already usable', (tester) async {
    final calls = await run(tester, ready: true, canEnable: false);
    expect(find.byType(AlertDialog), findsNothing);
    expect(calls, isEmpty, reason: 'nothing to switch on, nothing to ask');
  });

  testWidgets('switches the radio on silently where it can', (tester) async {
    // macOS allows this, and nothing is interrupted by doing it. There is no
    // decision here to put to a person.
    final calls = await run(tester, ready: false, canEnable: true);
    expect(find.byType(AlertDialog), findsNothing);
    expect(calls, equals(['enable']));
  });

  testWidgets('asks when the radio cannot be switched on for the user',
      (tester) async {
    await run(tester, ready: false, canEnable: false);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Send over Bluetooth'), findsOneWidget,
        reason: 'declining has to be a visible, ordinary choice');
  });

  testWidgets('taking the slow path is respected and opens nothing',
      (tester) async {
    final calls = await run(tester,
        ready: false, canEnable: false, tapLabel: 'Send over Bluetooth');
    expect(calls, equals(['enable']),
        reason: 'no is an answer; the transfer proceeds over Bluetooth');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('choosing to fix it opens the settings', (tester) async {
    final calls = await run(tester,
        ready: false, canEnable: false, tapLabel: 'Open settings');
    expect(calls, equals(['enable', 'settings']));
  });

  testWidgets('says nothing on a platform with no direct link to offer',
      (tester) async {
    // Windows, Linux, Android: switching the radio on buys nothing here,
    // because there is no direct link to carry the files. Asking anyway would
    // be an obstacle in front of a transfer that is about to work.
    final calls = await run(tester,
        ready: false, canEnable: true, platformHasLink: false);
    expect(find.byType(AlertDialog), findsNothing);
    expect(calls, isEmpty, reason: 'nothing here can be acted on');
  });
}
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/app.dart';
import 'package:quickshare/core/di/service_locator.dart';

void main() {
  // The app listens for `directdrop://` links through the app_links plugin,
  // which has no platform side under `flutter test`. Left unanswered, its
  // event channel reports a missing plugin to the framework, and the framework
  // fails whichever test happens to be running when that lands — one of the
  // two below, depending on how long it has to run. The plugin's two channels
  // are answered with "no link", which is what a launch from the icon gets.
  const links = [
    MethodChannel('com.llfbandit.app_links/messages'),
    MethodChannel('com.llfbandit.app_links/events'),
  ];

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in links) {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
    }
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in links) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    await sl.reset();
  });

  testWidgets('DirectDropApp smoke test', (WidgetTester tester) async {
    await ServiceLocator.init();
    await tester.pumpWidget(const DirectDropApp());
    expect(find.byType(DirectDropApp), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('the running app opens no listening socket of its own at start-up',
      (WidgetTester tester) async {
    // The invitation listener used to bind 53317 the moment the app opened,
    // and with it announced this device to the whole network. If anything in
    // the app listens there now, the bind below is refused.
    //
    // Real sockets, so outside the test's fake clock.
    Future<ServerSocket?> bind() async => tester.runAsync<ServerSocket?>(() async {
          try {
            return await ServerSocket.bind(InternetAddress.anyIPv4, 53317);
          } on SocketException {
            return null;
          }
        });

    final before = await bind();
    if (before == null) {
      markTestSkipped('port 53317 is in use by something else on this machine');
      return;
    }
    await tester.runAsync(before.close);

    await ServiceLocator.init();
    await tester.pumpWidget(const DirectDropApp());
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 800)));
    await tester.pump(const Duration(seconds: 1));

    final after = await bind();
    expect(after, isNotNull, reason: 'the app holds the old invitation port');
    await tester.runAsync(after!.close);
  });
}

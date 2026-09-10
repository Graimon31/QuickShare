// The `?room=` share link is gone, and nothing rebuilds it.
//
// DD-22. The live format is `directdrop://join?p=<payload>`. `?room=` belonged
// to the room-based WebRTC handshake — `POST /webrtc/answer`, a room id in the
// QR — which was replaced by the sealed serverless flow long ago. But three
// places still constructed a `?room=` string: the router's `/receive/code`
// branch, the scanner's internet-mode path, and a comment offering it as the
// canonical shape. A receiver handed one shows an error: it parses as neither
// ten digits nor a payload link.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/router/app_router.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

void main() {
  setUp(() => ServiceLocator.init());
  tearDown(() => sl.reset());

  test('a bare share link is a payload link, not a room link', () {
    // The one canonical shape a QR or a paste is expected to carry.
    final link = DeepLinkService.buildPayloadLink('SOME_PAYLOAD_BYTES');
    expect(link, startsWith('directdrop://join?p='));
    expect(link, isNot(contains('room=')));
  });

  test('a `?room=` link parses as nothing the receiver can use', () {
    // Not a payload link — no `?p=`.
    expect(
      DeepLinkService.parseShareLink('directdrop://join?room=A1B2C3'),
      isNull,
    );
    // And `unwrapToQrPayload` leaves it untouched rather than pulling a
    // payload out of it, so the QR decoder downstream fails it cleanly.
    expect(
      DeepLinkService.unwrapToQrPayload('directdrop://join?room=A1B2C3'),
      equals('directdrop://join?room=A1B2C3'),
    );
  });

  testWidgets('/receive/code?room=… no longer prefills anything',
      (tester) async {
    // The route used to turn a `room` query back into a
    // `directdrop://join?room=` string and auto-submit it, which failed. Now
    // the parameter is ignored: the screen opens empty, waiting for a code.
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: AppRouter.router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    AppRouter.router.go('/receive/code?room=A1B2C3&sig=deadbeef');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Page not found'), findsNothing);
    // No text field anywhere holds the dead link.
    expect(find.textContaining('room='), findsNothing);

    // Tear down real work the page may have started.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
  });

}

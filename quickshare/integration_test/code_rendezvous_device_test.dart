// Does the rendezvous work against the platform's own responder?
//
//     flutter test integration_test/code_rendezvous_device_test.dart -d macos
//
// The suite in `test/` runs headless with no native plugins, so every mDNS
// call there is a MissingPluginException: it can pin what goes on the air
// (`test/core/network/lan_discovery_test.dart`) but not that the responder
// carries it. That is this file's job, on the real service type the shipped
// app declares in Info.plist — a made-up type is refused by macOS Local
// Network privacy before anything can be observed.
//
// There is no list of devices to look at any more, so what is checked is the
// whole of what the rendezvous promises:
//
//  * an offer that is on the air can be found by the hint of its code;
//  * a rotation moves the hint: the new one is found, the old one is gone;
//  * when the offer ends, nothing is left.
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/session_code.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Waits until [browser] has heard a candidate for [hint] — or, with
  /// [present] false, has stopped hearing one.
  Future<bool> settles(
    RendezvousBrowser browser,
    String hint, {
    required bool present,
    Duration within = const Duration(seconds: 25),
  }) async {
    final deadline = DateTime.now().add(within);
    while (DateTime.now().isBefore(deadline)) {
      await browser.refresh();
      final heard = browser.current.any((c) => c.hint == hint);
      if (heard == present) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  /// Two different hints, so a rotation is visible. One byte can collide.
  (String, String) twoHints() {
    final first = SessionCode.generate().discoveryHint;
    var second = SessionCode.generate().discoveryHint;
    while (second == first) {
      second = SessionCode.generate().discoveryHint;
    }
    return (first, second);
  }

  testWidgets('an offer is found by its hint, moves with a rotation, and '
      'leaves nothing behind', (tester) async {
    final (first, second) = twoHints();
    final advertiser = NsdRendezvousAdvertiser();
    final browser = NsdRendezvousBrowser();
    addTearDown(advertiser.stop);
    addTearDown(browser.stop);

    expect(await browser.start(), isTrue,
        reason: 'this platform could not browse at all');
    expect(browser.current.where((c) => c.hint == first), isEmpty,
        reason: 'nothing of ours is on the air yet');

    await advertiser.advertise(port: 18123, hint: first);
    expect(advertiser.current, isNotNull,
        reason: 'the platform refused the registration');
    expect(await settles(browser, first, present: true), isTrue,
        reason: 'the offer never became visible to a browser');
    final heard = browser.current.firstWhere((c) => c.hint == first);
    expect(heard.port, 18123);
    print('heard ${heard.address.address}:${heard.port} hint ${heard.hint}');

    // A rotation: new name, new hint.
    await advertiser.advertise(port: 18123, hint: second);
    expect(await settles(browser, second, present: true), isTrue,
        reason: 'the rotated offer never became visible');
    expect(await settles(browser, first, present: false), isTrue,
        reason: 'the old hint is still on the air after the rotation');

    await advertiser.stop();
    expect(await settles(browser, second, present: false), isTrue,
        reason: 'the offer is still on the air after it ended');
    expect(advertiser.current, isNull);
  });
}

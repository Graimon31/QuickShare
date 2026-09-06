// Does the macOS Wi-Fi bridge actually work, sandbox and all?
//
//     flutter test integration_test/macos_wifi_bridge_test.dart -d macos
//
// Runs the real app against the real CoreWLAN, because the question it answers
// cannot be answered any other way: `CWInterface.associate` and
// `scanForNetworks` are public API, but the app ships sandboxed, and whether
// the sandbox lets them through is a fact about this machine rather than about
// the documentation.
//
// Scanning also became a Location Services matter in macOS 14 — Apple counts
// the list of nearby networks as location data, which it is — so an outright
// refusal here is a real outcome worth seeing, not a broken test.
//
// Deliberately does not join anything: putting the developer's Mac on some
// other network mid-test would be rude, and the join path is exercised by the
// pair test with two real devices.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:quickshare/core/network/local_hotspot_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final hotspot = LocalHotspotService();

  testWidgets('a Mac says it can join a network but not raise one',
      (tester) async {
    expect(hotspot.canJoinProgrammatically, isTrue,
        reason: 'CWInterface.associate is public API');
    expect(hotspot.canHost, isFalse,
        reason: 'macOS has no supported API for raising an access point');
    expect(hotspot.canScanForNetworks, isTrue);
  });

  testWidgets('raising a network is refused with an explanation, not a crash',
      (tester) async {
    // The Mac is always the guest. What matters is that the refusal says who
    // should host instead.
    await expectLater(
      hotspot.startHosting(),
      throwsA(isA<HotspotException>().having(
        (e) => e.message.toLowerCase(),
        'message',
        anyOf(contains('android'), contains('cannot create')),
      )),
    );
  });

  testWidgets('an empty result is never mistaken for an empty room',
      (tester) async {
    // The failure this test exists for. Without Location Services macOS 14+
    // answers a scan with an empty array and no error — indistinguishable from
    // "nothing is nearby" on a machine surrounded by networks. The first
    // version of this test passed while the feature did nothing at all.
    final authorization = await hotspot.locationAuthorization();
    print('location authorization: $authorization');

    if (authorization != 'granted') {
      // Then a scan must refuse, loudly, naming what the user can change.
      await expectLater(
        hotspot.scanForNetworks(),
        throwsA(isA<HotspotException>().having(
          (e) => e.message,
          'message',
          contains('Location Services'),
        )),
        reason: 'an unauthorised scan must not quietly return an empty list',
      );
      return;
    }

    final networks = await hotspot.scanForNetworks();
    print('scan returned ${networks.length} network(s)');
    expect(networks, isNotEmpty,
        reason: 'with authorization granted, a machine on Wi-Fi sees itself '
            'and its neighbours');

    final ours = await hotspot.scanForNetworks(prefix: 'DirectDrop-');
    expect(ours.every((n) => n.startsWith('DirectDrop-')), isTrue,
        reason: 'the prefix filter is what turns networks into devices');
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('the bridge knows which network this Mac is on', (tester) async {
    // Needed so the transfer can put the Mac back afterwards. Null is legal
    // when there is genuinely no Wi-Fi — but it is also what macOS returns
    // when location access is missing, which is why the two are checked
    // together rather than apart.
    if (!Platform.isMacOS) return;
    final ssid = await hotspot.currentSsid();
    final authorization = await hotspot.locationAuthorization();
    print('current network: ${ssid ?? "(none)"} (location: $authorization)');

    if (authorization == 'granted') {
      final addresses = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final onWifi = addresses.any((i) => i.name == 'en0');
      if (onWifi) {
        expect(ssid, isNotNull,
            reason: 'authorised and on en0, so the name must be readable');
      }
    }
  });
}

// The entitlement an iPhone needs to join the network the other device raised.
//
// DD-13. The file existed, said the right thing, and was even registered in
// the Xcode project — and no build configuration pointed at it, so nothing it
// declared ever reached a signed binary. `NEHotspotConfiguration.apply()` then
// failed at runtime, on the one path an iPhone has left: it cannot host a
// network, so joining one is the whole of its part in a Bluetooth transfer.
//
// A defect that reads as "the file is right there" is exactly the kind that
// comes back, so it is pinned here rather than in anyone's memory. This
// checks the project, not the signature: whether the entitlement survives
// into the binary depends on a provisioning profile that carries the Hotspot
// Configuration capability, which lives in the Apple developer account and
// not in this repository.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const entitlement = 'com.apple.developer.networking.HotspotConfiguration';

  test('the entitlements file declares what an iPhone needs to join', () {
    final file = File('ios/Runner/Runner.entitlements');
    expect(file.existsSync(), isTrue,
        reason: 'ios/Runner/Runner.entitlements is missing');
    final raw = file.readAsStringSync();
    final stripped =
        raw.replaceAll(RegExp(r'<!--.*?-->', multiLine: true, dotAll: true), '');
    expect(stripped, contains('<key>$entitlement</key>'));
  });

  test('every build configuration signs with it', () {
    // Debug, Release and Profile. One left out is a build that installs and
    // then cannot join, which is worse than one that fails to sign.
    final project =
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();

    final signed = 'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'
        .allMatches(project)
        .length;
    final configurations =
        'PRODUCT_BUNDLE_IDENTIFIER = com.mrgraimon.directdrop;'
            .allMatches(project)
            .length;

    expect(configurations, greaterThan(0),
        reason: 'the Runner target should have build configurations');
    expect(signed, equals(configurations),
        reason: 'every Runner configuration must point at the entitlements '
            'file; $signed of $configurations do');
  });

  test('the file is part of the project, not merely on disk', () {
    // It was, which is why the gap was easy to miss: Xcode listed it in the
    // navigator while no configuration referred to it.
    final project =
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(project, contains('Runner.entitlements'));
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';

void main() {
  const oneMb = 1024 * 1024;

  group('relayLimitAllows', () {
    test('a direct path is never capped', () {
      // Same Wi-Fi costs nobody anything: 500 GB is fine.
      expect(
        relayLimitAllows(IcePathKind.direct, 500 * 1024 * oneMb,
            limitBytes: 50 * oneMb),
        isTrue,
      );
    });

    test('a peer-to-peer path is never capped', () {
      expect(
        relayLimitAllows(IcePathKind.peerToPeer, 900 * oneMb,
            limitBytes: 50 * oneMb),
        isTrue,
      );
    });

    test('a relayed path is capped', () {
      expect(
        relayLimitAllows(IcePathKind.relayed, 51 * oneMb,
            limitBytes: 50 * oneMb),
        isFalse,
      );
    });

    test('a relayed session exactly at the limit is allowed through', () {
      expect(
        relayLimitAllows(IcePathKind.relayed, 50 * oneMb,
            limitBytes: 50 * oneMb),
        isTrue,
      );
    });

    test('an unknown path is capped like a relayed one', () {
      // DD-06. `getStats()` came back empty, threw, or named a candidate with
      // no type. "We could not confirm this is free" is not "this is free",
      // and gigabytes across a stranger's TURN by default is the one thing
      // the product says it will not do.
      expect(
        relayLimitAllows(IcePathKind.unknown, 900 * oneMb,
            limitBytes: 50 * oneMb),
        isFalse,
      );
    });

    test('an unknown path under the cap still proceeds', () {
      // The cap is the whole judgement — a small session over a path that
      // might be direct is not worth blocking.
      expect(
        relayLimitAllows(IcePathKind.unknown, 10 * oneMb,
            limitBytes: 50 * oneMb),
        isTrue,
      );
    });

    test('a confirmed direct path passes whatever an unknown one would fail',
        () {
      // The distinction the fix turns on: confirmed free vs unconfirmed.
      const huge = 900 * oneMb;
      expect(
          relayLimitAllows(IcePathKind.direct, huge, limitBytes: 50 * oneMb),
          isTrue);
      expect(
          relayLimitAllows(IcePathKind.unknown, huge, limitBytes: 50 * oneMb),
          isFalse);
    });

    test('a zero limit disables the cap for an unknown path too', () {
      expect(
        relayLimitAllows(IcePathKind.unknown, 900 * oneMb, limitBytes: 0),
        isTrue,
      );
    });

    test('a zero limit disables the cap, for a paid relay', () {
      expect(
        relayLimitAllows(IcePathKind.relayed, 900 * oneMb, limitBytes: 0),
        isTrue,
      );
    });

    test('defaults to the configured 2 GB ceiling', () {
      // The relay is the project's own Cloudflare Calls allocation, not a
      // paid metered account, so the default matches the largest file the
      // WebRTC path can carry at all.
      expect(AppConstants.maxRelayTransferBytes, equals(2 * 1024 * oneMb));
      expect(
          relayLimitAllows(IcePathKind.relayed, 2 * 1024 * oneMb + oneMb),
          isFalse);
      expect(relayLimitAllows(IcePathKind.relayed, 500 * oneMb), isTrue);
    });
  });
}

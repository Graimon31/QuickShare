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

    test('an unknown path gets the benefit of the doubt', () {
      // Refusing a transfer because a WebRTC statistic was missing would be
      // worse than the bandwidth it might cost.
      expect(
        relayLimitAllows(IcePathKind.unknown, 900 * oneMb,
            limitBytes: 50 * oneMb),
        isTrue,
      );
    });

    test('a zero limit disables the cap, for a paid relay', () {
      expect(
        relayLimitAllows(IcePathKind.relayed, 900 * oneMb, limitBytes: 0),
        isTrue,
      );
    });

    test('defaults to the configured 50 MB ceiling', () {
      expect(AppConstants.maxRelayTransferBytes, equals(50 * oneMb));
      expect(relayLimitAllows(IcePathKind.relayed, 60 * oneMb), isFalse);
      expect(relayLimitAllows(IcePathKind.relayed, 10 * oneMb), isTrue);
    });
  });
}

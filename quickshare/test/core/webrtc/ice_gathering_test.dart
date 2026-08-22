import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';

RTCIceCandidate _candidate(String type, {String address = '1.2.3.4'}) =>
    RTCIceCandidate(
      'candidate:1 1 udp 2122260223 $address 50000 typ $type generation 0',
      '0',
      0,
    );

void main() {
  group('IceGatheringTracker', () {
    test('starts with nothing gathered', () {
      final tracker = IceGatheringTracker();
      expect(tracker.count, isZero);
      expect(tracker.sawRelay, isFalse);
      expect(tracker.sawServerReflexive, isFalse);
    });

    test('host candidates alone are not enough to stop waiting', () {
      // A host-only set means the peers must already share a network. The
      // gathering wait must not return early on these.
      final tracker = IceGatheringTracker()
        ..observe(_candidate('host', address: '192.168.3.52'))
        ..observe(_candidate('host', address: '10.0.0.7'));
      expect(tracker.count, equals(2));
      expect(tracker.sawRelay, isFalse);
      expect(tracker.sawServerReflexive, isFalse);
    });

    test('recognises a server-reflexive candidate', () {
      final tracker = IceGatheringTracker()..observe(_candidate('srflx'));
      expect(tracker.sawServerReflexive, isTrue);
      expect(tracker.sawRelay, isFalse);
    });

    test('recognises a relay candidate', () {
      // This is the one that matters behind a VPN or a symmetric NAT: it is
      // the reason the gathering ceiling was raised off one second.
      final tracker = IceGatheringTracker()..observe(_candidate('relay'));
      expect(tracker.sawRelay, isTrue);
    });

    test('ignores empty end-of-candidates markers', () {
      final tracker = IceGatheringTracker()
        ..observe(RTCIceCandidate(null, '0', 0))
        ..observe(RTCIceCandidate('', '0', 0));
      expect(tracker.count, isZero);
    });

    test('describe() reports what will end up in the QR code', () {
      final tracker = IceGatheringTracker()
        ..observe(_candidate('host'))
        ..observe(_candidate('srflx'))
        ..observe(_candidate('relay'));
      expect(tracker.describe(), contains('3 candidates'));
      expect(tracker.describe(), contains('srflx: true'));
      expect(tracker.describe(), contains('relay: true'));
    });
  });

  group('gathering budget', () {
    test('leaves room for a TURN allocation over TLS', () {
      // Measured on the target network: a TURN handshake over TLS needed
      // 557-1040 ms just to complete. The old one-second cap discarded the
      // relay candidate, and in serverless mode there is no trickle path to
      // deliver it later.
      expect(AppConstants.iceGatheringMaxWait.inMilliseconds,
          greaterThan(1500));
    });
  });
}

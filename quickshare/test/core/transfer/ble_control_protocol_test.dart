// A folder sent over Bluetooth to a build that predates folders arrived as
// its first file, reported as a completed transfer, with nothing anywhere to
// say the rest existed. Silent partial delivery is the one failure worth
// spending a round trip to avoid, so a receiver now says what it can take
// before it says go.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/transfer/ble_control_protocol.dart';

void main() {
  group('capabilities', () {
    test('a receiver announces the generation it understands', () {
      expect(BleControlProtocol.capabilities(), equals('CAPS:2'));
      expect(BleControlProtocol.parseCapabilities('CAPS:2'), equals(2));
    });

    test('START is not mistaken for an announcement', () {
      // The two share a characteristic; confusing them would either start a
      // transfer nobody asked for or silently drop the one that was.
      expect(BleControlProtocol.parseCapabilities('START'), isNull);
      expect(BleControlProtocol.parseCapabilities('START:abc'), isNull);
    });

    test('an unreadable announcement is no evidence either way', () {
      // Not generation 1: "I could not parse this" and "the peer is old" are
      // different claims, and only one of them justifies refusing a folder.
      expect(BleControlProtocol.parseCapabilities('CAPS:'), isNull);
      expect(BleControlProtocol.parseCapabilities('CAPS:banana'), isNull);
    });

    test('a future generation reads as itself, not as a failure', () {
      expect(BleControlProtocol.parseCapabilities('CAPS:7'), equals(7));
    });
  });

  group('what a peer may be sent', () {
    test('a peer that announced this generation takes the whole list', () {
      expect(
          BleControlProtocol.peerCanTakeSession(
              fileCount: 412, peerGeneration: 2),
          isTrue);
    });

    test('silence means an old build, and a list is refused', () {
      // Every build through v1.0.10 wrote nothing here, so silence is exactly
      // what an old receiver sounds like. Guessing the other way is what
      // delivered one photo out of a folder and called it a success.
      expect(
          BleControlProtocol.peerCanTakeSession(
              fileCount: 412, peerGeneration: null),
          isFalse);
      expect(
          BleControlProtocol.peerCanTakeSession(
              fileCount: 2, peerGeneration: 1),
          isFalse);
    });

    test('one file goes to anyone', () {
      // The shape that always worked. Refusing it to protect the new case
      // would break the ordinary one.
      expect(
          BleControlProtocol.peerCanTakeSession(
              fileCount: 1, peerGeneration: null),
          isTrue);
    });

    test('a newer peer is not refused for being newer', () {
      expect(
          BleControlProtocol.peerCanTakeSession(
              fileCount: 9, peerGeneration: 7),
          isTrue);
    });

    test('the refusal says what to do about it', () {
      // "Bluetooth transfer failed" sends somebody hunting a radio problem
      // that is not there.
      expect(BleControlProtocol.sessionRefusedMessage, contains('Update'));
      expect(BleControlProtocol.sessionRefusedMessage, contains('Wi-Fi'));
    });
  });

  group('start', () {
    test('the token spelling is accepted', () {
      expect(BleControlProtocol.start('abc'), equals('START:abc'));
      expect(BleControlProtocol.isStart('START:abc', 'abc'), isTrue);
    });

    test('the bare spelling still works', () {
      // What the first builds wrote, and what an unauthenticated local test
      // still writes.
      expect(BleControlProtocol.isStart('START', 'abc'), isTrue);
      expect(BleControlProtocol.isStart('START', null), isTrue);
    });

    test('somebody else\'s token does not start this session', () {
      expect(BleControlProtocol.isStart('START:other', 'abc'), isFalse);
    });
  });
}

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
      expect(BleControlProtocol.capabilities(), equals('CAPS:4'));
      expect(BleControlProtocol.parseCapabilities('CAPS:4'), equals(4));
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

  group('who may be sent to at all', () {
    // DD-10, decided: generation 4 takes the file off this radio, and a peer
    // that only knows the radio is told to update rather than served slowly
    // down a second delivery path that publishes what arrives without
    // checking its length. The softer rule this replaced — no folder to an
    // old peer, but one file to anyone — is gone with it.
    test('a peer that announced this generation is sent to', () {
      expect(BleControlProtocol.peerSupportsDirectLink(4), isTrue);
    });

    test('a newer peer is not refused for being newer', () {
      expect(BleControlProtocol.peerSupportsDirectLink(7), isTrue);
    });

    test('silence means an old build, and old builds are refused', () {
      // Every build through v1.0.10 wrote nothing here, so silence is exactly
      // what an old receiver sounds like. Guessing the other way is what
      // delivered one photo out of a folder and called it a success.
      expect(BleControlProtocol.peerSupportsDirectLink(null), isFalse);
      expect(BleControlProtocol.peerSupportsDirectLink(1), isFalse);
    });

    test('a generation-3 peer understood lists, but not the link', () {
      expect(BleControlProtocol.peerSupportsDirectLink(3), isFalse);
    });

    test('one file is refused too, which is the breaking part', () {
      // Named out loud because it is the decision, not an oversight: the
      // shape that always worked no longer works with an old peer.
      expect(BleControlProtocol.peerSupportsDirectLink(1), isFalse);
    });

    test('the refusal says what to do about it', () {
      // "Bluetooth transfer failed" sends somebody hunting a radio problem
      // that is not there.
      expect(BleControlProtocol.directLinkRequiredMessage, contains('Update'));
      expect(BleControlProtocol.directLinkRequiredMessage, contains('Wi-Fi'));
    });
  });

  group('start', () {
    test('the token spelling is accepted', () {
      expect(BleControlProtocol.start('abc'), equals('START:abc'));
      expect(BleControlProtocol.isStart('START:abc', 'abc'), isTrue);
    });

    test('a bare START is refused — the token is mandatory', () {
      // Without the token, any device that connected to the GATT server could
      // begin the transfer.
      expect(BleControlProtocol.isStart('START', 'abc'), isFalse);
      expect(BleControlProtocol.isStart('START', null), isFalse);
      expect(BleControlProtocol.isStart('START:abc', null), isFalse);
      expect(BleControlProtocol.isStart('START:abc', ''), isFalse);
    });

    test('somebody else\'s token does not start this session', () {
      expect(BleControlProtocol.isStart('START:other', 'abc'), isFalse);
    });

    test('a START-shaped write without the token is flagged as unauthorized',
        () {
      expect(BleControlProtocol.isUnauthorizedStart('START', 'abc'), isTrue);
      expect(
          BleControlProtocol.isUnauthorizedStart('START:other', 'abc'), isTrue);
      // The real thing is not "unauthorized".
      expect(
          BleControlProtocol.isUnauthorizedStart('START:abc', 'abc'), isFalse);
      // Neither is an unrelated command.
      expect(BleControlProtocol.isUnauthorizedStart('CAPS:3', 'abc'), isFalse);
    });

    test('the stale-receiver message names the way out', () {
      expect(BleControlProtocol.staleReceiverMessage, contains('Wi-Fi'));
      expect(BleControlProtocol.staleReceiverMessage, contains('Update'));
    });
  });

  group('hotspot offer', () {
    test('the plain shape an Android hotspot produces', () {
      // The wire format is pinned: the Swift bridges parse this string, so a
      // drift here breaks the join on exactly the pairs nobody tests with.
      final command =
          BleControlProtocol.apOffer('AndroidShare_4821', 'x7k29dmq');
      expect(command, equals('AP:AndroidShare_4821:x7k29dmq'));
      final offer = BleControlProtocol.parseApOffer(command);
      expect(offer?.ssid, equals('AndroidShare_4821'));
      expect(offer?.passphrase, equals('x7k29dmq'));
    });

    test('credentials survive a round trip, colons and spaces included', () {
      // A hotspot name is chosen by the system; nothing about an SSID or a
      // WPA passphrase promises to avoid the separator, so the parts travel
      // percent-encoded.
      final command =
          BleControlProtocol.apOffer('Cafe: Guest Wi-Fi', 'p@ss:word 123');
      final offer = BleControlProtocol.parseApOffer(command);
      expect(offer?.ssid, equals('Cafe: Guest Wi-Fi'));
      expect(offer?.passphrase, equals('p@ss:word 123'));
    });

    test('not an offer reads as none', () {
      expect(BleControlProtocol.parseApOffer('START:abc'), isNull);
      expect(BleControlProtocol.parseApOffer('CAPS:4'), isNull);
      expect(BleControlProtocol.parseApOffer('AP:'), isNull);
      expect(BleControlProtocol.parseApOffer('AP:onlyone'), isNull);
      expect(BleControlProtocol.parseApOffer('AP:a:b:c'), isNull);
    });

    test('the limits are the 802.11 ones', () {
      // An SSID is at most 32 bytes, a WPA passphrase 8 to 63 characters; a
      // write outside them is malformed, not a network to look for.
      expect(
          BleControlProtocol.parseApOffer(
              BleControlProtocol.apOffer('A' * 33, 'x7k29dmq')),
          isNull);
      expect(
          BleControlProtocol.parseApOffer(
              BleControlProtocol.apOffer('AndroidShare_4821', 'short')),
          isNull);
      expect(
          BleControlProtocol.parseApOffer(
              BleControlProtocol.apOffer('AndroidShare_4821', 'x' * 64)),
          isNull);
      // 32 bytes, not 32 characters: a Cyrillic name spends two bytes per
      // letter.
      expect(
          BleControlProtocol.parseApOffer(
              BleControlProtocol.apOffer('Д' * 17, 'x7k29dmq')),
          isNull);
      expect(
          BleControlProtocol.parseApOffer(
              BleControlProtocol.apOffer('Д' * 16, 'x7k29dmq')),
          isNotNull);
    });

    test('garbled percent-encoding is dropped, not thrown', () {
      expect(BleControlProtocol.parseApOffer('AP:%zz:x7k29dmq'), isNull);
    });
  });

  group('the direct-link generation', () {
    test('a peer from this generation on can take part', () {
      expect(BleControlProtocol.peerSupportsDirectLink(4), isTrue);
      expect(BleControlProtocol.peerSupportsDirectLink(7), isTrue);
    });

    test('a peer below it cannot, whatever it could once do', () {
      // Generation 4 is where the bytes left this radio: a peer that only
      // knows the old way gets told to update, not sent the file slowly.
      expect(BleControlProtocol.peerSupportsDirectLink(3), isFalse);
      expect(BleControlProtocol.peerSupportsDirectLink(null), isFalse);
    });

    test('the message names the fix and the reason', () {
      // "Update" alone sends somebody to the store page wondering why; the
      // reason rides in the same breath.
      expect(BleControlProtocol.directLinkRequiredMessage, contains('Update'));
      expect(
          BleControlProtocol.directLinkRequiredMessage, contains('Wi-Fi'));
    });
  });
}

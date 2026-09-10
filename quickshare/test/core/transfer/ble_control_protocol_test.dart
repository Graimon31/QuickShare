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
    // DD-03. The pair used to travel as itself, percent-encoded, on a
    // characteristic with no bonding behind it — the WPA passphrase of a
    // live network in a packet anything in range could read. What crosses
    // now is a sealed blob, and this layer deliberately cannot tell what is
    // in it: `LinkSecret` seals and opens, and checks the 802.11 limits
    // after opening, where they can be checked on the real values.
    test('the wire shape is pinned, because both Swift bridges parse it', () {
      final command = BleControlProtocol.apOffer('c2VhbGVkLWJsb2I');
      expect(command, equals('AP:c2VhbGVkLWJsb2I'));
      expect(BleControlProtocol.parseApOffer(command),
          equals('c2VhbGVkLWJsb2I'));
    });

    test('not an offer reads as none', () {
      expect(BleControlProtocol.parseApOffer('START:abc'), isNull);
      expect(BleControlProtocol.parseApOffer('CAPS:4'), isNull);
      expect(BleControlProtocol.parseApOffer('KEX:abc'), isNull);
      expect(BleControlProtocol.parseApOffer('AP:'), isNull);
      expect(BleControlProtocol.parseApOffer('AP:   '), isNull);
    });

    test('a write far past the size of a sealed pair is not one', () {
      // A ceiling rather than a shape: the contents are opaque here, so
      // length is the only thing this layer can judge.
      expect(BleControlProtocol.parseApOffer('AP:${'x' * 513}'), isNull);
      expect(BleControlProtocol.parseApOffer('AP:${'x' * 512}'), isNotNull);
    });
  });

  group('the key exchange', () {
    test('a public half survives the round trip', () {
      const key = 'MCowBQYDK2VuAyEAGb9ECWmEzf6FQbrBZ9w7lshQhqowtrbL';
      expect(BleControlProtocol.parseKeyExchange(
              BleControlProtocol.keyExchange(key)),
          equals(key));
    });

    test('the other commands are not mistaken for it', () {
      // They share one characteristic, and taking a START for a key would
      // seal the credentials against nonsense.
      expect(BleControlProtocol.parseKeyExchange('START:abc'), isNull);
      expect(BleControlProtocol.parseKeyExchange('AP:blob'), isNull);
      expect(BleControlProtocol.parseKeyExchange('CAPS:4'), isNull);
    });

    test('an empty or oversized key is refused', () {
      // An X25519 public key is 32 bytes — 44 characters of base64url.
      expect(BleControlProtocol.parseKeyExchange('KEX:'), isNull);
      expect(BleControlProtocol.parseKeyExchange('KEX:   '), isNull);
      expect(BleControlProtocol.parseKeyExchange('KEX:${'x' * 65}'), isNull);
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

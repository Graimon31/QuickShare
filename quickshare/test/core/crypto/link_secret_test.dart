// DD-03. The passphrase of a live network travelled in a GATT write with no
// bonding and no encryption behind it, so anything in radio range could read
// it. It has to travel: an Android host's network names itself, and the SSID
// and passphrase `startLocalOnlyHotspot` hands back cannot be derived from
// anything the two devices already share.
//
// The key is exchanged rather than taken from the session token, because a
// receiver picked off the sender's list has no token yet — that arrives after
// the link is up, which is too late to have protected the credentials that
// built it.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/crypto/link_secret.dart';

void main() {
  const session = 'VM7SD2TA';

  test('the two sides reach the same credentials', () async {
    final host = await LinkSecret.generate();
    final joiner = await LinkSecret.generate();

    final sealed = await host.seal(
      ssid: 'AndroidShare_7712',
      passphrase: 'X7K29DMQ41ZT',
      sessionId: session,
      peerPublicKey: joiner.publicKey,
    );

    final opened = await joiner.open(
      sealed: sealed,
      sessionId: session,
      peerPublicKey: host.publicKey,
    );

    expect(opened, isNotNull);
    expect(opened!.ssid, equals('AndroidShare_7712'));
    expect(opened.passphrase, equals('X7K29DMQ41ZT'));
  });

  test('a listener with both public keys gets nothing', () async {
    // What a sniffer actually has: everything that crossed the wire. The
    // shared secret is the one thing that did not.
    final host = await LinkSecret.generate();
    final joiner = await LinkSecret.generate();
    final eavesdropper = await LinkSecret.generate();

    final sealed = await host.seal(
      ssid: 'AndroidShare_7712',
      passphrase: 'X7K29DMQ41ZT',
      sessionId: session,
      peerPublicKey: joiner.publicKey,
    );

    expect(sealed, isNot(contains('X7K29DMQ41ZT')));
    expect(
      await eavesdropper.open(
          sealed: sealed, sessionId: session, peerPublicKey: host.publicKey),
      isNull,
    );
  });

  test('credentials from another session do not open here', () async {
    // Bound to the session, so a frame captured from one negotiation cannot
    // be replayed into the next one between the same two devices.
    final host = await LinkSecret.generate();
    final joiner = await LinkSecret.generate();

    final sealed = await host.seal(
      ssid: 'AndroidShare_7712',
      passphrase: 'X7K29DMQ41ZT',
      sessionId: 'SESSION-A',
      peerPublicKey: joiner.publicKey,
    );

    expect(
      await joiner.open(
          sealed: sealed,
          sessionId: 'SESSION-B',
          peerPublicKey: host.publicKey),
      isNull,
    );
  });

  test('a tampered frame does not open', () async {
    final host = await LinkSecret.generate();
    final joiner = await LinkSecret.generate();

    final sealed = await host.seal(
      ssid: 'AndroidShare_7712',
      passphrase: 'X7K29DMQ41ZT',
      sessionId: session,
      peerPublicKey: joiner.publicKey,
    );
    final flipped = sealed.replaceRange(8, 9, sealed[8] == 'A' ? 'B' : 'A');

    expect(
      await joiner.open(
          sealed: flipped, sessionId: session, peerPublicKey: host.publicKey),
      isNull,
    );
  });

  test('rubbish off the radio is an ordinary event, not a crash', () async {
    // Anything can write to this characteristic, so this is a normal input.
    final joiner = await LinkSecret.generate();
    final host = await LinkSecret.generate();

    for (final junk in ['', 'not-base64!!', 'AAAA', 'x' * 200]) {
      expect(
        await joiner.open(
            sealed: junk, sessionId: session, peerPublicKey: host.publicKey),
        isNull,
        reason: '"$junk"',
      );
    }
  });

  test('credentials outside the 802.11 limits are refused', () async {
    // Checked after opening rather than handed to the Wi-Fi stack, which
    // fails less legibly.
    final host = await LinkSecret.generate();
    final joiner = await LinkSecret.generate();

    Future<({String ssid, String passphrase})?> roundTrip(
        String ssid, String passphrase) async {
      final sealed = await host.seal(
        ssid: ssid,
        passphrase: passphrase,
        sessionId: session,
        peerPublicKey: joiner.publicKey,
      );
      return joiner.open(
          sealed: sealed, sessionId: session, peerPublicKey: host.publicKey);
    }

    expect(await roundTrip('', 'X7K29DMQ41ZT'), isNull);
    expect(await roundTrip('x' * 33, 'X7K29DMQ41ZT'), isNull);
    expect(await roundTrip('Net', 'short'), isNull);
    expect(await roundTrip('Net', 'x' * 64), isNull);
  });

  test('a fresh pair every negotiation', () async {
    final first = await LinkSecret.generate();
    final second = await LinkSecret.generate();
    expect(first.publicKey, isNot(equals(second.publicKey)));
  });
}

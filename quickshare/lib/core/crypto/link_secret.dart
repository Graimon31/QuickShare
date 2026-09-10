import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The credentials of the network two devices raise between them, and the
/// secret that keeps them off the air.
///
/// ## Why this exists
///
/// The rendezvous runs over a GATT characteristic with no bonding and no
/// encryption, and the network an Android host raises names itself:
/// `startLocalOnlyHotspot` picks the SSID and the passphrase and hands them
/// back, so they cannot be derived from anything both sides already know —
/// they have to travel. They travelled in the clear, which put the WPA
/// passphrase of a live network in a packet anyone in radio range could read.
///
/// ## Why a key exchange and not the session token
///
/// The obvious key is the session token: both sides hold it whenever a code
/// was read out or a QR was scanned. But a receiver can arrive with neither —
/// it announces itself, the person sending picks it off a list, and the token
/// only reaches it *after* the link is up, in the frame that says where the
/// file is. Sealing with the token would have left exactly that case in the
/// clear, and it is the case the device list exists to serve.
///
/// So each side makes an ephemeral key pair and sends the public half. A
/// passive listener sees both public keys and can do nothing with them; the
/// shared secret is never transmitted. That covers the coded path and the
/// uncoded one with the same mechanism, which is one fewer thing to get wrong
/// than two.
///
/// An active attacker who substitutes their own key on the wire is not
/// addressed here and is not meant to be: what they would reach is the
/// credentials of a throwaway network with no internet on it. The file itself
/// is behind a TLS certificate pinned to a fingerprint that travels in the
/// same sealed frames, and a bearer token they do not have.
class LinkSecret {
  /// One side's ephemeral key pair, alive for the length of one negotiation.
  final SimpleKeyPair _keyPair;

  /// This side's public half, base64url, as it goes on the wire.
  final String publicKey;

  const LinkSecret._(this._keyPair, this.publicKey);

  static final _exchange = X25519();
  static final _cipher = Chacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Domain separation, so a secret derived here can never coincide with one
  /// derived for the answer envelope or for a session code.
  static const _keyInfo = 'directdrop-link-credentials-v1';

  static const int _nonceLength = 12;
  static const int _macLength = 16;

  /// A fresh key pair for one negotiation. Never reused: the pair is as
  /// short-lived as the network it protects.
  static Future<LinkSecret> generate() async {
    final pair = await _exchange.newKeyPair();
    final public = await pair.extractPublicKey();
    return LinkSecret._(pair, base64Url.encode(public.bytes));
  }

  /// Seals [credentials] for the holder of [peerPublicKey].
  ///
  /// [sessionId] is bound in as associated data, so credentials captured from
  /// one session do not authenticate in another even if the same pair of
  /// devices negotiates again.
  Future<String> seal({
    required String ssid,
    required String passphrase,
    required String sessionId,
    required String peerPublicKey,
  }) async {
    final key = await _sharedKey(peerPublicKey);
    final nonce = _cipher.newNonce();
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode({'ssid': ssid, 'passphrase': passphrase})),
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(sessionId),
    );
    return base64Url.encode(
        Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]));
  }

  /// Opens what [seal] produced, or returns null.
  ///
  /// Null rather than throwing: everything that reaches here came off a radio
  /// that anything can write to, so a frame that will not open is an ordinary
  /// event — a stale offer, a neighbouring session, somebody probing — and
  /// the negotiation's own ladder is what handles it.
  Future<({String ssid, String passphrase})?> open({
    required String sealed,
    required String sessionId,
    required String peerPublicKey,
  }) async {
    try {
      final bytes = base64Url.decode(sealed);
      if (bytes.length <= _nonceLength + _macLength) return null;

      final clear = await _cipher.decrypt(
        SecretBox(
          bytes.sublist(_nonceLength, bytes.length - _macLength),
          nonce: bytes.sublist(0, _nonceLength),
          mac: Mac(bytes.sublist(bytes.length - _macLength)),
        ),
        secretKey: await _sharedKey(peerPublicKey),
        aad: utf8.encode(sessionId),
      );

      final json = jsonDecode(utf8.decode(clear));
      if (json is! Map) return null;
      final ssid = json['ssid'];
      final passphrase = json['passphrase'];
      // The 802.11 limits, checked here rather than handed to the Wi-Fi stack
      // to fail less legibly: an SSID is at most 32 bytes and a WPA
      // passphrase 8 to 63 characters.
      if (ssid is! String || ssid.isEmpty || utf8.encode(ssid).length > 32) {
        return null;
      }
      if (passphrase is! String ||
          passphrase.length < 8 ||
          passphrase.length > 63) {
        return null;
      }
      return (ssid: ssid, passphrase: passphrase);
    } catch (_) {
      // Malformed base64, a wrong key, a tampered or truncated frame. All of
      // them mean the same thing here: this is not credentials for us.
      return null;
    }
  }

  Future<SecretKey> _sharedKey(String peerPublicKey) async {
    final shared = await _exchange.sharedSecretKey(
      keyPair: _keyPair,
      remotePublicKey: SimplePublicKey(
        base64Url.decode(peerPublicKey),
        type: KeyPairType.x25519,
      ),
    );
    // The raw X25519 output is not a key: HKDF is what turns it into one, and
    // the info string is what stops it colliding with any other secret this
    // app derives.
    return SecretKey(await _hkdf
        .deriveKey(
          secretKey: shared,
          nonce: utf8.encode(_keyInfo),
          info: utf8.encode(_keyInfo),
        )
        .then((k) => k.extractBytes()));
  }
}

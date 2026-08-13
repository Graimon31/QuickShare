import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The SDP answer travels through a public broker we do not run, so it goes
/// out sealed. The broker sees ciphertext of a fixed shape and nothing else —
/// not the ICE credentials, not the candidate addresses, not the fingerprint.
///
/// The key never crosses the network: both sides derive it from a random seed
/// that only ever exists on the desktop screen and in the phone's camera.
class SealedEnvelope {
  const SealedEnvelope._();

  /// 128 bits is plenty against an attacker who must also have photographed
  /// the QR code, and it keeps the code sparse.
  static const int seedLengthBytes = 16;

  static const int _nonceLength = 12;
  static const _keyInfo = 'quickshare-answer-key-v1';
  static const _topicInfo = 'quickshare-answer-topic-v1';

  static final _cipher = Chacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _random = Random.secure();

  static Uint8List newSeed() {
    final seed = Uint8List(seedLengthBytes);
    for (var i = 0; i < seed.length; i++) {
      seed[i] = _random.nextInt(256);
    }
    return seed;
  }

  /// The channel name is derived from the same seed but under a different
  /// info string, so knowing where to listen never leaks the ability to read.
  static Future<String> deriveTopic(Uint8List seed) async {
    final bytes = await _derive(seed, _topicInfo);
    return base64Url.encode(bytes.sublist(0, 16)).replaceAll('=', '');
  }

  /// Wraps [plaintext] as nonce ‖ ciphertext ‖ MAC.
  ///
  /// [offerFingerprint] is bound in as associated data: an answer sealed for
  /// one offer will not authenticate against another, which kills replay of a
  /// captured answer into a later session.
  static Future<Uint8List> seal({
    required Uint8List plaintext,
    required Uint8List seed,
    required Uint8List offerFingerprint,
  }) async {
    final key = SecretKey(await _derive(seed, _keyInfo));
    final nonce = List<int>.generate(_nonceLength, (_) => _random.nextInt(256));

    final box = await _cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: offerFingerprint,
    );

    return Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Throws [FormatException] if the payload is malformed and
  /// [SecretBoxAuthenticationError] if it was tampered with, truncated, or
  /// sealed for a different offer.
  static Future<Uint8List> open({
    required Uint8List envelope,
    required Uint8List seed,
    required Uint8List offerFingerprint,
  }) async {
    const macLength = 16;
    if (envelope.length <= _nonceLength + macLength) {
      throw FormatException(
          'envelope is ${envelope.length} bytes, too short to hold a nonce, '
          'a payload and a MAC');
    }

    final key = SecretKey(await _derive(seed, _keyInfo));
    final box = SecretBox(
      envelope.sublist(_nonceLength, envelope.length - macLength),
      nonce: envelope.sublist(0, _nonceLength),
      mac: Mac(envelope.sublist(envelope.length - macLength)),
    );

    final clear = await _cipher.decrypt(
      box,
      secretKey: key,
      aad: offerFingerprint,
    );
    return Uint8List.fromList(clear);
  }

  static Future<List<int>> _derive(Uint8List seed, String info) async {
    final key = await _hkdf.deriveKey(
      secretKey: SecretKey(seed),
      nonce: seed, // salt; the seed is single-use, so it doubles as one
      info: utf8.encode(info),
    );
    return key.extractBytes();
  }
}

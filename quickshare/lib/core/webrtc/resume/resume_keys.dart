import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:quickshare/core/crypto/hkdf.dart';

/// Which of the two messages of a reconnection a sealed envelope is. Bound
/// into the associated data, so one cannot be passed off as the other.
enum ResumeKind { offer, answer }

/// What a reconnection message says, once it has been opened.
class ResumeOpened {
  const ResumeOpened({required this.generation, required this.plaintext});

  /// Which link this message is about. The link the QR code started is 1.
  final int generation;
  final Uint8List plaintext;
}

/// The keys and topics the two ends of one transfer use to find each other
/// again after the connection between them has died.
///
/// ## Where the secret comes from
///
/// Nothing new is agreed on the public network. A transfer already has a
/// shared secret, the 16-byte seed that rode in the QR code (to a receiver
/// that scanned it) or in the offer a receiver was handed after it proved the
/// ten-digit code (SPAKE2, sealed). Only the two devices hold it, and it is the
/// same secret the first answer was sealed under. This class derives *different*
/// keys from it, so that nothing sealed for the first connection can be
/// replayed into a reconnection or the other way round:
///
///     okm = HKDF-SHA256(ikm = seed, salt = SHA-256(first offer),
///                       info = "directdrop-resume-v1/keys", length = 64)
///     aead key = okm[0..32), offer topic = okm[32..48), answer topic = okm[48..64)
///
/// The salt is the digest of the offer the transfer began with, so the keys
/// belong to this transfer and no other, even if a seed were ever reused.
///
/// ## What is on the public network
///
/// A sealed message is `generation (4, big-endian) ‖ nonce (12) ‖ ciphertext ‖
/// tag (16)`. The generation is in the clear so that a stale message can be
/// thrown away before any cryptography, and it is also part of the associated
/// data, so changing it fails authentication. The associated data is
///
///     "directdrop-resume-v1/<kind>/" ‖ generation ‖ SHA-256(first offer)
///
/// which binds a message to its kind (an offer cannot be played back as an
/// answer), to its link (generation 3 does not open as generation 2) and to
/// the transfer. Whoever runs a relay sees that two parties exchange small
/// messages on two unlinkable topics, and nothing else.
class ResumeKeys {
  ResumeKeys._(
      this._aeadKey, this.offerTopic, this.answerTopic, this._fingerprint);

  /// 16-byte seed, as in the QR code.
  static const int seedLength = 16;
  static const int _nonceLength = 12;
  static const int _macLength = 16;
  static const int _headerLength = 4;

  /// An honest message is a compact SDP, a few hundred bytes. The Worker's room
  /// holds 8 KiB; this stays under it.
  static const int maxEnvelopeBytes = 6144;

  static const String _domain = 'directdrop-resume-v1';
  static final _cipher = Chacha20.poly1305Aead();

  final Uint8List _aeadKey;

  /// Where the sender publishes its offers and the receiver listens.
  final String offerTopic;

  /// Where the receiver publishes its answers and the sender listens.
  final String answerTopic;

  final Uint8List _fingerprint;

  factory ResumeKeys.derive({
    required List<int> seed,
    required List<int> offerFingerprint,
  }) {
    if (seed.length != seedLength) {
      throw ArgumentError.value(
          seed.length, 'seed', 'the session seed is $seedLength bytes');
    }
    if (offerFingerprint.length != 32) {
      throw ArgumentError.value(offerFingerprint.length, 'offerFingerprint',
          'the offer fingerprint is a SHA-256 digest');
    }
    final okm = hkdfSha256(
      seed,
      salt: offerFingerprint,
      info: utf8.encode('$_domain/keys'),
      length: 64,
    );
    String topic(List<int> bytes) =>
        base64Url.encode(bytes).replaceAll('=', '');
    return ResumeKeys._(
      Uint8List.fromList(okm.sublist(0, 32)),
      topic(okm.sublist(32, 48)),
      topic(okm.sublist(48, 64)),
      Uint8List.fromList(offerFingerprint),
    );
  }

  List<int> _aad(ResumeKind kind, int generation) => [
        ...utf8.encode('$_domain/${kind.name}/'),
        ..._generationBytes(generation),
        ..._fingerprint,
      ];

  static Uint8List _generationBytes(int generation) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, generation, Endian.big);

  /// The generation a message claims, without opening it; null for something
  /// too short or too long to be one. Used to drop a stale message cheaply.
  static int? peekGeneration(Uint8List envelope) {
    if (envelope.length < _headerLength + _nonceLength + _macLength + 1 ||
        envelope.length > maxEnvelopeBytes) {
      return null;
    }
    return ByteData.sublistView(envelope).getUint32(0, Endian.big);
  }

  Future<Uint8List> seal({
    required ResumeKind kind,
    required int generation,
    required List<int> plaintext,
    Random? random,
  }) async {
    if (generation < 1 || generation > 0xffffffff) {
      throw ArgumentError.value(generation, 'generation', 'out of range');
    }
    final source = random ?? Random.secure();
    final nonce =
        List<int>.generate(_nonceLength, (_) => source.nextInt(256));
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: SecretKey(_aeadKey),
      nonce: nonce,
      aad: _aad(kind, generation),
    );
    return Uint8List.fromList([
      ..._generationBytes(generation),
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// The message in [envelope], or null when it is the wrong size, was sealed
  /// under another key, for another transfer, as the other kind of message, or
  /// was altered. Never throws: what arrives on a public topic is not the
  /// caller's to trust, and a stranger's message is not an error.
  Future<ResumeOpened?> open({
    required ResumeKind kind,
    required Uint8List envelope,
  }) async {
    final generation = peekGeneration(envelope);
    if (generation == null || generation < 1) return null;
    try {
      final clear = await _cipher.decrypt(
        SecretBox(
          envelope.sublist(
              _headerLength + _nonceLength, envelope.length - _macLength),
          nonce: envelope.sublist(_headerLength, _headerLength + _nonceLength),
          mac: Mac(envelope.sublist(envelope.length - _macLength)),
        ),
        secretKey: SecretKey(_aeadKey),
        aad: _aad(kind, generation),
      );
      return ResumeOpened(
          generation: generation, plaintext: Uint8List.fromList(clear));
    } catch (_) {
      return null;
    }
  }
}

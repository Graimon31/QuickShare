import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:quickshare/core/crypto/hkdf.dart';
import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/session_code.dart';

/// What the receiver's SPAKE2 run with a sender is, in DirectDrop's terms.
///
/// The password is the ten-digit code. A is the receiver, B is the sender, and
/// B's identity is the fingerprint of the TLS certificate the receiver is
/// actually talking to. That last binding is what ties the proof to the
/// connection: a device in the middle that terminates TLS with a certificate
/// of its own has a different B from the real sender's, so the two ends derive
/// unrelated keys and the sender's confirmation never verifies — even though
/// the middle device relays every byte faithfully.
///
/// Every step that does curve arithmetic runs on its own isolate. One scalar
/// multiplication is about five milliseconds on a desktop and a run does four
/// per side, which is a dropped frame on the UI isolate and several on a
/// phone.
class CodePake {
  const CodePake._();

  /// The sender's endpoint for the first round.
  static const String startPath = '/v2/pake/start';

  /// A, the receiver's side of every run. A label rather than a name: the
  /// receiver has no identity the sender could check, and does not need one —
  /// what it proves is that it knows the code.
  static const String receiverIdentity = 'directdrop/receiver';

  /// Bound into the confirmation keys, so a run of this protocol cannot be
  /// replayed into another that happens to use SPAKE2 with the same code.
  static const String _aad = 'directdrop/v2/code-pake';
  static const String _passwordInfo = 'directdrop/v2/code-pake/password';

  /// Length of a confirmation, in bytes.
  static const int tagLength = 32;

  /// The code as a scalar: HKDF-SHA256 to 64 bytes, then reduced modulo the
  /// group order. Sixty-four bytes is 256 bits more than the order needs, so
  /// the reduction is unbiased.
  ///
  /// No memory-hard function. The attacker the exchange is built against
  /// never sees anything to run one against; what limits the guesses it gets
  /// is the sender's rate limiter, not the cost of a guess.
  static BigInt passwordScalar(SessionCode code) {
    final okm = hkdfSha256(
      utf8.encode(code.code),
      info: utf8.encode(_passwordInfo),
      length: 64,
    );
    var v = BigInt.zero;
    for (final byte in okm) {
      v = (v << 8) | BigInt.from(byte);
    }
    return v % Spake2.order;
  }

  /// The receiver's first step: its scalar and its share, `pA`.
  static Future<Spake2> begin(SessionCode code) => Isolate.run(
      () => Spake2.start(role: Spake2Role.a, w: passwordScalar(code)));

  /// The receiver's second step, with the sender's share and the fingerprint
  /// of the certificate it was actually served — not one it was told about.
  ///
  /// Throws if the share is not a point of the group.
  static Future<Spake2Keys> complete(
    Spake2 begun, {
    required List<int> senderShare,
    required String certFingerprint,
  }) =>
      Isolate.run(() => begun.finish(
            senderShare,
            identityA: utf8.encode(receiverIdentity),
            identityB: utf8.encode(certFingerprint),
            aad: utf8.encode(_aad),
          ));

  /// The sender's whole run: it has the receiver's share in hand already, so
  /// there is nothing to hold between the steps. [certFingerprint] is the
  /// fingerprint of its own certificate.
  ///
  /// Throws if the share is not a point of the group.
  static Future<PakeReply> respond(
    SessionCode code, {
    required List<int> receiverShare,
    required String certFingerprint,
  }) =>
      Isolate.run(() {
        final b = Spake2.start(role: Spake2Role.b, w: passwordScalar(code));
        final keys = b.finish(
          receiverShare,
          identityA: utf8.encode(receiverIdentity),
          identityB: utf8.encode(certFingerprint),
          aad: utf8.encode(_aad),
        );
        return PakeReply(b.share, keys);
      });

  /// Unpadded base64url, as the rest of the protocol writes fingerprints.
  static String encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  /// The bytes of [value], or null if it is not exactly [length] bytes in the
  /// one canonical spelling [encode] produces. Strict because a value with
  /// two spellings is a value two parties can disagree about.
  static Uint8List? decode(Object? value, {required int length}) {
    if (value is! String || value.length > 4 * length) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(value));
      if (bytes.length != length || encode(bytes) != value) return null;
      return Uint8List.fromList(bytes);
    } on FormatException {
      return null;
    }
  }
}

/// The sender's answer to a receiver's first round.
class PakeReply {
  /// `pB`.
  final Uint8List share;

  /// The keys the sender derived: `cA` is what it expects back, `cB` is what
  /// it sends now.
  final Spake2Keys keys;

  const PakeReply(this.share, this.keys);
}

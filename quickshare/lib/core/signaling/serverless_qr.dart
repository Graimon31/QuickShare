import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';

/// Everything the phone needs to answer, and nothing else.
///
/// The old serverless code carried a full zlib-compressed SDP plus an address
/// the phone was supposed to POST back to — around 1460 characters, dense
/// enough that the phone had to be held against the screen, and pointing at a
/// port no inbound packet could ever reach. This carries a 16-byte seed and a
/// binary offer instead: the seed names the drop point and unlocks it, the
/// offer is rebuilt from a template on the far side.
class ServerlessQr {
  /// Marks the payload as this format so the scanner can tell it apart from
  /// the JSON QR codes used by the LAN and Bluetooth transports.
  static const String prefix = 'QS1';

  final Uint8List seed;
  final CompactSdp offer;

  const ServerlessQr({required this.seed, required this.offer});

  static bool looksLikeOne(String raw) => raw.trim().startsWith(prefix);

  String encode() {
    final offerBytes = offer.toBytes();
    final body = Uint8List(seed.length + offerBytes.length)
      ..setRange(0, seed.length, seed)
      ..setRange(seed.length, seed.length + offerBytes.length, offerBytes);
    return prefix + base64Url.encode(body).replaceAll('=', '');
  }

  static ServerlessQr decode(String raw) {
    final trimmed = raw.trim();
    if (!looksLikeOne(trimmed)) {
      throw const FormatException('not a serverless DirectDrop QR code');
    }
    final body = base64Url.decode(
      base64Url.normalize(trimmed.substring(prefix.length)),
    );
    if (body.length <= SealedEnvelope.seedLengthBytes) {
      throw const FormatException('serverless QR payload is truncated');
    }
    return ServerlessQr(
      seed: Uint8List.fromList(body.sublist(0, SealedEnvelope.seedLengthBytes)),
      offer: CompactSdp.fromBytes(
        Uint8List.fromList(body.sublist(SealedEnvelope.seedLengthBytes)),
      ),
    );
  }

  /// Bound into the sealed answer as associated data. An answer produced for
  /// one offer cannot be replayed against a later one, because the far side
  /// authenticates against this exact digest.
  Uint8List get offerFingerprint =>
      Uint8List.fromList(sha256.convert(offer.toBytes()).bytes);

  /// Where the answer will be dropped. Derived from the seed, so it never
  /// travels anywhere except across the camera.
  Future<String> get topic => SealedEnvelope.deriveTopic(seed);

  /// Only candidates a peer on another network can act on are worth the QR
  /// space. Host candidates are kept — two devices on one Wi-Fi still connect
  /// directly through them — but capped, since a laptop with several
  /// interfaces can otherwise produce a dozen useless ones.
  static CompactSdp trimForQr(CompactSdp full, {int maxHostCandidates = 2}) {
    final routable = full.candidates
        .where((c) => c.type == 'srflx' || c.type == 'relay')
        .toList();
    final host = full.candidates
        .where((c) => c.type == 'host')
        .take(maxHostCandidates)
        .toList();
    return CompactSdp(
      iceUfrag: full.iceUfrag,
      icePwd: full.icePwd,
      fingerprint: full.fingerprint,
      setup: full.setup,
      candidates: [...routable, ...host],
    );
  }
}

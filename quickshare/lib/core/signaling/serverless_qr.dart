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
  ///
  /// `QS1` is seed + offer only. `QS2` prepends name/size/count so the
  /// receiver can show what is coming before the DataChannel opens — a
  /// camera scan never sees the `n`/`s`/`c` query params on the share link.
  static const String prefix = 'QS1';
  static const String prefixWithPreview = 'QS2';
  static const int _maxNameBytes = 80;

  final Uint8List seed;
  final CompactSdp offer;
  final String fileName;
  final int fileSize;
  final int itemCount;

  const ServerlessQr({
    required this.seed,
    required this.offer,
    this.fileName = '',
    this.fileSize = 0,
    this.itemCount = 0,
  });

  bool get hasPreview =>
      fileSize > 0 || itemCount > 0 || fileName.isNotEmpty;

  static bool looksLikeOne(String raw) {
    final t = raw.trim();
    return t.startsWith(prefixWithPreview) || t.startsWith(prefix);
  }

  String encode() {
    final offerBytes = offer.toBytes();
    final nameBytes = utf8.encode(_clipName(fileName));
    final withPreview = hasPreview;
    final previewBytes = withPreview ? 4 + 8 + 1 + nameBytes.length : 0;
    final body = Uint8List(seed.length + previewBytes + offerBytes.length);
    var o = 0;
    body.setRange(o, o + seed.length, seed);
    o += seed.length;
    if (withPreview) {
      final view = ByteData.sublistView(body);
      view.setUint32(o, itemCount, Endian.big);
      o += 4;
      view.setUint64(o, fileSize, Endian.big);
      o += 8;
      body[o] = nameBytes.length;
      o += 1;
      body.setRange(o, o + nameBytes.length, nameBytes);
      o += nameBytes.length;
    }
    body.setRange(o, o + offerBytes.length, offerBytes);
    final tag = withPreview ? prefixWithPreview : prefix;
    return tag + base64Url.encode(body).replaceAll('=', '');
  }

  static ServerlessQr decode(String raw) {
    final trimmed = raw.trim();
    if (!looksLikeOne(trimmed)) {
      throw const FormatException('not a serverless DirectDrop QR code');
    }
    final withPreview = trimmed.startsWith(prefixWithPreview);
    final tag = withPreview ? prefixWithPreview : prefix;
    final body = base64Url.decode(
      base64Url.normalize(trimmed.substring(tag.length)),
    );
    if (body.length <= SealedEnvelope.seedLengthBytes) {
      throw const FormatException('serverless QR payload is truncated');
    }
    var o = SealedEnvelope.seedLengthBytes;
    var fileName = '';
    var fileSize = 0;
    var itemCount = 0;
    if (withPreview) {
      if (body.length < o + 13) {
        throw const FormatException('serverless QR preview is truncated');
      }
      final view = ByteData.sublistView(body);
      itemCount = view.getUint32(o, Endian.big);
      o += 4;
      fileSize = view.getUint64(o, Endian.big);
      o += 8;
      final nameLen = body[o];
      o += 1;
      if (body.length < o + nameLen) {
        throw const FormatException('serverless QR name is truncated');
      }
      fileName = utf8.decode(body.sublist(o, o + nameLen));
      o += nameLen;
    }
    return ServerlessQr(
      seed: Uint8List.fromList(body.sublist(0, SealedEnvelope.seedLengthBytes)),
      offer: CompactSdp.fromBytes(Uint8List.fromList(body.sublist(o))),
      fileName: fileName,
      fileSize: fileSize,
      itemCount: itemCount,
    );
  }

  static String _clipName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '';
    final bytes = utf8.encode(trimmed);
    if (bytes.length <= _maxNameBytes) return trimmed;
    return utf8.decode(bytes.sublist(0, _maxNameBytes), allowMalformed: true);
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

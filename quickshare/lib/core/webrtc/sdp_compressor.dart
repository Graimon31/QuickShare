import 'dart:convert';
import 'dart:io';

/// Utility to compress WebRTC SDP text into compact base64Url strings
/// suitable for QR code embedding, and decompress back to full SDP format.
class SdpCompressor {
  const SdpCompressor._();

  /// Compresses raw [sdp] string into a compact, URL-safe base64 string.
  static String compress(String sdp) {
    if (sdp.isEmpty) return '';
    try {
      final bytes = utf8.encode(sdp);
      final compressed = zlib.encode(bytes);
      return base64Url.encode(compressed).replaceAll('=', '');
    } catch (_) {
      return base64Url.encode(utf8.encode(sdp)).replaceAll('=', '');
    }
  }

  /// Enforces the CRLF (\r\n) line endings required by the native LibWebRTC
  /// C++ parser (RFC 8866). Unix \n endings make iOS reject the description
  /// with "SessionDescription is NULL".
  static String normalizeLineEndings(String sdp) {
    if (sdp.isEmpty) return '';
    var out = sdp.replaceAll(RegExp(r'\r?\n'), '\r\n');
    if (!out.endsWith('\r\n')) out += '\r\n';
    return out;
  }

  /// Drops ICE candidates a peer on another network can never use, so the
  /// offer still fits inside a QR code. Only `a=candidate:` lines are touched
  /// — m= sections and BUNDLE groups are left intact, which is what the old
  /// regex filter got wrong.
  static String pruneCandidatesForQr(String sdp) {
    if (sdp.isEmpty) return '';
    final kept = <String>[];
    for (final line in normalizeLineEndings(sdp).split('\r\n')) {
      if (!line.startsWith('a=candidate:') || _isRemotelyRoutable(line)) {
        kept.add(line);
      }
    }
    return normalizeLineEndings(kept.join('\r\n'));
  }

  /// a=candidate:<foundation> <component> <transport> <priority> <ip> <port> typ <type> ...
  static bool _isRemotelyRoutable(String candidateLine) {
    final parts = candidateLine.split(' ');
    if (parts.length < 8) return false;
    final address = parts[4];
    final type = parts[7];
    if (type == 'host') return false; // LAN-only, unreachable over LTE
    if (address.contains(':')) return false; // IPv6
    if (address.endsWith('.local')) return false; // mDNS, unresolvable remotely
    if (address.startsWith('169.254.')) return false; // link-local
    return true;
  }

  /// Decompresses a URL-safe base64 string back into the original raw SDP string
  /// with strict CRLF (\r\n) line endings required by native LibWebRTC C++ parser.
  static String decompress(String compressedSdp) {
    if (compressedSdp.isEmpty) return '';
    // Current QR format compresses the whole payload once, so `sdp` arrives as
    // plain text — it needs line-ending normalization but no base64/zlib pass.
    if (compressedSdp.trimLeft().startsWith('v=0')) {
      return normalizeLineEndings(compressedSdp);
    }
    try {
      var normalized = compressedSdp.trim();
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      final bytes = base64Url.decode(normalized);
      String sdp;
      try {
        final decompressedBytes = zlib.decode(bytes);
        sdp = utf8.decode(decompressedBytes);
      } catch (_) {
        sdp = utf8.decode(bytes);
      }
      return normalizeLineEndings(sdp);
    } catch (e) {
      return compressedSdp;
    }
  }
}

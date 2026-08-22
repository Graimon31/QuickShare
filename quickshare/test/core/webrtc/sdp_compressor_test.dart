import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/webrtc/sdp_compressor.dart';

void main() {
  group('SdpCompressor', () {
    const sampleSdp = '''v=0
o=- 432454656 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
a=msid-semantic: WMS
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=candidate:1 1 UDP 2122260223 192.168.1.45 54321 typ host
a=candidate:2 1 UDP 1686052863 203.0.113.5 54321 typ srflx raddr 192.168.1.45 rport 54321
a=setup:actpass
a=mid:0
a=sctp-port:5000''';

    test('compresses SDP to a compact string and decompresses back correctly', () {
      final compressed = SdpCompressor.compress(sampleSdp);
      expect(compressed.length, lessThan(sampleSdp.length));

      final decompressed = SdpCompressor.decompress(compressed);
      final expectedCrlf = '${sampleSdp.replaceAll(RegExp(r'\r?\n'), '\r\n')}\r\n';
      expect(decompressed, equals(expectedCrlf));
    });

    test('handles empty strings gracefully', () {
      expect(SdpCompressor.compress(''), isEmpty);
      expect(SdpCompressor.decompress(''), isEmpty);
    });
  });
}

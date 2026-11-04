import 'dart:math';
import 'dart:typed_data';

import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';

/// A real offer, as the sender's QR holds it, for tests that go on to decode
/// it: `QS2` + seed + a compact SDP, with a name, a size and a count.
///
/// [tag] makes two calls differ, so a test can tell one offer from another.
String sampleOffer({int tag = 0, String name = 'holiday.zip'}) {
  final sdp = [
    'v=0',
    'o=- 4611731400430051336 2 IN IP4 127.0.0.1',
    's=-',
    't=0 0',
    'a=group:BUNDLE 0',
    'm=application 9 UDP/DTLS/SCTP webrtc-datachannel',
    'c=IN IP4 0.0.0.0',
    'a=ice-ufrag:F7g${tag % 10}',
    'a=ice-pwd:x9cO/TDwjM9zPCTFEJUUS9nJ',
    'a=fingerprint:sha-256 8F:BF:9A:F5:5A:AE:1C:2C:1D:BE:1E:1A:33:6C:A1:9B:'
        '11:B2:CE:1B:4A:36:1E:4B:1B:6A:1C:F1:0E:2B:3A:5C',
    'a=setup:actpass',
    'a=mid:0',
    'a=sctp-port:5000',
    'a=candidate:0 1 udp 2122260223 192.168.3.1 40000 typ host generation 0',
    '',
  ].join('\r\n');
  final random = Random(1000 + tag);
  return ServerlessQr(
    seed: Uint8List.fromList(
        List<int>.generate(SealedEnvelope.seedLengthBytes, (_) => random.nextInt(256))),
    offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(sdp)),
    fileName: name,
    fileSize: 12345,
    itemCount: 1,
  ).encode();
}

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';

void main() {
  String offerWith(int hostCount, int srflxCount, int relayCount) {
    final b = StringBuffer('''v=0
o=- 4611731400430051336 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=ice-ufrag:F7gI
a=ice-pwd:x9cO/TDwjM9zPCTFEJUUS9nJ
a=fingerprint:sha-256 8F:BF:9A:F5:5A:AE:1C:2C:1D:BE:1E:1A:33:6C:A1:9B:11:B2:CE:1B:4A:36:1E:4B:1B:6A:1C:F1:0E:2B:3A:5C
a=setup:actpass
a=mid:0
a=sctp-port:5000
''');
    var n = 0;
    void add(String type, int count) {
      for (var i = 0; i < count; i++, n++) {
        b.writeln('a=candidate:$n 1 udp 2122260223 192.168.3.${n + 1} '
            '${40000 + n} typ $type generation 0');
      }
    }

    add('host', hostCount);
    add('srflx', srflxCount);
    add('relay', relayCount);
    return b.toString();
  }

  group('ServerlessQr', () {
    test('round trips seed and offer through the QR string', () {
      final seed = SealedEnvelope.newSeed();
      final qr = ServerlessQr(
        seed: seed,
        offer: CompactSdp.fromSdp(offerWith(1, 1, 1)),
      );

      final decoded = ServerlessQr.decode(qr.encode());

      expect(decoded.seed, seed);
      expect(decoded.offer.iceUfrag, 'F7gI');
      expect(decoded.offer.icePwd, 'x9cO/TDwjM9zPCTFEJUUS9nJ');
      expect(decoded.offer.fingerprint, qr.offer.fingerprint);
      expect(decoded.offer.candidates.length, 3);
    });

    test('stays sparse enough to scan from a distance', () {
      final trimmed = ServerlessQr.trimForQr(
        CompactSdp.fromSdp(offerWith(8, 2, 2)),
      );
      final encoded = ServerlessQr(
        seed: SealedEnvelope.newSeed(),
        offer: trimmed,
      ).encode();

      // The format this replaces produced 1460 characters — roughly 150
      // modules per side, which is why the phone had to touch the screen.
      expect(encoded.length, lessThan(220),
          reason: 'QR payload is ${encoded.length} characters');
    });

    test('trimming keeps every routable candidate and caps host ones', () {
      final trimmed = ServerlessQr.trimForQr(
        CompactSdp.fromSdp(offerWith(8, 3, 2)),
      );

      expect(trimmed.candidates.where((c) => c.type == 'srflx').length, 3);
      expect(trimmed.candidates.where((c) => c.type == 'relay').length, 2);
      expect(trimmed.candidates.where((c) => c.type == 'host').length, 2);
      // Credentials must survive trimming or the answer can never authenticate.
      expect(trimmed.iceUfrag, 'F7gI');
      expect(trimmed.fingerprint.length, 32);
    });

    test('offer fingerprint changes with the offer', () {
      final a = ServerlessQr(
          seed: SealedEnvelope.newSeed(),
          offer: CompactSdp.fromSdp(offerWith(1, 1, 0)));
      final b = ServerlessQr(
          seed: SealedEnvelope.newSeed(),
          offer: CompactSdp.fromSdp(offerWith(1, 2, 0)));

      expect(a.offerFingerprint.length, 32);
      expect(a.offerFingerprint, isNot(b.offerFingerprint));
    });

    test('topic depends only on the seed', () async {
      final seed = SealedEnvelope.newSeed();
      final a = ServerlessQr(
          seed: seed, offer: CompactSdp.fromSdp(offerWith(1, 0, 0)));
      final b = ServerlessQr(
          seed: seed, offer: CompactSdp.fromSdp(offerWith(3, 2, 1)));

      expect(await a.topic, await b.topic);
    });

    test('is distinguishable from the LAN and Bluetooth QR formats', () {
      final encoded = ServerlessQr(
        seed: SealedEnvelope.newSeed(),
        offer: CompactSdp.fromSdp(offerWith(1, 1, 0)),
      ).encode();

      expect(ServerlessQr.looksLikeOne(encoded), isTrue);
      expect(ServerlessQr.looksLikeOne('eyJ2IjoyLCJpcCI6IjE5Mi4xNjgifQ'), isFalse);
      expect(ServerlessQr.looksLikeOne('quickshare://join?room=A1B2C3'), isFalse);
    });

    test('rejects a truncated or foreign payload', () {
      expect(() => ServerlessQr.decode('QS1AAAA'),
          throwsA(isA<FormatException>()));
      expect(() => ServerlessQr.decode('not-a-quickshare-code'),
          throwsA(isA<FormatException>()));
    });
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';

void main() {
  _multiSectionGuard();
  const realOffer = '''v=0
o=- 4611731400430051336 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
a=extmap-allow-mixed
a=msid-semantic: WMS
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=ice-ufrag:F7gI
a=ice-pwd:x9cO/TDwjM9zPCTFEJUUS9nJ
a=ice-options:trickle
a=fingerprint:sha-256 8F:BF:9A:F5:5A:AE:1C:2C:1D:BE:1E:1A:33:6C:A1:9B:11:B2:CE:1B:4A:36:1E:4B:1B:6A:1C:F1:0E:2B:3A:5C
a=setup:actpass
a=mid:0
a=sctp-port:5000
a=max-message-size:262144
a=candidate:1510613869 1 udp 2122260223 192.168.3.52 54321 typ host generation 0
a=candidate:842163049 1 udp 1686052607 195.170.199.39 5044 typ srflx raddr 192.168.3.52 rport 54321 generation 0
a=candidate:3publicrelay 1 udp 41885439 172.253.62.127 30001 typ relay raddr 0.0.0.0 rport 0 generation 0
a=candidate:2001db8 1 udp 2122194687 2001:db8::1 54322 typ host generation 0
a=candidate:mdns1 1 udp 2122197247 f3a1b2c3-1111-2222-3333-444455556666.local 54323 typ host generation 0''';

  group('CompactSdp', () {
    test('extracts only the session-specific fields from a real offer', () {
      final compact = CompactSdp.fromSdp(realOffer);

      expect(compact.iceUfrag, 'F7gI');
      expect(compact.icePwd, 'x9cO/TDwjM9zPCTFEJUUS9nJ');
      expect(compact.setup, 'actpass');
      expect(compact.fingerprint.length, 32);
      expect(compact.fingerprint.first, 0x8F);
      expect(compact.fingerprint.last, 0x5C);
    });

    test('drops IPv6 and mDNS candidates it cannot pack', () {
      final compact = CompactSdp.fromSdp(realOffer);

      expect(compact.candidates.map((c) => c.type),
          containsAll(['host', 'srflx', 'relay']));
      expect(compact.candidates.length, 3);
      expect(compact.candidates.every((c) => !c.address.contains(':')), isTrue);
      expect(compact.candidates.every((c) => !c.address.endsWith('.local')),
          isTrue);
    });

    test('binary round trip preserves every field', () {
      final original = CompactSdp.fromSdp(realOffer);
      final restored = CompactSdp.fromBytes(original.toBytes());

      expect(restored.iceUfrag, original.iceUfrag);
      expect(restored.icePwd, original.icePwd);
      expect(restored.setup, original.setup);
      expect(restored.fingerprint, original.fingerprint);
      expect(restored.candidates.length, original.candidates.length);
      for (var i = 0; i < original.candidates.length; i++) {
        expect(restored.candidates[i].address, original.candidates[i].address);
        expect(restored.candidates[i].port, original.candidates[i].port);
        expect(restored.candidates[i].type, original.candidates[i].type);
      }
    });

    test('payload stays small enough for a sparse QR code', () {
      final bytes = CompactSdp.fromSdp(realOffer).toBytes();

      // Header 4 + ufrag 1+4 + pwd 1+24 + fingerprint 32 + count 1 + 3*8 = 91.
      expect(bytes.length, lessThan(150),
          reason: 'compact payload is ${bytes.length} bytes; the full offer '
              'this came from is ${realOffer.length} chars');
    });

    test('rebuilt SDP keeps the structure the native parser requires', () {
      final sdp = CompactSdp.fromBytes(
        CompactSdp.fromSdp(realOffer).toBytes(),
      ).toSdp(isOffer: true);

      // The BUNDLE group must line up with an m= section carrying mid:0 —
      // getting this wrong is what produced "BUNDLE group contains a MID='0'
      // matching no m= section" on iOS.
      expect(sdp, contains('a=group:BUNDLE 0'));
      expect(sdp, contains('m=application 9 UDP/DTLS/SCTP webrtc-datachannel'));
      expect(sdp, contains('a=mid:0'));
      expect(sdp, contains('a=ice-ufrag:F7gI'));
      expect(sdp, contains('a=ice-pwd:x9cO/TDwjM9zPCTFEJUUS9nJ'));
      expect(sdp, contains('a=sctp-port:5000'));
      expect(sdp, contains('a=candidate:'));
      expect(sdp.contains('\n'), isTrue);
      expect(sdp.split('\n').every((l) => l.isEmpty || l.endsWith('\r')), isTrue,
          reason: 'every line must terminate with CRLF for LibWebRTC on iOS');
    });

    test('fingerprint survives as the same colon-separated hex', () {
      final sdp = CompactSdp.fromSdp(realOffer).toSdp(isOffer: true);

      expect(
        sdp,
        contains('a=fingerprint:sha-256 8F:BF:9A:F5:5A:AE:1C:2C:1D:BE:1E:1A:'
            '33:6C:A1:9B:11:B2:CE:1B:4A:36:1E:4B:1B:6A:1C:F1:0E:2B:3A:5C'),
      );
    });

    test('answer flips actpass to active', () {
      final sdp = CompactSdp.fromSdp(realOffer).toSdp(isOffer: false);

      expect(sdp, contains('a=setup:active'));
    });

    test('rejects an SDP with no fingerprint', () {
      expect(
        () => CompactSdp.fromSdp('v=0\r\na=ice-ufrag:aaaa\r\na=ice-pwd:bbbb'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a truncated or foreign payload', () {
      expect(() => CompactSdp.fromBytes(Uint8List.fromList([1, 2, 3, 4])),
          throwsA(isA<FormatException>()));
      final valid = CompactSdp.fromSdp(realOffer).toBytes();
      expect(() => CompactSdp.fromBytes(valid.sublist(0, valid.length - 4)),
          throwsA(isA<FormatException>()));
    });
  });
}

void _multiSectionGuard() {
  group('media section guard', () {
    // Regression: flutter_webrtc offers audio and video by default even when
    // only a data channel exists, producing three m-sections. toSdp() rebuilds
    // one, so the answer came back with a single m-line against a three-line
    // offer and libwebrtc rejected it at setRemoteDescription — far from the
    // cause. Caught here instead.
    const credentials = 'a=ice-ufrag:Xt3k\r\n'
        'a=ice-pwd:9pQ2vLmR4sT7wZ1aB6cD8eF0\r\n'
        'a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:'
        '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00\r\n'
        'a=setup:actpass\r\n';

    test('accepts a data-channel-only offer', () {
      final compact = CompactSdp.fromSdp(
          'v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n$credentials');
      expect(compact.iceUfrag, equals('Xt3k'));
    });

    test('rejects an offer that also carries audio and video', () {
      expect(
        () => CompactSdp.fromSdp('v=0\r\n'
            'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
            'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
            'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n$credentials'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            allOf(contains('3 media sections'),
                contains('OfferToReceiveAudio')))),
      );
    });
  });
}

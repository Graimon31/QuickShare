// Guards the size of the serverless QR code, and the shape of what goes into
// it, without touching the network.
//
// This replaces an earlier test that called the sender repository's serverless
// QR builder, which in turn resolved a public IP and asked the router for a
// UPnP mapping. That made an ordinary `flutter test` run depend on the
// developer's internet connection, print their public address into the log,
// take eight seconds, and leave a port mapping behind on their router. The
// property worth protecting — that a fully gathered offer still fits in a
// scannable code — needs none of that.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';

/// A gathered offer of the shape libwebrtc actually produces: host candidates
/// on several interfaces, reflexive candidates from a STUN pool, and a relay.
String _gatheredOffer() {
  const candidates = [
    'a=candidate:1 1 udp 2122260223 192.168.3.52 51001 typ host generation 0',
    'a=candidate:2 1 udp 2122194687 10.0.0.7 51002 typ host generation 0',
    'a=candidate:3 1 udp 2122129151 172.20.10.3 51003 typ host generation 0',
    'a=candidate:4 1 udp 1686052607 195.170.199.10 34415 typ srflx generation 0',
    'a=candidate:5 1 udp 1686052606 212.34.142.83 46251 typ srflx generation 0',
    'a=candidate:6 1 udp 41885439 37.27.44.221 60001 typ relay generation 0',
    'a=candidate:7 1 udp 41885438 172.236.193.11 60002 typ relay generation 0',
  ];
  return [
    'v=0',
    'o=- 0 0 IN IP4 0.0.0.0',
    's=-',
    't=0 0',
    'a=group:BUNDLE 0',
    'm=application 9 UDP/DTLS/SCTP webrtc-datachannel',
    'c=IN IP4 0.0.0.0',
    'a=ice-ufrag:Xt3k',
    'a=ice-pwd:9pQ2vLmR4sT7wZ1aB6cD8eF0',
    'a=fingerprint:sha-256 '
        '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:'
        '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00',
    'a=setup:actpass',
    'a=mid:0',
    'a=sctp-port:5000',
    ...candidates,
  ].join('\r\n');
}

void main() {
  /// Byte mode, version 40, error correction level L. Past this the code
  /// simply cannot be produced, and the sender shows a render error instead of
  /// a transfer.
  const qrByteCapacity = 2953;

  group('serverless QR capacity', () {
    test('a fully gathered offer encodes far inside QR capacity', () {
      final qr = ServerlessQr(
        seed: SealedEnvelope.newSeed(),
        offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(_gatheredOffer())),
      );
      final encoded = qr.encode();

      expect(encoded.length, lessThan(qrByteCapacity),
          reason: 'a code larger than this cannot be rendered at all');
      // The compact form exists precisely so the code scans across a desk
      // rather than pressed against the screen; 500 chars is a generous
      // ceiling that still leaves the code sparse.
      expect(encoded.length, lessThan(500),
          reason: 'the point of CompactSdp is a sparse, scannable code');
    });

    test('trimming keeps every routable candidate and caps host ones', () {
      final full = CompactSdp.fromSdp(_gatheredOffer());
      final trimmed = ServerlessQr.trimForQr(full);

      final types = trimmed.candidates.map((c) => c.type).toList();
      expect(types.where((t) => t == 'srflx').length, equals(2),
          reason: 'reflexive candidates are how a peer reaches us');
      expect(types.where((t) => t == 'relay').length, equals(2),
          reason: 'relay candidates are the only path behind a VPN');
      expect(types.where((t) => t == 'host').length, lessThanOrEqualTo(2),
          reason: 'a laptop with several interfaces would otherwise fill the '
              'code with addresses nobody outside the room can use');
    });

    test('the round trip preserves what the far side needs to answer', () {
      final original = ServerlessQr(
        seed: SealedEnvelope.newSeed(),
        offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(_gatheredOffer())),
      );
      final decoded = ServerlessQr.decode(original.encode());

      expect(decoded.seed, equals(original.seed));
      expect(decoded.offer.iceUfrag, equals(original.offer.iceUfrag));
      expect(decoded.offer.icePwd, equals(original.offer.icePwd));
      expect(decoded.offer.fingerprint, equals(original.offer.fingerprint));
      expect(decoded.offer.candidates.length,
          equals(original.offer.candidates.length));
    });

    test('the rebuilt SDP keeps the parts libwebrtc refuses to work without',
        () {
      // The BUNDLE group, the mid and the m= line have to agree. An early
      // regex-based compressor dropped one of the three and iOS rejected the
      // description outright with "MID='0' matching no m= section".
      final sdp = ServerlessQr.trimForQr(CompactSdp.fromSdp(_gatheredOffer()))
          .toSdp(isOffer: true);

      expect(sdp, contains('a=group:BUNDLE 0'));
      expect(sdp, contains('a=mid:0'));
      expect(sdp, contains('m=application'));
      expect(sdp, contains('a=fingerprint:sha-256 '));
      // CRLF throughout: the native parser rejects Unix line endings.
      expect(sdp.contains('\r\n'), isTrue);
      expect(RegExp(r'(?<!\r)\n').hasMatch(sdp), isFalse,
          reason: 'a bare LF anywhere makes iOS reject the description');
    });

    test('a truncated scan is rejected rather than half-applied', () {
      final encoded = ServerlessQr(
        seed: SealedEnvelope.newSeed(),
        offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(_gatheredOffer())),
      ).encode();

      expect(() => ServerlessQr.decode(encoded.substring(0, 10)),
          throwsA(isA<FormatException>()));
      expect(() => ServerlessQr.decode('not a quickshare code'),
          throwsA(isA<FormatException>()));
    });

    test('the seed is fresh for every session', () {
      // A repeated seed would name the same rendezvous topic twice and let a
      // relay operator link two transfers.
      final seeds = <String>{};
      for (var i = 0; i < 32; i++) {
        seeds.add(Uint8List.fromList(SealedEnvelope.newSeed()).join(','));
      }
      expect(seeds.length, equals(32));
    });
  });
}

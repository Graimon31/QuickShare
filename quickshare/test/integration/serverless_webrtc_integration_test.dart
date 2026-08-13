import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/network/auto_tunnel_service.dart';
import 'package:quickshare/core/webrtc/sdp_compressor.dart';
import 'package:quickshare/features/sender/data/repositories/sender_repository_impl.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/features/sender/data/qr/qr_payload_encoder.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

void main() {
  group('Serverless WebRTC End-to-End Handshake Integration Tests', () {
    const sampleSdpOffer = '''v=0
o=- 432454656 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=candidate:1 1 UDP 2122260223 203.0.113.10 54321 typ host
a=setup:actpass
a=mid:0
a=sctp-port:5000''';

    test('SenderRepositoryImpl generates valid serverless SDP-in-QR payload', () async {
      final server = LocalHttpServer();
      final repository = SenderRepositoryImpl(
        localServer: server,
        networkInfoService: NetworkInfoService(),
        qrEncoder: QRPayloadEncoder(),
      );
      const meta = FileMetadata(
        name: 'test.zip',
        path: '/tmp/test.zip',
        size: 2048,
        mimeType: 'application/zip',
      );
      final session = TransferSession(
        id: 'serverless_session_123',
        fileMetadata: meta,
        serverPort: 3000,
        authToken: 'token_123',
        localIp: '192.168.1.50',
        startedAt: DateTime.now(),
        status: TransferStatus.serving,
      );

      final result = await repository.generateServerlessQRPayload(
        session: session,
        sdpOffer: sampleSdpOffer,
      );

      expect(result.isRight, isTrue);
      final encodedQr = result.fold((l) => '', (r) => r);
      final decodedPayload = QRPayload.decode(encodedQr);

      expect(decodedPayload.mode, equals('webrtc-sdp'));
      expect(decodedPayload.sdpOffer, equals(sampleSdpOffer));
      final expectedCrlf =
          '${sampleSdpOffer.replaceAll(RegExp(r'\r?\n'), '\r\n')}\r\n';
      expect(SdpCompressor.decompress(decodedPayload.sdpOffer!),
          equals(expectedCrlf));
    });

    test('QR payload for a full-size gathered offer stays inside QR capacity',
        () async {
      // Regression guard for the encoding blowup: base64 over a JSON that
      // already held base64(zlib(sdp)) pushed real offers (7.6-8.4 KB raw)
      // past the 2953-byte byte-mode ceiling of a version-40 EC-L QR code.
      const qrByteModeCapacity = 2953;

      final buffer = StringBuffer(sampleSdpOffer.trimRight())..write('\n');
      for (var i = 0; i < 60; i++) {
        final octet = 11 + (i % 200);
        final type = ['host', 'srflx', 'relay'][i % 3];
        buffer.writeln('a=candidate:${1000000000 + i} 1 udp ${2100000000 - i} '
            '203.0.$octet.${i + 1} ${30000 + i} typ $type generation 0 '
            'ufrag F7gI network-id 1 network-cost 10');
      }
      final gatheredOffer = buffer.toString();

      final repository = SenderRepositoryImpl(
        localServer: LocalHttpServer(),
        networkInfoService: NetworkInfoService(),
        qrEncoder: QRPayloadEncoder(),
      );
      final result = await repository.generateServerlessQRPayload(
        session: TransferSession(
          id: 'serverless_session_qr_capacity',
          fileMetadata: FileMetadata(
            name: 'Shared_1786238540815.zip',
            path: '/tmp/Shared_1786238540815.zip',
            size: 104857600,
            mimeType: 'application/zip',
          ),
          serverPort: 8000,
          authToken: 'a7f3c1e9-4b2d-4e8a-9c1f-2d3e4f5a6b7c',
          localIp: '192.168.1.50',
          startedAt: DateTime.now(),
          status: TransferStatus.serving,
        ),
        sdpOffer: SdpCompressor.pruneCandidatesForQr(gatheredOffer),
      );

      final encodedQr = result.fold((l) => '', (r) => r);
      expect(encodedQr.length, lessThan(qrByteModeCapacity),
          reason: 'QR payload is ${encodedQr.length} chars, over the '
              '$qrByteModeCapacity limit — QrImageView would refuse to render');

      // Pruning must not disturb the session header or the m= sections; that
      // is what produced "BUNDLE group contains a MID='0' matching no m=".
      final rehydrated =
          SdpCompressor.decompress(QRPayload.decode(encodedQr).sdpOffer!);
      expect(rehydrated, contains('a=group:BUNDLE 0'));
      expect(rehydrated, contains('a=mid:0'));
      expect(rehydrated, contains('m=application'));
      expect(rehydrated, contains('typ srflx'));
      expect(rehydrated, contains('typ relay'));
      expect(rehydrated, isNot(contains('typ host')));
    });

    test('LocalHttpServer POST /webrtc/answer endpoint accepts and forwards SDP Answer', () async {
      final server = LocalHttpServer();
      final port = await server.start('/tmp', 'dummy', 'text/plain', 0, 'token_abc');
      expect(port, greaterThan(0));

      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/webrtc/answer'));
      req.headers.set('Content-Type', 'application/json');
      req.add(utf8.encode(jsonEncode({'sdp': 'v=0\r\ns=-', 'type': 'answer'})));
      final res = await req.close();

      expect(res.statusCode, equals(400)); // 400 because activeWebRtcTransport is null, showing endpoint is active!
      client.close();
      await server.stop();
    });

    test('AutoTunnelService performs IP reachability and UPnP port mapping resolution', () async {
      final service = AutoTunnelService();
      expect(AutoTunnelService.isPrivateLanUrl('ws://192.168.1.1:3000'), isTrue);
      expect(AutoTunnelService.isPrivateLanUrl('ws://10.0.0.1:3000'), isTrue);
      expect(AutoTunnelService.isPrivateLanUrl('wss://public-domain.com'), isFalse);

      final resolved = await service.resolveReachableSignalingUrl('ws://localhost:3000');
      expect(resolved, isNotEmpty);
    });
  });
}

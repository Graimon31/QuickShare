// The room-based LAN path, end to end, against a signaling server the test
// runs itself.
//
// `startSharing()` is the older of the two transports and the only one whose
// full handshake had never run anywhere: unit tests stopped at the signaling
// client, and the serverless test exercises a different method entirely.
//
//     flutter test integration_test/lan_webrtc_e2e_test.dart -d macos
//
// The signaling server is forty lines of Dart below rather than the Node
// process in `signaling_server/`. Spawning that one needs `node` on PATH and a
// path to the script — and `Directory.current` inside a running macOS app is
// the bundle, not the repository, so the first version of this test silently
// skipped itself. A server the test owns has no such failure mode and none of
// the port collisions either.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

/// The room protocol `WebRtcSignalingClient` speaks, in the smallest form that
/// satisfies it: create a room, join it, relay everything else to the peer.
class _SignalingServer {
  final HttpServer _http;
  final _rooms = <String, List<WebSocket>>{};

  _SignalingServer._(this._http);

  static Future<_SignalingServer> start() async {
    // Port 0 lets the OS pick a free one, so two runs never collide.
    final http = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final server = _SignalingServer._(http);
    unawaited(server._accept());
    return server;
  }

  int get port => _http.port;

  Future<void> _accept() async {
    await for (final request in _http) {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        continue;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      unawaited(_serve(socket));
    }
  }

  Future<void> _serve(WebSocket socket) async {
    String? room;
    await for (final raw in socket) {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (message['type']) {
        case 'create-room':
          room = (Random().nextInt(0xFFFFFF))
              .toRadixString(16)
              .toUpperCase()
              .padLeft(6, '0');
          _rooms[room] = [socket];
          socket.add(jsonEncode({'type': 'room-created', 'roomCode': room}));
        case 'join-room':
          room = message['roomCode'] as String;
          final peers = _rooms[room];
          if (peers == null) {
            socket.add(jsonEncode(
                {'type': 'error', 'message': 'Room not found'}));
            continue;
          }
          peers.add(socket);
          socket.add(jsonEncode({'type': 'room-joined', 'roomCode': room}));
          peers.first.add(jsonEncode({'type': 'receiver-joined'}));
        default:
          // offer / answer / ice-candidate go to whoever else is in the room.
          for (final peer in _rooms[room] ?? const <WebSocket>[]) {
            if (!identical(peer, socket)) peer.add(raw);
          }
      }
    }
  }

  Future<void> close() async {
    for (final peers in _rooms.values) {
      for (final socket in peers) {
        await socket.close();
      }
    }
    await _http.close(force: true);
  }
}

/// The receiver refuses a loopback signaling URL on purpose — a phone cannot
/// reach the sender's 127.0.0.1, and the guard exists so that misconfiguration
/// fails loudly instead of timing out. The test therefore has to dial the
/// machine's own LAN address, which is also closer to what actually happens.
Future<String?> _lanAddress() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLinkLocal) return address.address;
    }
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  _SignalingServer? server;
  String? host;

  setUpAll(() async {
    host = await _lanAddress();
    server = await _SignalingServer.start();
  });

  tearDownAll(() async => server?.close());

  setUp(() => workspace = Directory.systemTemp.createTempSync('dd_lan_'));
  tearDown(() => workspace.deleteSync(recursive: true));

  testWidgets('a file crosses the room-based path and lands intact',
      (tester) async {
    if (host == null) {
      markTestSkipped('no non-loopback IPv4 interface to dial');
      return;
    }

    const sizeBytes = 256 * 1024;
    final random = Random(20260817);
    final data =
        Uint8List.fromList(List<int>.generate(sizeBytes, (_) => random.nextInt(256)));
    final source = File(p.join(workspace.path, 'lan-payload.bin'))
      ..writeAsBytesSync(data);
    final expected = sha256.convert(data).toString();

    final destination = Directory(p.join(workspace.path, 'incoming'))
      ..createSync();

    final signalingUrl = 'ws://$host:${server!.port}';
    final sender = WebRtcTransferTransport(signalingUrlOverride: signalingUrl);
    final receiver = WebRtcReceiverTransport();
    addTearDown(sender.stopSharing);

    // Prove the socket is reachable before blaming WebRTC for anything.
    final probe = await WebSocket.connect(signalingUrl)
        .timeout(const Duration(seconds: 5));
    await probe.close();

    // The sender dials the same URL it will hand to the peer; on a desktop
    // both are the machine's LAN address.
    await sender.initialize();
    final shareLink = await sender.startSharing(
      FileMetadata(
        name: p.basename(source.path),
        path: source.path,
        size: sizeBytes,
        mimeType: 'application/octet-stream',
      ),
      'lan-token',
    );

    final roomCode = DeepLinkService.parseFromText(shareLink);
    expect(roomCode, isNotNull,
        reason: 'the share link must carry a room the receiver can join');

    final savedPath = await receiver.receive(
      roomCode!,
      targetDir: destination.path,
      signalingUrl: signalingUrl,
    );

    final received = File(savedPath);
    expect(received.existsSync(), isTrue);
    final bytes = received.readAsBytesSync();
    expect(bytes.length, equals(sizeBytes));
    expect(sha256.convert(bytes).toString(), equals(expected),
        reason: 'byte-for-byte across a real DataChannel');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('the offer this path produces is data-channel only',
      (tester) async {
    // Same regression as the serverless path: three m-sections in the offer
    // made libwebrtc reject the answer. startSharing() builds its offer through
    // a different method, so it needs its own guard.
    final sender = WebRtcTransferTransport();
    addTearDown(sender.stopSharing);
    await sender.initialize();

    final probe = File(p.join(workspace.path, 'probe.bin'))
      ..writeAsBytesSync([1, 2, 3]);
    await sender.startSharingServerless(FileMetadata(
      name: 'probe.bin',
      path: probe.path,
      size: 3,
      mimeType: 'application/octet-stream',
    ));

    final sdp = await sender.createLocalOfferSdp();
    final mediaSections =
        sdp!.split(RegExp(r'\r?\n')).where((l) => l.startsWith('m=')).toList();

    expect(mediaSections, hasLength(1),
        reason: 'audio and video sections break the CompactSdp round trip');
    expect(mediaSections.single, startsWith('m=application'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

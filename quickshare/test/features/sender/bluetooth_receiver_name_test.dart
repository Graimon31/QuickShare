// What the sender does with the name the connected receiver gives itself.
//
// Nothing is listed and nothing is picked, but the name still does one job: a
// sender that cannot raise a Wi-Fi network normally asks the receiver to, and
// an Apple receiver cannot, so asking it only costs a round of waiting. The
// sender skips the question for a device that says it is an iPhone, an iPad or
// a Mac, and asks everyone else — which is the behaviour the removed device
// list used to feed, and has to survive its removal.
//
// This is observed at the radio, with the Apple bridge selected: what the
// native side reports in, and the negotiation frames that go out.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';

class _MockRepository extends Mock implements SenderRepository {}

class _MockHotspot extends Mock implements LocalHotspotService {}

class _SilentPeerLink extends PeerLinkService {
  const _SilentPeerLink();
  @override
  Future<void> stop() async {}
}

class _NoDiagnostics extends TransferDiagnostics {
  const _NoDiagnostics();
  @override
  Future<void> record(TransferReport report) async {}
}

/// An Apple-shaped device: it cannot host a network, it can join a
/// peer-to-peer link, and every step it is asked to take succeeds at once.
class _AppleDriver implements DirectLinkDriver {
  @override
  bool get canHost => false;
  @override
  bool get canPeerLink => true;
  @override
  Future<bool> ensureWifiReady() async => true;
  @override
  Future<HotspotCredentials> host() =>
      throw UnimplementedError('canHost is false');
  @override
  Future<void> joinNetwork(HotspotCredentials credentials) async {}
  @override
  Future<void> stopHosting() async {}
  @override
  Future<void> leaveNetwork() async {}
  @override
  Future<void> hostPeerLink(String serviceName, int localPort) async {}
  @override
  Future<int> joinPeerLink(String serviceName) async => 4242;
  @override
  Future<void> stopPeerLink() async {}
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('quickshare/bluetooth');
  const events = MethodChannel('quickshare/bluetooth/events');
  const codec = StandardMethodCodec();

  late Directory scratch;
  late List<MethodCall> sent;

  setUpAll(() {
    registerFallbackValue(Duration.zero);
    registerFallbackValue((int items, int bytes) {});
    registerFallbackValue((Object error) {});
    registerFallbackValue(<String>[]);
  });

  Future<void> radioSays(Map<String, Object?> event) =>
      binding.defaultBinaryMessenger.handlePlatformMessage(
          events.name, codec.encodeSuccessEnvelope(event), (_) {});

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('bt_receiver_name');
    File('${scratch.path}/offer.bin').writeAsBytesSync([1, 2, 3, 4, 5]);
    sent = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods,
        (call) async {
      sent.add(call);
      if (call.method == 'startAdvertising') {
        await radioSays({'type': 'advertisingStarted'});
      }
      return null;
    });
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (call) async => null);
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
    scratch.deleteSync(recursive: true);
  });

  /// The `host` field of every link directive the sender has written so far.
  List<Object?> directives() => [
        for (final call in sent)
          if (call.method == 'sendLinkFrame')
            if ((call.arguments as Map)['frame'] case {'link': final Map link})
              link['host'],
      ];

  /// Whether the sender has told the receiver where the file is — the last
  /// thing a rendezvous does, after which nothing is left running.
  bool served() => sent.any((call) =>
      call.method == 'sendLinkFrame' &&
      (call.arguments as Map)['frame'] is Map &&
      ((call.arguments as Map)['frame'] as Map).containsKey('serve'));

  /// Runs a whole Bluetooth rendezvous with a receiver that calls itself
  /// [receiverName], to the end, and returns what the sender asked of it.
  Future<List<Object?>> negotiateWith(
      WidgetTester tester, String receiverName) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    SenderBloc? bloc;
    try {
      await tester.runAsync(() async {
        final repository = _MockRepository();
        when(() => repository.stopServer(force: any(named: 'force')))
            .thenAnswer((_) async => const Right(null));
        when(() => repository.transferProgress)
            .thenAnswer((_) => const Stream.empty());
        when(() => repository.statusStream)
            .thenAnswer((_) => const Stream.empty());
        when(() => repository.approvalRequests)
            .thenAnswer((_) => const Stream.empty());
        when(() => repository.sessionTlsFingerprint).thenReturn('AA:BB');
        when(() => repository.lastQhtpClientAddress).thenReturn(null);
        when(() =>
                repository.waitForFirstClient(timeout: any(named: 'timeout')))
            .thenAnswer((_) async => true);
        when(() => repository.startQhtpTransfer(
              any(),
              authToken: any(named: 'authToken'),
              onIndexed: any(named: 'onIndexed'),
              onIndexFailed: any(named: 'onIndexFailed'),
            )).thenAnswer((_) async => Right(TransferSession(
              id: 'session',
              fileMetadata: const FileMetadata(
                name: 'offer.bin',
                path: '/tmp/offer.bin',
                size: 5,
                mimeType: 'application/octet-stream',
              ),
              serverPort: 8123,
              authToken: 'token',
              localIp: '192.168.1.10',
              startedAt: DateTime.utc(2026),
              status: TransferStatus.serving,
              isQhtp: true,
            )));
        final hotspot = _MockHotspot();
        when(hotspot.stopHosting).thenAnswer((_) async {});

        bloc = SenderBloc(
          repository: repository,
          hotspotService: hotspot,
          peerLinkService: const _SilentPeerLink(),
          directLinkDriver: _AppleDriver(),
          diagnostics: const _NoDiagnostics(),
        );
        bloc!.add(StartQhtpSend(['${scratch.path}/offer.bin'],
            mode: TransportType.bluetooth));
        await bloc!.stream
            .firstWhere((s) => s is BluetoothAdvertising)
            .timeout(const Duration(seconds: 30));

        // In the order a real receiver does it: says who it is, hands over its
        // key, and is ready.
        await radioSays({'type': 'receiverAnnounced', 'name': receiverName});
        await radioSays({
          'type': 'peerKey',
          'key': 'A' * 43 + '=',
        });
        await radioSays({'type': 'receiverReady'});

        // The ladder ends on the peer-to-peer rung for an Apple pair, with the
        // question to the receiver, if there is one, before it. The test waits
        // for the serve frame that follows, so nothing is still in flight when
        // the bloc is closed.
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (!served()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('the negotiation never finished: ${directives()}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      return directives();
    } finally {
      await tester.runAsync(() async => bloc?.close());
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('a receiver that is an iPhone is not asked to raise a network',
      (tester) async {
    final asked = await negotiateWith(tester, "Anna's iPhone");

    expect(asked, isNot(contains('receiver')),
        reason: 'it cannot, and the question costs a round of waiting');
    expect(asked, contains('peerlink'));
  });

  testWidgets('a Mac is not asked either', (tester) async {
    final asked = await negotiateWith(tester, 'MacBook Pro');

    expect(asked, isNot(contains('receiver')));
  });

  testWidgets('any other receiver is asked to raise one', (tester) async {
    final asked = await negotiateWith(tester, 'Pixel 9');

    expect(asked, contains('receiver'));
    expect(asked, contains('peerlink'));
  });

  testWidgets('a receiver that never said what it is is asked', (tester) async {
    final asked = await negotiateWith(tester, '');

    expect(asked, contains('receiver'),
        reason: 'unknown is not Apple; the old behaviour was to ask');
  });
}

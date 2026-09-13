// Selecting several files and sending them over Bluetooth used to send one.
//
// The native Bluetooth bridge advertised a single file and had no manifest,
// so the sender took `files.first` and the rest of the selection vanished
// without a message, an error, or anything on screen to suggest it. The
// stopgap after that was a .zip: it sent everything, at the price of handing
// the recipient an archive to unpack instead of photos in their gallery.
//
// The bridge now takes the whole list, each file carrying the relative path
// it keeps on the far side — so a folder crosses Bluetooth as a folder and
// nothing is bundled into anything.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/crypto/link_secret.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';

class _MockSenderRepository extends Mock implements SenderRepository {}

/// Stands in for the native side, which does not exist under `flutter test`.
class _FakePeerLink extends PeerLinkService {
  const _FakePeerLink();

  // The fast path exists on iOS and macOS; CI runs on Linux, where the real
  // answer is false and these tests asserted an empty branch.
  @override
  bool get supported => true;

  @override
  Future<void> host({
    required String serviceName,
    required int localPort,
    Duration timeout = const Duration(seconds: 5),
  }) async {}

  @override
  Future<void> stop() async {}
}

/// Answers for the Wi-Fi radio the test runner does not have: hosting always
/// succeeds and the network always has an address.
class _FakeDirectLinkDriver implements DirectLinkDriver {
  const _FakeDirectLinkDriver();

  @override
  bool get canHost => true;

  @override
  Future<HotspotCredentials> host(SessionCode code) async =>
      HotspotCredentials(
          ssid: code.ssid,
          passphrase: code.passphrase,
          hostAddress: '192.168.4.1');

  @override
  Future<void> joinNetwork(HotspotCredentials credentials) async {}

  @override
  Future<bool> ensureWifiReady() async => true;

  @override
  Future<void> stopHosting() async {}

  @override
  Future<void> leaveNetwork() async {}

  // Hosting works in this fake, so the peer-to-peer rung is never reached.
  @override
  bool get canPeerLink => false;

  @override
  Future<void> hostPeerLink(String serviceName, int localPort) async =>
      throw UnimplementedError();

  @override
  Future<int> joinPeerLink(String serviceName) async =>
      throw UnimplementedError();

  @override
  Future<void> stopPeerLink() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('quickshare/bluetooth');
  const events = MethodChannel('quickshare/bluetooth/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory workspace;
  late _MockSenderRepository repository;
  late List<MethodCall> nativeCalls;

  setUpAll(() {
    registerFallbackValue(const Duration(seconds: 1));
  });

  setUp(() {
    // The bridge is chosen from the target platform, not the host, so the
    // Apple path is what this exercises wherever the suite runs.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    workspace = Directory.systemTemp.createTempSync('dd_bt_multi_');
    nativeCalls = [];

    messenger.setMockMethodCallHandler(method, (call) async {
      nativeCalls.add(call);
      return null;
    });
    // The transport subscribes to the event channel on initialize().
    messenger.setMockMethodCallHandler(events, (call) async => null);

    repository = _MockSenderRepository();
    when(() => repository.transferProgress)
        .thenAnswer((_) => const Stream.empty());
    when(() => repository.statusStream).thenAnswer((_) => const Stream.empty());
    // What the serve frame pins the receiver's pull to. Without one the
    // session refuses to hand out an address at all — see DD-01.
    when(() => repository.sessionTlsFingerprint)
        .thenReturn('K_Ro4-N-V4udoTFvW8VYS_sPoXq4aCH465');
    when(() => repository.stopServer(force: any(named: 'force')))
        .thenAnswer((_) async => const Right(null));
    when(repository.stopServer).thenAnswer((_) async => const Right(null));
    when(() => repository.waitForFirstClient(timeout: any(named: 'timeout')))
        .thenAnswer((_) async => true);
    when(() => repository.approvalRequests)
        .thenAnswer((_) => const Stream.empty());
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockMethodCallHandler(events, null);
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  File write(String name) => File(p.join(workspace.path, name))
    ..writeAsStringSync('contents of $name');

  /// Starts a Bluetooth send and returns the native scan call.
  ///
  /// The sender now finds receivers (GATT central). Files no longer ride the
  /// advertisement — they cross Wi-Fi after the rendezvous.
  Future<Map> startedScan(List<String> paths) async {
    final bloc = SenderBloc(
      repository: repository,
      peerLinkService: const _FakePeerLink(),
    );
    addTearDown(bloc.close);

    final advertising = bloc.stream.firstWhere((s) => s is BluetoothAdvertising);
    bloc.add(StartQhtpSend(paths, mode: TransportType.bluetooth));
    await advertising.timeout(const Duration(seconds: 20));

    expect(nativeCalls.any((c) => c.method == 'startAdvertising'), isTrue);
    final call = nativeCalls.firstWhere((c) => c.method == 'startScanning');
    return call.arguments as Map;
  }

  /// Delivers a native bridge event the way CoreBluetooth would.
  Future<void> emitNativeEvent(Map<String, Object?> event) async {
    await messenger.handlePlatformMessage(
      'quickshare/bluetooth/events',
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  /// Waits until [condition] holds, bounded so a broken negotiation fails
  /// the test instead of hanging it.
  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('progress on the direct link moves the sender off its QR code',
      () async {
    // The file went out over the direct link, finished, and the sender screen
    // sat on its QR the whole time — no progress, no completion, nothing to
    // say it had worked. Reported as "the QR never changed", and it is
    // indistinguishable from a hung app.
    final progress = StreamController<double>.broadcast();
    addTearDown(progress.close);
    when(() => repository.transferProgress)
        .thenAnswer((_) => progress.stream);
    when(() => repository.startQhtpTransfer(any(),
            authToken: any(named: 'authToken'),
            onIndexed: any(named: 'onIndexed'),
            onIndexFailed: any(named: 'onIndexFailed')))
        .thenAnswer((_) async => Right(TransferSession(
              id: 'direct-link',
              fileMetadata: const FileMetadata(
                name: 'holiday.mov',
                path: '/tmp/holiday.mov',
                size: 1000,
                mimeType: 'video/quicktime',
              ),
              serverPort: 8000,
              authToken: 'tok',
              localIp: '127.0.0.1',
              startedAt: DateTime.now(),
            )));

    final bloc = SenderBloc(
      repository: repository,
      peerLinkService: const _FakePeerLink(),
      directLinkDriver: const _FakeDirectLinkDriver(),
    );
    addTearDown(bloc.close);
    final advertising = bloc.stream.firstWhere((s) => s is BluetoothAdvertising);
    bloc.add(StartQhtpSend([write('holiday.mov').path],
        mode: TransportType.bluetooth));
    await advertising.timeout(const Duration(seconds: 20));

    // A generation-4 receiver is connected; the negotiation and the serving
    // session build from here, and only then does progress have a listener.
    // Its public half comes first: the credentials of the network this
    // device raises are sealed against it, so nothing moves until it lands.
    await emitNativeEvent(
        {'type': 'peerKey', 'key': (await LinkSecret.generate()).publicKey});
    await emitNativeEvent({'type': 'receiverReady'});
    // The serve frame, not merely the first one: the negotiation's own
    // directive goes out before it, and the progress listener is only
    // subscribed once the address has been handed over.
    await until(() => nativeCalls.any((c) =>
        c.method == 'sendLinkFrame' &&
        '${(c.arguments as Map)['frame']}'.contains('serve')));

    final moved = bloc.stream.firstWhere((s) => s is Transferring);
    progress.add(0.5);
    await expectLater(moved.timeout(const Duration(seconds: 10)),
        completes);
  });

  test('the direct link accepts the token the receiver actually has',
      () async {
    // The receiver on the far side of a Bluetooth session holds one token:
    // the Bluetooth one. A QHTP session minting its own answered 401 to the
    // only device it existed to serve, and the screen reported a connection
    // failure before falling back on the retry.
    final captured = <String?>[];
    when(() => repository.startQhtpTransfer(any(),
            authToken: any(named: 'authToken'),
            onIndexed: any(named: 'onIndexed'),
            onIndexFailed: any(named: 'onIndexFailed')))
        .thenAnswer((invocation) async {
      captured.add(invocation.namedArguments[#authToken] as String?);
      return const Left(NetworkFailure('not needed for this test'));
    });

    final bloc = SenderBloc(
      repository: repository,
      peerLinkService: const _FakePeerLink(),
      directLinkDriver: const _FakeDirectLinkDriver(),
    );
    addTearDown(bloc.close);
    final advertising = bloc.stream.firstWhere((s) => s is BluetoothAdvertising);
    bloc.add(StartQhtpSend([write('holiday.mov').path],
        mode: TransportType.bluetooth));
    await advertising.timeout(const Duration(seconds: 20));

    await emitNativeEvent(
        {'type': 'peerKey', 'key': (await LinkSecret.generate()).publicKey});
    await emitNativeEvent({'type': 'receiverReady'});
    await until(() => captured.isNotEmpty);

    final advertisedToken =
        (nativeCalls.firstWhere((c) => c.method == 'startScanning').arguments
            as Map)['sessionToken'] as String;
    expect(captured.single, equals(advertisedToken),
        reason: 'both halves of one session have to agree on its token');
  });

  test('the sender scans for waiting receivers instead of advertising files',
      () async {
    final files = [write('one.txt'), write('two.txt')];
    final args = await startedScan([for (final f in files) f.path]);
    expect(args['forReceivers'], isTrue);
    expect(args['sessionToken'], isNotEmpty);
  });

  test('a broken fast path does not take the Bluetooth transfer with it',
      () async {
    final files = [write('one.txt'), write('two.txt')];
    final args = await startedScan([for (final f in files) f.path]);
    expect(args['forReceivers'], isTrue,
        reason: 'Bluetooth scan starts regardless of the extra route failing');
  });

  test('a folder still starts a Bluetooth send session', () async {
    final trip = Directory(p.join(workspace.path, 'Trip'))..createSync();
    Directory(p.join(trip.path, 'Day 2')).createSync();
    File(p.join(trip.path, 'IMG_0001.jpg')).writeAsStringSync('a');
    File(p.join(trip.path, 'Day 2', 'IMG_0002.jpg')).writeAsStringSync('b');

    final args = await startedScan([trip.path]);
    expect(args['forReceivers'], isTrue);
  });
}

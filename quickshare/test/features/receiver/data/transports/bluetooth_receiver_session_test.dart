import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/storage/gallery_formats.dart';
import 'package:quickshare/core/storage/receive_destination.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/receiver/data/client/isolated_qhtp_receiver.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_session.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_receive_result.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class _FakeBleReceiver implements BleReceiver {
  final _devicesController = StreamController<BluetoothDevice>();
  final _serveController = StreamController<LinkServeInfo>();

  void emitDevice(BluetoothDevice device) => _devicesController.add(device);
  void emitServe(LinkServeInfo serve) => _serveController.add(serve);

  @override
  Stream<BluetoothDevice> get devices => _devicesController.stream;

  @override
  Stream<BluetoothReceiveProgress> get progressStream => const Stream.empty();

  @override
  Stream<DirectLinkDirective> get linkDirectives => const Stream.empty();

  @override
  Stream<LinkServeInfo> get serveInfos => _serveController.stream;

  @override
  Future<void> startScanning({String? sessionToken, String? publicId}) async {}

  @override
  Future<void> stopScanning() async {}

  @override
  Future<void> startWaitingAdvertisement({required String deviceName}) async {}

  @override
  Future<String> connect(String deviceId, {String? token, String? targetDir}) =>
      // The legacy in-band path never lands in these tests; the serve frame
      // is what carries the session.
      Completer<String>().future;

  @override
  Future<void> sendApOffer(String sealed) async {}

  @override
  Future<void> sendKeyExchange(String publicKey) async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

/// Peer-link answers instantly, so the direct-link negotiation does not sit
/// out its 45-second budget beside a test that has already decided.
class _FakeDriver implements DirectLinkDriver {
  @override
  bool get canHost => false;

  @override
  bool get canPeerLink => true;

  @override
  Future<int> joinPeerLink(String serviceName) async => 4242;

  @override
  Future<void> hostPeerLink(String serviceName, int localPort) async {}

  @override
  Future<void> stopPeerLink() async {}

  @override
  Future<HotspotCredentials> host(SessionCode code) =>
      throw UnimplementedError('canHost is false; host is never called');

  @override
  Future<bool> ensureWifiReady() async => true;

  @override
  Future<void> joinNetwork(HotspotCredentials credentials) async {}

  @override
  Future<void> leaveNetwork() async {}

  @override
  Future<void> stopHosting() async {}
}

class _FakeNetworkInfo extends NetworkInfoService {
  @override
  Future<String?> getLocalIpAddress() async => '192.168.4.2';
}

class _FakeHotspot extends LocalHotspotService {
  @override
  Future<void> leaveNetwork() async {}
}

class _FakeQhtpReceiver extends IsolatedQhtpReceiver {
  _FakeQhtpReceiver(this._result);

  final Either<Failure, QhtpReceiveResult> _result;

  @override
  Future<Either<Failure, QhtpReceiveResult>> downloadSession({
    required QRPayload payload,
    required String targetBaseDir,
    void Function(QhtpProgress progress)? onProgress,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return _result;
  }
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('dd_bt_session_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<ReceiveDestination> cacheDestination() => ReceiveDestination.resolve(
        destination: const SaveDestination(
            isDesktop: false, gallery: GalleryFormats(GalleryPlatform.ios)),
        cache: TransferCache(overrideRoot: () => root),
      );

  test('a failed QHTP session completes run() with the failure, not silence',
      () async {
    final transport = _FakeBleReceiver();
    final session = BluetoothReceiverSession(
      transport: transport,
      driver: _FakeDriver(),
      networkInfo: _FakeNetworkInfo(),
      hotspotService: _FakeHotspot(),
      qhtpReceiver: _FakeQhtpReceiver(
          const Left(NetworkFailure('the link dropped mid-session'))),
    );

    final running = session.run(
      token: 'token',
      publicId: 'public',
      destination: await cacheDestination(),
      onProgress: (_, __, ___) {},
      onVerifying: () {},
    );

    transport.emitDevice(const BluetoothDevice(id: 'd1', name: 'Sender'));
    // The device listener subscribes to serve frames asynchronously; fire the
    // frame only once the ear exists.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    transport.emitServe(const LinkServeInfo(
        ip: '127.0.0.1', port: 9, token: 'token', tlsFingerprint: 'ff'));

    // Without a completion on the failure branch this future never settles
    // and the receive screen spins forever; the timeout is what catches it.
    await expectLater(
      running.timeout(const Duration(seconds: 5)),
      throwsA(isA<Exception>().having((e) => e.toString(), 'message',
          contains('the link dropped mid-session'))),
    );
  });

  test('a finished session lists what it left in the session directory',
      () async {
    final dest = await cacheDestination();
    final folder = Directory(p.join(dest.path, 'trip'))..createSync();
    File(p.join(folder.path, 'a.jpg')).writeAsStringSync('12345');

    final transport = _FakeBleReceiver();
    final session = BluetoothReceiverSession(
      transport: transport,
      driver: _FakeDriver(),
      networkInfo: _FakeNetworkInfo(),
      hotspotService: _FakeHotspot(),
      qhtpReceiver: _FakeQhtpReceiver(Right(QhtpReceiveResult(
          preferredResultPath: dest.path, displayName: 'trip'))),
    );

    final running = session.run(
      token: 'token',
      publicId: 'public',
      destination: dest,
      onProgress: (_, __, ___) {},
      onVerifying: () {},
    );

    transport.emitDevice(const BluetoothDevice(id: 'd1', name: 'Sender'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    transport.emitServe(const LinkServeInfo(
        ip: '127.0.0.1', port: 9, token: 'token', tlsFingerprint: 'ff'));

    final result = await running.timeout(const Duration(seconds: 5));

    expect(result.items, hasLength(1));
    expect(result.items.single.name, 'trip');
    expect(result.items.single.isDirectory, isTrue);
    expect(result.items.single.size, 5, reason: 'the whole tree counts');
    expect(result.placed, isFalse);
  });
}

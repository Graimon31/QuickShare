import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/network_info_service.dart';
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
  final _failureController = StreamController<BleReceiverFailure>();

  /// What `connect` does. Completing at once is a handshake that went well.
  Future<void> Function() onConnect = () async {};

  /// The devices the session connected to.
  final List<String> connected = [];

  void emitDevice(BluetoothDevice device) => _devicesController.add(device);
  void emitServe(LinkServeInfo serve) => _serveController.add(serve);
  void emitFailure(String message, String code) =>
      _failureController.add(BleReceiverFailure(message, code));

  @override
  Stream<BluetoothDevice> get devices => _devicesController.stream;

  @override
  Stream<DirectLinkDirective> get linkDirectives => Stream.value(
      const DirectLinkDirective.overPeerLink(serviceName: 'test-link'));

  @override
  Stream<LinkServeInfo> get serveInfos => _serveController.stream;

  @override
  Stream<BleReceiverFailure> get failures => _failureController.stream;

  @override
  Future<void> startScanning({String? sessionToken, String? locator}) async {}

  @override
  Future<void> stopScanning() async {}

  @override
  Future<void> connect(String deviceId, {String? token}) {
    connected.add(deviceId);
    return onConnect();
  }

  @override
  Future<void> sendApOffer(String sealed) async {}

  @override
  Future<void> sendKeyExchange(String publicKey) async {}

  /// How many times the radio itself was told to cancel.
  int cancels = 0;

  @override
  Future<void> cancel() async => cancels++;

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
  Future<HotspotCredentials> host() =>
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

class _DelayedPeerDriver extends _FakeDriver {
  final joined = Completer<int>();
  final joining = Completer<void>();

  @override
  Future<int> joinPeerLink(String serviceName) {
    joining.complete();
    return joined.future;
  }
}

/// A device whose Wi-Fi is off: the negotiation ends at once, with a reason.
class _WifiOffDriver extends _FakeDriver {
  @override
  Future<bool> ensureWifiReady() async => false;
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
  final payloads = <QRPayload>[];

  @override
  Future<Either<Failure, QhtpReceiveResult>> downloadSession({
    required QRPayload payload,
    required String targetBaseDir,
    void Function(QhtpProgress progress)? onProgress,
  }) async {
    payloads.add(payload);
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

  test('early and duplicate serve frames wait for the peer proxy', () async {
    final transport = _FakeBleReceiver();
    final driver = _DelayedPeerDriver();
    final receiver = _FakeQhtpReceiver(const Left(NetworkFailure('finished')));
    final session = BluetoothReceiverSession(
      transport: transport,
      driver: driver,
      networkInfo: _FakeNetworkInfo(),
      hotspotService: _FakeHotspot(),
      qhtpReceiver: receiver,
    );
    final running = session.run(
      token: 'token',
      locator: 'public',
      destination: await cacheDestination(),
      onProgress: (_, __, ___) {},
      onVerifying: () {},
    );
    final checked = expectLater(
        running.timeout(const Duration(seconds: 5)), throwsA(isA<Exception>()));
    transport.emitDevice(const BluetoothDevice(id: 'd1', name: 'Sender'));
    await driver.joining.future.timeout(const Duration(seconds: 5));
    const serve = LinkServeInfo(
        ip: '127.0.0.1', port: 8000, token: 'secret', tlsFingerprint: 'pin');
    transport.emitServe(serve);
    transport.emitServe(serve);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(receiver.payloads, isEmpty);
    driver.joined.complete(4242);
    await checked;
    expect(receiver.payloads, hasLength(1));
    final payload = receiver.payloads.single;
    expect(payload.ip, '127.0.0.1');
    expect(payload.port, 4242);
    expect(payload.token, 'secret');
    expect(payload.tlsFingerprint, 'pin');
  });

  test('an early serve does not hide a failed negotiation', () async {
    final transport = _FakeBleReceiver();
    final driver = _DelayedPeerDriver();
    final receiver =
        _FakeQhtpReceiver(const Left(NetworkFailure('unexpected')));
    final session = BluetoothReceiverSession(
      transport: transport,
      driver: driver,
      networkInfo: _FakeNetworkInfo(),
      hotspotService: _FakeHotspot(),
      qhtpReceiver: receiver,
    );
    final running = session.run(
      token: 'token',
      locator: 'public',
      destination: await cacheDestination(),
      onProgress: (_, __, ___) {},
      onVerifying: () {},
    );
    final checked = expectLater(
        running.timeout(const Duration(seconds: 5)),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message',
            contains('Could not set up the direct Wi-Fi link'))));
    transport.emitDevice(const BluetoothDevice(id: 'd1', name: 'Sender'));
    await driver.joining.future.timeout(const Duration(seconds: 5));
    transport.emitServe(const LinkServeInfo(
        ip: '127.0.0.1', port: 8000, token: 'token', tlsFingerprint: 'pin'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    driver.joined.completeError(StateError('join failed'));
    await checked;
    expect(receiver.payloads, isEmpty);
  });

  test('a scan failure completes the session before any device is found',
      () async {
    final transport = _FakeBleReceiver();
    final session = BluetoothReceiverSession(
      transport: transport,
      driver: _FakeDriver(),
      networkInfo: _FakeNetworkInfo(),
      hotspotService: _FakeHotspot(),
    );
    final result = session.run(
      token: 'token',
      locator: 'public',
      destination: await cacheDestination(),
      onProgress: (_, __, ___) {},
      onVerifying: () {},
    );
    final checked = expectLater(
        result,
        throwsA(isA<FileException>()
            .having((e) => e.message, 'message', 'Bluetooth is turned off')));
    transport.emitFailure(
        'Bluetooth is turned off', FailureCode.bluetoothTransferFailed);
    await checked;
    expect(transport.connected, isEmpty);
    expect(transport.cancels, 1);
  });

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
      locator: 'public',
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
      locator: 'public',
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

  test('cancelling a running session cancels the radio too', () async {
    // The native bridge keeps a connection and a half-open transfer of its own;
    // stopping the Dart side alone left both standing.
    final transport = _FakeBleReceiver();
    final session = BluetoothReceiverSession(
      transport: transport,
      driver: _FakeDriver(),
      networkInfo: _FakeNetworkInfo(),
      hotspotService: _FakeHotspot(),
      qhtpReceiver:
          _FakeQhtpReceiver(const Left(NetworkFailure('never reached'))),
    );

    // Never settles: nothing is cancelled to completion in the fake, and the
    // search timer it started is cancelled with the session.
    unawaited(session
        .run(
          token: 'token',
          locator: 'public',
          destination: await cacheDestination(),
          onProgress: (_, __, ___) {},
          onVerifying: () {},
        )
        .then<void>((_) {}, onError: (Object _) {}));

    await session.cancel();

    expect(transport.cancels, 1);
  });

  group('what the radio and the negotiation can say', () {
    BluetoothReceiverSession sessionWith(
      _FakeBleReceiver transport, {
      DirectLinkDriver? driver,
      Duration handshake = const Duration(seconds: 20),
      Either<Failure, QhtpReceiveResult>? download,
    }) =>
        BluetoothReceiverSession(
          transport: transport,
          driver: driver ?? _FakeDriver(),
          networkInfo: _FakeNetworkInfo(),
          hotspotService: _FakeHotspot(),
          qhtpReceiver: _FakeQhtpReceiver(
              download ?? const Left(NetworkFailure('never reached'))),
          handshakeBudget: handshake,
        );

    Future<BluetoothReceiverSessionResult> runOn(
            BluetoothReceiverSession session) async =>
        session.run(
          token: 'token',
          locator: 'public',
          destination: await cacheDestination(),
          onProgress: (_, __, ___) {},
          onVerifying: () {},
        );

    const sender = BluetoothDevice(id: 'd1', name: 'Sender');
    const serve = LinkServeInfo(
        ip: '127.0.0.1', port: 9, token: 'token', tlsFingerprint: 'ff');

    test(
        'a link that cannot be built ends the session with the reason, not '
        'a spinner', () async {
      // The negotiation used to end in a log line when it found no way to
      // join the sender, and the screen waited for a serve frame that could
      // not come.
      final transport = _FakeBleReceiver();
      final running = runOn(sessionWith(transport, driver: _WifiOffDriver()));
      transport.emitDevice(sender);

      await expectLater(
        running.timeout(const Duration(seconds: 5)),
        throwsA(isA<FileException>()
            .having((e) => e.code, 'code', FailureCode.linkWifiOff)),
      );
    });

    test(
        'a sender that is still pushing a file over Bluetooth is told to '
        'update, not received from', () async {
      final transport = _FakeBleReceiver();
      final running = runOn(sessionWith(transport));
      transport.emitDevice(sender);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      transport.emitFailure(
          'older sender', FailureCode.senderTooOldForDirectLink);

      await expectLater(
        running.timeout(const Duration(seconds: 5)),
        throwsA(isA<FileException>().having(
            (e) => e.code, 'code', FailureCode.senderTooOldForDirectLink)),
      );
    });

    test('the radio dropping before the serve frame ends the session',
        () async {
      final transport = _FakeBleReceiver();
      final running = runOn(sessionWith(transport));
      transport.emitDevice(sender);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      transport.emitFailure('dropped', FailureCode.linkPeerLost);

      await expectLater(
        running.timeout(const Duration(seconds: 5)),
        throwsA(isA<FileException>()
            .having((e) => e.code, 'code', FailureCode.linkPeerLost)),
      );
    });

    test('and after the serve frame it is nothing: the file crosses Wi-Fi',
        () async {
      final dest = await cacheDestination();
      File(p.join(dest.path, 'a.bin')).writeAsStringSync('12345');
      final transport = _FakeBleReceiver();
      final session = sessionWith(transport,
          download: Right(QhtpReceiveResult(
              preferredResultPath: dest.path, displayName: 'a.bin')));
      final running = session.run(
        token: 'token',
        locator: 'public',
        destination: dest,
        onProgress: (_, __, ___) {},
        onVerifying: () {},
      );
      transport.emitDevice(sender);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      transport.emitServe(serve);
      transport.emitFailure('dropped', FailureCode.linkPeerLost);

      final result = await running.timeout(const Duration(seconds: 5));
      expect(result.items, hasLength(1));
    });

    test('a handshake that never finishes ends in an error', () async {
      final transport = _FakeBleReceiver()
        ..onConnect = () => Completer<void>().future;
      final running = runOn(
          sessionWith(transport, handshake: const Duration(milliseconds: 100)));
      transport.emitDevice(sender);

      await expectLater(
        running.timeout(const Duration(seconds: 5)),
        throwsA(isA<FileException>()
            .having((e) => e.code, 'code', FailureCode.linkPeerLost)),
      );
      expect(transport.cancels, greaterThanOrEqualTo(1),
          reason: 'the half-open connection is let go');
    });

    test('a connect that fails ends the session with the failure', () async {
      final transport = _FakeBleReceiver()
        ..onConnect = () async => throw Exception('Failed to connect');
      final running = runOn(sessionWith(transport));
      transport.emitDevice(sender);

      await expectLater(
        running.timeout(const Duration(seconds: 5)),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('Failed to connect'))),
      );
    });

    test('two senders in range are not two connections', () async {
      final transport = _FakeBleReceiver();
      final running = runOn(sessionWith(transport));
      transport.emitDevice(sender);
      transport.emitDevice(const BluetoothDevice(id: 'd2', name: 'Other'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(transport.connected, ['d1']);

      await expectLater((() async {
        transport.emitFailure('end it', FailureCode.linkPeerLost);
        await running;
      })(), throwsA(isA<Exception>()));
    });
  });
}

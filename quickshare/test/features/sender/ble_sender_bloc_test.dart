// A Bluetooth session on an Android phone or a Windows PC, from the bloc down.
//
// The pieces are tested one by one elsewhere; this is the seam between them,
// which is where this feature was broken: the bloc built a real transport,
// the real transport advertised nothing on these platforms, and the only
// rotation test used a transport that was a fake all the way down, so none of
// it could notice.
//
// Everything below the bloc is real — the transport, the protocol, the
// coordinator — and the radio is a fake that answers the way the plugin does.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/crypto/link_secret.dart';
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

import '../../support/fake_ble.dart';

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

/// A device that raises a hotspot when asked, or cannot.
class _Driver implements DirectLinkDriver {
  _Driver({required this.canHost});

  @override
  final bool canHost;

  int hosted = 0;

  @override
  bool get canPeerLink => false;

  @override
  Future<bool> ensureWifiReady() async => true;

  @override
  Future<HotspotCredentials> host(SessionCode code) async {
    hosted++;
    return HotspotCredentials(
        ssid: code.ssid, passphrase: code.passphrase, hostAddress: '192.168.137.1');
  }

  @override
  Future<void> joinNetwork(HotspotCredentials credentials) async {}

  @override
  Future<void> stopHosting() async {}

  @override
  Future<void> leaveNetwork() async {}

  @override
  Future<void> hostPeerLink(String serviceName, int localPort) async {}

  @override
  Future<int> joinPeerLink(String serviceName) async => 0;

  @override
  Future<void> stopPeerLink() async {}
}

void main() {
  late FakeBlePeripheral radio;
  late FakeBleCentral central;
  late Directory scratch;
  late DateTime clock;
  late List<BluetoothTransferTransport> transports;
  SenderBloc? bloc;

  setUpAll(() {
    registerFallbackValue(Duration.zero);
    registerFallbackValue((int items, int bytes) {});
    registerFallbackValue((Object error) {});
    registerFallbackValue(<String>[]);
  });

  setUp(() {
    radio = FakeBlePeripheral();
    central = FakeBleCentral();
    UniversalBlePeripheral.setInstance(radio);
    UniversalBle.setInstance(central);
    scratch = Directory.systemTemp.createTempSync('ble_sender_bloc');
    File('${scratch.path}/offer.bin').writeAsBytesSync([1, 2, 3, 4, 5]);
    clock = DateTime.utc(2026, 11, 4, 12);
    transports = [];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() async {
    await bloc?.close();
    bloc = null;
    debugDefaultTargetPlatformOverride = null;
    UniversalBlePeripheral.setInstance(UniversalBlePeripheralUnsupported());
    scratch.deleteSync(recursive: true);
  });

  SenderBloc build(_Driver driver) {
    final repository = _MockRepository();
    when(() => repository.stopServer(force: any(named: 'force')))
        .thenAnswer((_) async => const Right(null));
    when(() => repository.transferProgress)
        .thenAnswer((_) => const Stream.empty());
    when(() => repository.statusStream).thenAnswer((_) => const Stream.empty());
    when(() => repository.approvalRequests)
        .thenAnswer((_) => const Stream.empty());
    when(() => repository.sessionTlsFingerprint).thenReturn('AA' * 32);
    when(() => repository.lastQhtpClientAddress).thenReturn(null);
    when(() => repository.waitForFirstClient(timeout: any(named: 'timeout')))
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

    return bloc = SenderBloc(
      repository: repository,
      hotspotService: hotspot,
      peerLinkService: const _SilentPeerLink(),
      directLinkDriver: driver,
      diagnostics: const _NoDiagnostics(),
      now: () => clock,
      bluetoothTransportFactory: () {
        final t = BluetoothTransferTransport();
        transports.add(t);
        return t;
      },
    );
  }

  Future<BluetoothAdvertising> offerOn(SenderBloc b) async {
    final shown = b.stream
        .firstWhere((s) => s is BluetoothAdvertising || s is SenderError)
        .timeout(const Duration(seconds: 20));
    b.add(StartQhtpSend(['${scratch.path}/offer.bin'],
        mode: TransportType.bluetooth));
    final state = await shown;
    if (state is SenderError) {
      fail('no offer: ${state.message} (${state.code})');
    }
    return state as BluetoothAdvertising;
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    group('on ${platform.name}', () {
      setUp(() => debugDefaultTargetPlatformOverride = platform);

      test('the QR on screen belongs to an advertisement that is on the air',
          () async {
        final b = build(_Driver(canHost: true));

        final offer = await offerOn(b);

        expect(radio.advertised, hasLength(1));
        final qr = BluetoothQrPayload.tryDecode(offer.qrData)!;
        expect(qr.token, offer.code!.sessionToken);
        // The radio answers to this session's token and to no other.
        expect(
            radio
                .write('phone', BleGatt.control, BleControlProtocol.start(qr.token))
                ?.status,
            isNull);
      });

      test('the QR changes under a new code, and the advertisement with it',
          () async {
        final b = build(_Driver(canHost: true));
        final first = await offerOn(b);
        expect(radio.advertised, hasLength(1));

        final second = b.stream
            .firstWhere((s) => s is BluetoothAdvertising && s.code != first.code)
            .timeout(const Duration(seconds: 20));
        clock = clock.add(const Duration(minutes: 6));
        b.add(OfferResumed());
        final rotated = await second as BluetoothAdvertising;

        expect(rotated.qrData, isNot(first.qrData));
        expect(BluetoothQrPayload.tryDecode(rotated.qrData)!.token,
            rotated.code!.sessionToken);
        expect(radio.stopAdvertisingCalls, greaterThanOrEqualTo(1),
            reason: 'the old advertisement was left running');
        expect(radio.advertised, hasLength(2),
            reason: 'nothing was advertised under the new code');
        expect(transports, hasLength(2));

        // And the radio now answers to the new token and refuses the old.
        expect(
            radio
                .write('phone', BleGatt.control,
                    BleControlProtocol.start(rotated.code!.sessionToken))
                ?.status,
            isNull);
        expect(
            radio
                .write('phone', BleGatt.control,
                    BleControlProtocol.start(first.code!.sessionToken))
                ?.status,
            BleControlProtocol.attInsufficientAuthentication,
            reason: 'a receiver holding the old QR must not get in');
      });

      test('cancelling stops the advertisement', () async {
        final b = build(_Driver(canHost: true));
        await offerOn(b);

        b.add(CancelSending());
        await b.stream.firstWhere((s) => s is SenderInitial);

        expect(radio.stopAdvertisingCalls, greaterThanOrEqualTo(1));
        expect(radio.writeHandler, isNull,
            reason: 'a receiver can still write to a session that is over');
      });

      test('a radio that cannot advertise ends in an error, not a spinner',
          () async {
        radio.afterStart = PeripheralAdvertisingState.error;
        radio.advertisingError = 'Feature unsupported';
        final b = build(_Driver(canHost: true));

        final state = b.stream
            .firstWhere((s) => s is SenderError || s is BluetoothAdvertising)
            .timeout(const Duration(seconds: 20));
        b.add(StartQhtpSend(['${scratch.path}/offer.bin'],
            mode: TransportType.bluetooth));
        final error = await state;

        expect(error, isA<SenderError>());
        expect((error as SenderError).code, FailureCode.bluetoothAdvertiseFailed);
        expect(error.message, contains('Feature unsupported'));
      });

      test('Bluetooth being off says so', () async {
        radio.readiness = PeripheralReadinessState.bluetoothOff;
        final b = build(_Driver(canHost: true));

        final state = b.stream
            .firstWhere((s) => s is SenderError || s is BluetoothAdvertising);
        b.add(StartQhtpSend(['${scratch.path}/offer.bin'],
            mode: TransportType.bluetooth));

        expect(((await state) as SenderError).code, FailureCode.bluetoothOff);
      });
    });
  }

  group('the rendezvous, with a receiver that never said what it is', () {
    /// A phone does what a phone does: says what it can take, hands over its
    /// key, subscribes, and asks.
    Future<void> receiverConnects(BluetoothAdvertising offer) async {
      final key = (await LinkSecret.generate()).publicKey;
      radio.write('phone', BleGatt.control, BleControlProtocol.capabilities());
      radio.write('phone', BleGatt.control, BleControlProtocol.keyExchange(key));
      radio.subscribe('phone', BleGatt.metadata);
      radio.subscribe('phone', BleGatt.data);
      radio.write('phone', BleGatt.control,
          BleControlProtocol.start(offer.code!.sessionToken));
    }

    List<Map<String, Object?>> frames() => [
          for (final n in radio.notificationsOn(BleGatt.metadata))
            jsonDecode(n.text) as Map<String, Object?>,
        ];

    Future<void> until(bool Function() condition, String what) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) fail('never happened: $what');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('a sender that can host raises the network and tells the phone',
        () async {
      final driver = _Driver(canHost: true);
      final b = build(driver);
      final offer = await offerOn(b);

      await receiverConnects(offer);
      await until(() => frames().any((f) => f.containsKey('serve')),
          'the serve frame');

      expect(transports.single.receiverName, isNull,
          reason: 'this is the case under test: no HELLO was written');
      expect(driver.hosted, 1, reason: 'the hotspot was never raised');
      final link = frames().first['link'] as Map;
      expect(link['host'], 'sender');
      expect(link['sealed'], isNotEmpty);
      final serve = frames().last['serve'] as Map;
      expect(serve['ip'], '192.168.137.1');
      expect(serve['port'], 8123);
    });

    test('a sender that cannot host asks the receiver to — it does not give '
        'up because the receiver is not an Apple device', () async {
      final driver = _Driver(canHost: false);
      final b = build(driver);
      final offer = await offerOn(b);

      await receiverConnects(offer);
      await until(() => frames().any((f) => f.containsKey('link')),
          'a directive');

      expect(driver.hosted, 0);
      expect((frames().first['link'] as Map)['host'], 'receiver');
    });

    test('the receiver being an iPhone does not change what an Android or '
        'Windows sender does', () async {
      // The sender only skips the question for an Apple receiver when it can
      // itself use Apple's peer-to-peer link, and these platforms cannot.
      final driver = _Driver(canHost: false);
      final b = build(driver);
      final offer = await offerOn(b);

      radio.write('phone', BleGatt.control, BleControlProtocol.hello("Anna's iPhone"));
      await receiverConnects(offer);
      await until(() => frames().any((f) => f.containsKey('link')),
          'a directive');

      expect(transports.single.receiverName, "Anna's iPhone");
      expect((frames().first['link'] as Map)['host'], 'receiver');
    });
  });

  test('the radio is quiet before anyone scans: no frame without a receiver',
      () async {
    final b = build(_Driver(canHost: true));
    await offerOn(b);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(radio.notificationsOn(BleGatt.metadata), isEmpty);
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_announcer.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class MockBleReceiver extends Mock implements BleReceiver {}
class MockDirectLinkDriver extends Mock implements DirectLinkDriver {}
class MockNetworkInfoService extends Mock implements NetworkInfoService {}
class MockLocalHotspotService extends Mock implements LocalHotspotService {}
class MockReceiverRepository extends Mock implements ReceiverRepository {}
class MockDownloadFileUseCase extends Mock implements DownloadFileUseCase {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockBleReceiver mockTransport;
  late MockDirectLinkDriver mockDriver;
  late MockNetworkInfoService mockNetworkInfo;
  late MockLocalHotspotService mockHotspot;

  late StreamController<BluetoothDevice> devicesController;
  late StreamController<LinkServeInfo> serveController;
  late StreamController<DirectLinkDirective> directiveController;
  late StreamController<BluetoothReceiveProgress> progressController;

  setUpAll(() {
    registerFallbackValue(const QRPayload(
      version: 1,
      ip: '127.0.0.1',
      port: 8080,
      token: 'fallback_token',
    ));
  });

  setUp(() {
    mockTransport = MockBleReceiver();
    mockDriver = MockDirectLinkDriver();
    mockNetworkInfo = MockNetworkInfoService();
    mockHotspot = MockLocalHotspotService();

    devicesController = StreamController<BluetoothDevice>.broadcast();
    serveController = StreamController<LinkServeInfo>.broadcast();
    directiveController = StreamController<DirectLinkDirective>.broadcast();
    progressController = StreamController<BluetoothReceiveProgress>.broadcast();

    when(() => mockTransport.devices).thenAnswer((_) => devicesController.stream);
    when(() => mockTransport.serveInfos).thenAnswer((_) => serveController.stream);
    when(() => mockTransport.linkDirectives).thenAnswer((_) => directiveController.stream);
    when(() => mockTransport.progressStream).thenAnswer((_) => progressController.stream);

    when(() => mockTransport.startScanning(
          sessionToken: any(named: 'sessionToken'),
          publicId: any(named: 'publicId'),
        )).thenAnswer((_) async {});
    when(() => mockTransport.startWaitingAdvertisement(
          deviceName: any(named: 'deviceName'),
        )).thenAnswer((_) async {});
    when(() => mockTransport.stopScanning()).thenAnswer((_) async {});
    when(() => mockTransport.cancel()).thenAnswer((_) async {});
    when(() => mockTransport.connect(
          any(),
          token: any(named: 'token'),
          targetDir: any(named: 'targetDir'),
        )).thenAnswer((_) => Completer<String>().future);

    when(() => mockDriver.canHost).thenReturn(false);
    when(() => mockDriver.canPeerLink).thenReturn(false);
    when(() => mockDriver.ensureWifiReady()).thenAnswer((_) async => true);
    when(() => mockNetworkInfo.getLocalIpAddress()).thenAnswer((_) async => '192.168.1.50');
    when(() => mockHotspot.leaveNetwork()).thenAnswer((_) async => true);
  });

  tearDown(() {
    devicesController.close();
    serveController.close();
    directiveController.close();
    progressController.close();
  });

  test('start advertises so the sender can find this device', () async {
    final announcer = BluetoothReceiverAnnouncer(
      transport: mockTransport,
      driver: mockDriver,
      networkInfo: mockNetworkInfo,
      hotspotService: mockHotspot,
    );

    await announcer.start();
    expect(announcer.isActive, isTrue);

    verify(() => mockTransport.startWaitingAdvertisement(
          deviceName: any(named: 'deviceName'),
        )).called(1);
    verify(() => mockTransport.startScanning(
          sessionToken: any(named: 'sessionToken'),
          publicId: any(named: 'publicId'),
        )).called(1);
    await announcer.stop();
  });

  test('connects to a scanned sender even when the advertised name is missing', () async {
    final announcer = BluetoothReceiverAnnouncer(
      transport: mockTransport,
      driver: mockDriver,
      networkInfo: mockNetworkInfo,
      hotspotService: mockHotspot,
    );

    await announcer.start();

    devicesController.add(const BluetoothDevice(id: 'dev-1', name: 'Unknown device'));
    await pumpEventQueue();
    verify(() => mockTransport.connect(
          'dev-1',
          token: null,
          targetDir: any(named: 'targetDir'),
        )).called(1);

    await announcer.stop();
  });

  test('receiving serve frame notifies onServeReceived with converted QRPayload', () async {
    QRPayload? receivedPayload;
    final announcer = BluetoothReceiverAnnouncer(
      transport: mockTransport,
      driver: mockDriver,
      networkInfo: mockNetworkInfo,
      hotspotService: mockHotspot,
      onServeReceived: (payload) {
        receivedPayload = payload;
      },
    );

    await announcer.start();

    serveController.add(const LinkServeInfo(
      ip: '192.168.1.10',
      port: 8000,
      token: 'secret123',
      tlsFingerprint: 'fingerprint_abc',
    ));
    await pumpEventQueue();

    expect(receivedPayload, isNotNull);
    expect(receivedPayload!.ip, equals('192.168.1.10'));
    expect(receivedPayload!.port, equals(8000));
    expect(receivedPayload!.token, equals('secret123'));
    expect(receivedPayload!.tlsFingerprint, equals('fingerprint_abc'));
    expect(receivedPayload!.mode, equals('http-lan'));

    await announcer.stop();
  });

  test('ReceiverBloc handles BluetoothServeReceived and emits QRParsed', () async {
    final repo = MockReceiverRepository();
    final useCase = MockDownloadFileUseCase();

    when(() => repo.fetchQhtpSessionPreview(any()))
        .thenAnswer((_) async => const Left(ServerFailure('')));

    final bloc = ReceiverBloc(
      downloadFileUseCase: useCase,
      repository: repo,
      bluetoothAnnouncerFactory: ({onServeReceived}) => BluetoothReceiverAnnouncer(
        transport: mockTransport,
        driver: mockDriver,
        networkInfo: mockNetworkInfo,
        hotspotService: mockHotspot,
        onServeReceived: onServeReceived,
      ),
    );

    const payload = QRPayload(
      version: 2,
      ip: '192.168.1.20',
      port: 8000,
      token: 'token999',
      mode: 'http-lan',
      tlsFingerprint: 'tf123',
    );

    bloc.add(const BluetoothServeReceived(payload));

    await expectLater(
      bloc.stream,
      emitsThrough(isA<QRParsed>().having((s) => s.payload, 'payload', equals(payload))),
    );

    await bloc.close();
  });

  test('receiving serve frame with 127.0.0.1 falls back to lanIp if peer link is not established', () async {
    QRPayload? receivedPayload;
    final announcer = BluetoothReceiverAnnouncer(
      transport: mockTransport,
      driver: mockDriver,
      networkInfo: mockNetworkInfo,
      hotspotService: mockHotspot,
      onServeReceived: (payload) {
        receivedPayload = payload;
      },
    );

    await announcer.start();

    serveController.add(const LinkServeInfo(
      ip: '127.0.0.1',
      port: 53317,
      token: 'secret123',
      tlsFingerprint: 'fingerprint_abc',
      lanIp: '192.168.1.45',
    ));
    await pumpEventQueue();

    expect(receivedPayload, isNotNull);
    expect(receivedPayload!.ip, equals('192.168.1.45'));
    expect(receivedPayload!.port, equals(53317));
    expect(receivedPayload!.token, equals('secret123'));

    await announcer.stop();
  });

  test('a waiting-phase progress still starts the direct-link negotiation', () async {
    final announcer = BluetoothReceiverAnnouncer(
      transport: mockTransport,
      driver: mockDriver,
      networkInfo: mockNetworkInfo,
      hotspotService: mockHotspot,
    );

    await announcer.start();

    progressController.add(const BluetoothReceiveProgress(
      phase: 'waiting',
      fileName: '',
      received: 0,
      total: 0,
    ));
    await pumpEventQueue();

    await announcer.stop();
  });
}

// Nothing worked out from a session code goes on the air over Bluetooth.
//
// The radio carries two kinds of thing that anyone in range can read: the
// advertisement (the name an Apple or Linux sender gives itself) and the GATT
// writes and notifications, which cross an unencrypted, unbonded connection. A
// session code is ten digits — about 33 bits — so any value that is a hash of
// one can be run backwards by trying all ten billion in seconds, and the code
// derives the session token, the Wi-Fi network's name and its passphrase.
//
// Until this was written the advertised name was a hash of the code, the link
// directive carried the digits themselves, the sealed credentials were bound to
// a hash of them, and the session token — written as `START:<token>` and
// repeated in the serve frame — was a hash of them too. These tests run the
// real sender (bloc, transport, coordinator) on a simulated radio and look at
// every byte it puts out, with the search an attacker would run.
//
// The last group is the other half: a receiver of the same generation, wired to
// the same simulated radio, still gets the whole way to the file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/crypto/link_secret.dart';
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/hotspot_naming.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/storage/gallery_formats.dart';
import 'package:quickshare/core/storage/receive_destination.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/transfer/ble_control_protocol.dart';
import 'package:quickshare/core/transfer/ble_frame.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/receiver/data/client/isolated_qhtp_receiver.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_session.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_receive_result.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

import '../support/fake_ble.dart';
import '../support/legacy_network_derivation.dart';

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

/// The real transport, with a note of what the bloc asked it to advertise.
///
/// Apple and Linux senders put `QuickShare-<locator>` on the air, and an
/// Android phone or a Windows PC puts nothing there; the locator the bloc hands
/// over is the same on every platform, so it is read here, where it is handed.
class _SpyTransport extends BluetoothTransferTransport {
  String? locator;
  String? token;

  @override
  Future<String> startSharing(FileMetadata file, String token,
      {List<FileMetadata>? files, String locator = ''}) {
    this.locator = locator;
    this.token = token;
    return super.startSharing(file, token, files: files, locator: locator);
  }
}

/// A device that raises a hotspot when asked, and remembers the code it was
/// asked to name it from — the one place a test can see the session's code.
class _Driver implements DirectLinkDriver {
  _Driver({required this.canHost, this.canPeerLink = false});

  @override
  final bool canHost;

  @override
  final bool canPeerLink;

  HotspotCredentials? hosted;
  final List<String> peerLinksHosted = [];
  final List<HotspotCredentials> joined = [];

  @override
  Future<bool> ensureWifiReady() async => true;

  @override
  Future<HotspotCredentials> host() async {
    // What the real driver does: a pair drawn for this network, from nothing.
    final naming = HotspotNaming.generate();
    return hosted = HotspotCredentials(
        ssid: naming.ssid,
        passphrase: naming.passphrase,
        hostAddress: '192.168.137.1');
  }

  @override
  Future<void> joinNetwork(HotspotCredentials credentials) async =>
      joined.add(credentials);

  @override
  Future<void> stopHosting() async {}

  @override
  Future<void> leaveNetwork() async {}

  @override
  Future<void> hostPeerLink(String serviceName, int localPort) async =>
      peerLinksHosted.add(serviceName);

  @override
  Future<int> joinPeerLink(String serviceName) async => 4242;

  @override
  Future<void> stopPeerLink() async {}
}

/// Everything a session put where a listener could read it.
class _OnAir {
  _OnAir({
    required this.qr,
    required this.advertisedNames,
    required this.writes,
    required this.frames,
  });

  /// The QR as scanned: token and locator, which then travel in the clear.
  final BluetoothQrPayload qr;

  /// What each kind of sender names itself. Android and Windows: nothing.
  final List<String> advertisedNames;

  /// What the receiver wrote to the control characteristic.
  final List<String> writes;

  /// What the sender notified on the metadata characteristic, as text.
  final List<String> frames;

  List<String> get everything => [...advertisedNames, ...writes, ...frames];
}

/// Every value a session code derives, by what it is — including the network
/// name and passphrase it used to name, which the app no longer derives from
/// anything (see test/support/legacy_network_derivation.dart).
Map<String, String> _derivedFrom(SessionCode code) {
  final network = legacyNetworkOf(code.code);
  return {
    'the digits': code.code,
    'the digits, spaced': code.display,
    'the public id': code.publicId,
    'the session token': code.sessionToken,
    'the network name the code used to name': network.ssid,
    'the network name without its prefix':
        network.ssid.substring(HotspotNaming.ssidPrefix.length),
    'the passphrase the code used to derive': network.passphrase,
    'the peer-link name': PeerLinkService.serviceNameFor(code.sessionToken),
  };
}

/// What an eavesdropper does with a value read off the air: hash every code,
/// keep the one it matches.
///
/// All ten billion take seconds on a laptop and a minute here, so the search is
/// the part of the space that holds the real code — the ones that share its
/// first five digits, a hundred thousand. The result is the same, only the
/// size of the haystack differs. A value that matches nothing in a haystack
/// that is known to contain the code cannot be searched for it.
SessionCode? _recover(Iterable<String> read, String firstFiveDigits) {
  final air = read.join('\n').toLowerCase();
  for (final digits in codesStartingWith(firstFiveDigits)) {
    final candidate = SessionCode(digits);
    final network = legacyNetworkOf(digits);
    final hashes = [
      candidate.publicId,
      candidate.sessionToken,
      network.passphrase,
      network.ssid,
      PeerLinkService.serviceNameFor(candidate.sessionToken),
    ];
    if (hashes.any((h) => air.contains(h.toLowerCase()))) return candidate;
  }
  return null;
}


/// The sender's radio, wired to the receiver's: whatever the sender notifies
/// the receiver hears, as a central would.
class _LinkedPeripheral extends FakeBlePeripheral {
  _LinkedPeripheral(this.central);

  final FakeBleCentral central;

  @override
  Future<void> updateCharacteristicValue({
    required String characteristicId,
    required Uint8List value,
    String? deviceId,
  }) async {
    await super.updateCharacteristicValue(
        characteristicId: characteristicId, value: value, deviceId: deviceId);
    // Like a real link: what does not fit the negotiated size is cut to it,
    // silently. A sender that sent a frame whole to a small link would deliver
    // half a document here, as it would on a phone.
    final carried = maxNotifyLength ?? 20;
    central.notifyBytes('peer', characteristicId,
        value.length > carried ? value.sublist(0, carried) : value);
  }
}

/// The receiver's radio, wired to the sender's: what the receiver writes and
/// subscribes to reaches the sender's GATT server.
class _LinkedCentral extends FakeBleCentral {
  FakeBlePeripheral? server;

  @override
  Future<void> writeValue(String deviceId, String service, String characteristic,
      Uint8List value, BleOutputProperty bleOutputProperty) async {
    await super.writeValue(
        deviceId, service, characteristic, value, bleOutputProperty);
    server!.write(deviceId, characteristic, String.fromCharCodes(value));
  }

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    await super.setNotifiable(
        deviceId, service, characteristic, bleInputProperty);
    if (bleInputProperty != BleInputProperty.disabled) {
      server!.subscribe(deviceId, characteristic);
    }
  }
}

/// Stops where the file would start to move, and keeps what it was told.
class _CapturingQhtp extends IsolatedQhtpReceiver {
  QRPayload? pulledWith;

  @override
  Future<Either<Failure, QhtpReceiveResult>> downloadSession({
    required QRPayload payload,
    required String targetBaseDir,
    void Function(QhtpProgress progress)? onProgress,
  }) async {
    pulledWith = payload;
    return Right(QhtpReceiveResult(
        preferredResultPath: targetBaseDir, displayName: 'offer.bin'));
  }
}

class _FakeNetworkInfo extends NetworkInfoService {
  @override
  Future<String?> getLocalIpAddress() async => '192.168.137.2';
}

class _FakeHotspot extends LocalHotspotService {
  @override
  Future<void> leaveNetwork() async {}
}

void main() {
  late FakeBlePeripheral radio;
  late FakeBleCentral central;
  late Directory scratch;
  late List<_SpyTransport> transports;
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
    scratch = Directory.systemTemp.createTempSync('ble_nothing_from_code');
    File('${scratch.path}/offer.bin').writeAsBytesSync([1, 2, 3, 4, 5]);
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
    when(() => repository.sessionTlsFingerprint)
        .thenReturn('ppyVDnOklxV6jThfz6nwYkm7r_rGePi0X5ULmV_k2qY');
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
    when(hotspot.leaveNetwork).thenAnswer((_) async {});

    return bloc = SenderBloc(
      repository: repository,
      hotspotService: hotspot,
      peerLinkService: const _SilentPeerLink(),
      directLinkDriver: driver,
      diagnostics: const _NoDiagnostics(),
      bluetoothTransportFactory: () {
        final t = _SpyTransport();
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

  /// Every negotiation frame the sender completed, as text.
  List<String> frames() => radio.framesOn(BleGatt.metadata);

  /// Waits for a condition, not for a time: polls the radio until [condition]
  /// holds, and fails with [what] if it never does.
  Future<void> until(bool Function() condition, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('never happened: $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// A phone scans the QR and does what a phone does, as the receiver writes it:
  /// says what it can take, hands over its key, subscribes, and asks.
  Future<List<String>> phoneConnects(BluetoothQrPayload qr) async {
    final key = (await LinkSecret.generate()).publicKey;
    final writes = [
      BleControlProtocol.capabilities(),
      BleControlProtocol.keyExchange(key),
      BleControlProtocol.start(qr.token),
    ];
    radio.write('phone', BleGatt.control, writes[0]);
    radio.write('phone', BleGatt.control, writes[1]);
    radio.subscribe('phone', BleGatt.metadata);
    radio.subscribe('phone', BleGatt.data);
    radio.write('phone', BleGatt.control, writes[2]);
    return writes;
  }

  /// One session, from the QR to the serve frame, and everything it said.
  Future<({_OnAir air, BluetoothAdvertising offer})> sessionOn(
      _Driver driver) async {
    final b = build(driver);
    final offer = await offerOn(b);
    final qr = BluetoothQrPayload.tryDecode(offer.qrData)!;
    final writes = await phoneConnects(qr);
    await until(() => frames().any((f) => f.contains('"serve"')),
        'the serve frame');

    final spy = transports.single;
    return (
      offer: offer,
      air: _OnAir(
        qr: qr,
        // An Apple or Linux sender names itself from the locator the bloc
        // handed over (the contract test holds the Swift and BlueZ code to
        // that); an Android phone or a Windows PC advertises no name.
        advertisedNames: [
          BleAdvertisement.nameFor(spy.locator!),
          if (radio.advertised.single.localName != null)
            radio.advertised.single.localName!,
        ],
        writes: writes,
        frames: frames(),
      ),
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    group('a sender on ${platform.name}', () {
      setUp(() => debugDefaultTargetPlatformOverride = platform);

      test('puts nothing on the air that a code derives, nor the network it '
          'raised', () async {
        final driver = _Driver(canHost: true);
        final session = await sessionOn(driver);
        final air = session.air;
        // There is no code in a Bluetooth session. These are the values a code
        // would derive, for a code picked to stand in for any: none of them is
        // anywhere the radio carries.
        final code = SessionCode.generate();

        expect(air.frames.length, greaterThanOrEqualTo(2),
            reason: 'the test has to have seen the directive and the serve '
                'frame');
        for (final entry in _derivedFrom(code).entries) {
          for (final text in air.everything) {
            expect(text.toLowerCase(), isNot(contains(entry.value.toLowerCase())),
                reason: '${entry.key} is on the air, in: $text');
          }
        }
        // And the real network's name and passphrase cross sealed, never as
        // themselves.
        for (final secret in [driver.hosted!.ssid, driver.hosted!.passphrase]) {
          for (final text in air.everything) {
            expect(text, isNot(contains(secret)),
                reason: 'the network that was raised is readable off the air');
          }
        }
      });

      test('cannot be searched for a code, by anything it says', () async {
        final driver = _Driver(canHost: true);
        final session = await sessionOn(driver);
        // The search an eavesdropper runs over the part of the code space that
        // holds a code. Which code does not matter: nothing the session says is
        // a function of one, so no choice of haystack has an answer in it.
        const firstFive = '40817';

        // The control: the value this used to advertise. Searching for it finds
        // the code, which is what makes the empty answer below mean something.
        const code = SessionCode('4081726359');
        final old = _recover(['QuickShare-${code.publicId}'], firstFive);
        expect(old, code,
            reason: 'the search has to work on the old value, or it proves '
                'nothing about the new one');
        final oldNetwork = _recover([legacyNetworkOf(code.code).ssid], firstFive);
        expect(oldNetwork, code,
            reason: 'and on the network name the code used to name');

        expect(_recover(session.air.everything, firstFive), isNull,
            reason: 'a value on the air led back to a code');
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('names itself, to the receiver that scanned the QR, with a value '
          'that has nothing to do with a code', () async {
        final driver = _Driver(canHost: true);
        final session = await sessionOn(driver);
        final qr = session.air.qr;

        expect(qr.locator, hasLength(BleAdvertisement.locatorLength));
        expect(BleAdvertisement.nameFor(qr.locator), 'QuickShare-${qr.locator}');
        expect(transports.single.locator, qr.locator,
            reason: 'what is on the air is what the QR hands to the receiver');
        expect(session.offer.locator, qr.locator);
      });

      test('uses the token it advertises for the transfer', () async {
        final driver = _Driver(canHost: true);
        final session = await sessionOn(driver);
        final serve = (jsonDecode(
            frames().firstWhere((f) => f.contains('"serve"')))['serve'] as Map);

        expect(serve['token'], session.air.qr.token,
            reason: 'one session, one token: the one in the QR, the one the '
                'receiver wrote in START, the one it pulls with');
      });

      test('raises a different network every time, whatever the session',
          () async {
        final first = _Driver(canHost: true);
        await sessionOn(first);
        final firstNetwork = first.hosted!;
        await bloc?.close();
        bloc = null;
        transports.clear();
        radio.notifications.clear();
        radio.advertised.clear();

        final second = _Driver(canHost: true);
        await sessionOn(second);

        expect(second.hosted!.ssid, isNot(firstNetwork.ssid));
        expect(second.hosted!.passphrase, isNot(firstNetwork.passphrase));
      });
    });
  }

  // Ten digits that stand alone, as a code would in a JSON value. Not any ten
  // digits in a row: the token is 32 random hex characters, and a run of ten
  // decimal digits turns up inside one in about every fifth session.
  final tenDigitsStandingAlone =
      RegExp(r'(?<![0-9a-fA-F])\d{10}(?![0-9a-fA-F])');

  group('every shape the link directive takes', () {
    test('the sender hosts: the sealed credentials and a key, and no digits',
        () async {
      final driver = _Driver(canHost: true);
      await sessionOn(driver);

      final link = jsonDecode(frames().first)['link'] as Map;
      expect(link.keys.toSet(), {'host', 'sealed', 'kex'});
      expect(link['host'], 'sender');
    });

    test('the receiver is asked to host: a key and nothing else', () async {
      final driver = _Driver(canHost: false);
      final b = build(driver);
      final offer = await offerOn(b);
      await phoneConnects(BluetoothQrPayload.tryDecode(offer.qrData)!);
      await until(() => frames().any((f) => f.contains('"link"')),
          'the directive');

      final link = jsonDecode(frames().first)['link'] as Map;
      expect(link.keys.toSet(), {'host', 'kex'});
      expect(link['host'], 'receiver');
      expect(link.containsKey('code'), isFalse);
      expect(frames().join(), isNot(matches(tenDigitsStandingAlone)),
          reason: 'ten digits in a row anywhere on the air');
    });

    test('an Apple pair: the name of the peer-to-peer link, made from the '
        'locator and not from the token', () async {
      final driver = _Driver(canHost: false, canPeerLink: true);
      final b = build(driver);
      final offer = await offerOn(b);
      final qr = BluetoothQrPayload.tryDecode(offer.qrData)!;
      await phoneConnects(qr);
      await until(() => driver.peerLinksHosted.isNotEmpty && frames().length >= 3,
          'the peer-link directive');

      final directive = frames()
          .map(jsonDecode)
          .whereType<Map>()
          .map((f) => f['link'])
          .whereType<Map>()
          .lastWhere((l) => l['host'] == 'peerlink');
      expect(directive.keys.toSet(), {'host', 'kex', 'service'});
      expect(directive['service'], PeerLinkService.serviceNameFor(qr.locator));
      expect(directive['service'],
          isNot(PeerLinkService.serviceNameFor(qr.token)),
          reason: 'it is announced to the whole network, and read in the clear '
              'here');
      expect(frames().join(), isNot(matches(tenDigitsStandingAlone)));
    });
  });

  group('between old and new', () {
    test('a receiver of the generation before is told to update, at once, and '
        'is not sent a directive it could not open', () async {
      final driver = _Driver(canHost: true);
      final b = build(driver);
      final offer = await offerOn(b);
      final qr = BluetoothQrPayload.tryDecode(offer.qrData)!;

      final failed = b.stream
          .firstWhere((s) => s is SenderError)
          .timeout(const Duration(seconds: 20));
      final key = (await LinkSecret.generate()).publicKey;
      radio.write('phone', BleGatt.control, 'CAPS:4');
      radio.write('phone', BleGatt.control, BleControlProtocol.keyExchange(key));
      radio.subscribe('phone', BleGatt.metadata);
      radio.subscribe('phone', BleGatt.data);
      radio.write('phone', BleGatt.control, BleControlProtocol.start(qr.token));

      final error = await failed as SenderError;
      expect(error.code, FailureCode.receiverTooOldForDirectLink);
      expect(error.message, BleControlProtocol.directLinkRequiredMessage);
      expect(frames(), isEmpty,
          reason: 'nothing was negotiated with a peer that cannot take part');
      expect(driver.hosted, isNull, reason: 'no network was raised for it');
    });

    test('and one that said nothing at all is refused the same way', () async {
      final b = build(_Driver(canHost: true));
      final offer = await offerOn(b);
      final qr = BluetoothQrPayload.tryDecode(offer.qrData)!;

      final failed = b.stream
          .firstWhere((s) => s is SenderError)
          .timeout(const Duration(seconds: 20));
      radio.subscribe('phone', BleGatt.metadata);
      radio.subscribe('phone', BleGatt.data);
      radio.write('phone', BleGatt.control, BleControlProtocol.start(qr.token));

      expect(((await failed) as SenderError).code,
          FailureCode.receiverTooOldForDirectLink);
    });
  });

  group('a receiver of the same generation, on the same radio', () {
    late _LinkedCentral linkedCentral;
    late Directory inbox;

    setUp(() {
      linkedCentral = _LinkedCentral();
      final linked = _LinkedPeripheral(linkedCentral);
      linkedCentral.server = linked;
      radio = linked;
      central = linkedCentral;
      UniversalBlePeripheral.setInstance(linked);
      UniversalBle.setInstance(linkedCentral);
      inbox = Directory.systemTemp.createTempSync('ble_exchange_inbox');
    });

    tearDown(() => inbox.deleteSync(recursive: true));

    Future<ReceiveDestination> cacheDestination() => ReceiveDestination.resolve(
          destination: const SaveDestination(
              isDesktop: false, gallery: GalleryFormats(GalleryPlatform.ios)),
          cache: TransferCache(overrideRoot: () => inbox),
        );

    /// The receiver, built the way the app builds it, on the radio above.
    ({BluetoothReceiverSession session, _CapturingQhtp qhtp, _Driver driver})
        receiver({bool canHost = false}) {
      final qhtp = _CapturingQhtp();
      final driver = _Driver(canHost: canHost);
      return (
        session: BluetoothReceiverSession(
          transport: BluetoothReceiverTransport.forPlatform(),
          driver: driver,
          networkInfo: _FakeNetworkInfo(),
          hotspotService: _FakeHotspot(),
          qhtpReceiver: qhtp,
        ),
        qhtp: qhtp,
        driver: driver,
      );
    }

    // The same exchange over every size of link there is: one that carries a
    // whole frame (512), an iPhone's (182) and one nobody negotiated (20). The
    // frames are cut to what the link carries, so one that was sent whole
    // arrives as half a document and the exchange does not finish.
    for (final limit in [512, 182, 20]) {
      group('over a link that carries $limit', () {
        setUp(() => radio.maxNotifyLength = limit);

        test('the sender hosts: the receiver opens what was sealed, joins that '
            'network, and is told where the file is', () async {
          final sender = _Driver(canHost: true);
          final b = build(sender);
          final offer = await offerOn(b);
          final qr = BluetoothQrPayload.tryDecode(offer.qrData)!;

          final r = receiver();
          final running = r.session.run(
            token: qr.token,
            locator: qr.locator,
            destination: await cacheDestination(),
            onProgress: (_, __, ___) {},
            onVerifying: () {},
          );
          // The receiver scans for the service, and the OS hands it the sender.
          // Android and Windows senders advertise no name.
          await until(() => central.scans.isNotEmpty, 'the scan');
          central.discover(
              id: 'peer',
              name: radio.advertised.single.localName,
              services: radio.advertised.single.services);

          final result = await running.timeout(const Duration(seconds: 30));

          expect(result.displayName, 'offer.bin');
          // The receiver joined exactly the network the sender raised: the
          // credentials crossed sealed, were opened against the locator from the
          // QR, and nothing about the code was sent for it to work them out from.
          expect(r.driver.joined.single.ssid, sender.hosted!.ssid);
          expect(r.driver.joined.single.passphrase, sender.hosted!.passphrase);
          // And it pulls with the QR's token, from where the serve frame said.
          final pulled = r.qhtp.pulledWith!;
          expect(pulled.token, qr.token);
          expect(pulled.ip, '192.168.137.1');
          expect(pulled.port, 8123);
          expect(pulled.tlsFingerprint, 'ppyVDnOklxV6jThfz6nwYkm7r_rGePi0X5ULmV_k2qY');
          // And none of it is a code's: the network the sender raised appears on
          // the air only sealed.
          expect(frames().join(), isNot(contains(sender.hosted!.ssid)));
          expect(frames().join(), isNot(contains(sender.hosted!.passphrase)));
        });

        test('the receiver is asked to host: it raises a network of its own, '
            'named from a code that is not the sender\'s, and the sender joins',
            () async {
          final sender = _Driver(canHost: false);
          final b = build(sender);
          final offer = await offerOn(b);
          final qr = BluetoothQrPayload.tryDecode(offer.qrData)!;

          final r = receiver(canHost: true);
          final running = r.session.run(
            token: qr.token,
            locator: qr.locator,
            destination: await cacheDestination(),
            onProgress: (_, __, ___) {},
            onVerifying: () {},
          );
          await until(() => central.scans.isNotEmpty, 'the scan');
          central.discover(
              id: 'peer',
              name: radio.advertised.single.localName,
              services: radio.advertised.single.services);

          final result = await running.timeout(const Duration(seconds: 30));

          expect(result.displayName, 'offer.bin');
          // The sender found the credentials the receiver offered, sealed, and
          // joined that network: the offer was opened against the same locator.
          expect(sender.joined.single.ssid, r.driver.hosted!.ssid);
          expect(sender.joined.single.passphrase, r.driver.hosted!.passphrase);
          expect(r.driver.hosted, isNotNull,
              reason: 'it raised a network of its own when asked to');
          expect(frames().join(), isNot(contains(r.driver.hosted!.passphrase)),
              reason: 'and never said its passphrase in the clear');
          expect(r.qhtp.pulledWith!.token, qr.token);
          expect(frames().first, contains('"host":"receiver"'));
        });
      });
    }

    test('a sender of the generation before is told to update, at once, and '
        'the negotiation is not left to run out', () async {
      // What a generation-4 sender sends first: the directive with the digits.
      final r = receiver();
      final running = r.session.run(
        token: 'a-token',
        locator: 'K3M9Q2TV',
        destination: await cacheDestination(),
        onProgress: (_, __, ___) {},
        onVerifying: () {},
      );
      // The sender is stood in for by a bare GATT server that answers the
      // handshake and then sends what an older build sent.
      radio.writeHandler ??= (_, __, ___, ____) => PeripheralWriteRequestResult();
      await until(() => central.scans.isNotEmpty, 'the scan');
      central.discover(
          id: 'peer', name: null, services: [BleGatt.service]);
      await until(() => central.subscribed.length >= 2, 'the subscriptions');
      central.notifyFrame(
          'peer',
          BleGatt.metadata,
          jsonEncode({
            'link': {
              'host': 'receiver',
              'kex': 'ZmFrZS1rZXktZm9yLXRoZS10ZXN0LTEyMzQ1Njc4OTA=',
              'code': '0123456789',
            }
          }));

      await expectLater(
        running.timeout(const Duration(seconds: 10)),
        throwsA(isA<FileException>().having(
            (e) => e.code, 'code', FailureCode.senderTooOldForDirectLink)),
      );
      expect(r.driver.joined, isEmpty);
    });
  });

  group('how big each frame is', () {
    // The numbers the owner asked for, measured on the real objects rather than
    // worked out by hand. An iPhone negotiates a 185-byte ATT MTU, which holds
    // 182 bytes of a notification; Android before 14 holds 20 until the central
    // asks for more. A frame longer than that crosses as parts, each of which
    // fits — see `BleFrame`.
    const iPhone = 182;

    Future<int> bytes(Map<String, Object?> frame) async =>
        utf8.encode(jsonEncode(frame)).length;

    /// How many notifications of at most [limit] bytes carry a frame of [size].
    int partsFor(int size, int limit) =>
        (size + (limit - BleFrame.headerBytes) - 1) ~/
        (limit - BleFrame.headerBytes);

    Future<DirectLinkDirective> sealedFrom(String ssid, String passphrase) async {
      final sender = await LinkSecret.generate();
      final receiver = await LinkSecret.generate();
      return DirectLinkDirective.hostBySender(
        sealedCredentials: await sender.seal(
            ssid: ssid,
            passphrase: passphrase,
            sessionId: 'K3M9Q2TV',
            peerPublicKey: receiver.publicKey),
        senderPublicKey: sender.publicKey,
      );
    }

    test('what each frame comes to, and in how many parts', () async {
      final key = (await LinkSecret.generate()).publicKey;
      final hotspot = HotspotNaming.generate();
      final frames = <String, Map<String, Object?>>{
        'link, sender hosts (Windows/Linux hotspot name)': {
          'link': (await sealedFrom(hotspot.ssid, hotspot.passphrase)).toJson()
        },
        'link, sender hosts (Android-style name)': {
          'link': (await sealedFrom('AndroidShare_4821', 'X7K29DMQ41ZT'))
              .toJson()
        },
        'link, receiver is asked to host': {
          'link': DirectLinkDirective.hostByReceiver(senderPublicKey: key)
              .toJson()
        },
        'link, Apple peer-to-peer': {
          'link': DirectLinkDirective.overPeerLink(
                  serviceName: 'dd-K3M9Q2TV', senderPublicKey: key)
              .toJson()
        },
        'serve, every field': {
          'serve': const LinkServeInfo(
            ip: '192.168.137.1',
            port: 54321,
            token: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
            tlsFingerprint: 'ppyVDnOklxV6jThfz6nwYkm7r_rGePi0X5ULmV_k2qY',
            fileName: 'Vacation photos',
            fileSize: 123456789,
            itemCount: 12,
            senderName: "Farman's PC",
            lanIp: '192.168.1.10',
          ).toJson()
        },
        'serve, only what a receiver needs': {
          'serve': const LinkServeInfo(
            ip: '192.168.137.1',
            port: 54321,
            token: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
            tlsFingerprint: 'ppyVDnOklxV6jThfz6nwYkm7r_rGePi0X5ULmV_k2qY',
          ).toJson()
        },
      };
      final sizes = {
        for (final e in frames.entries) e.key: await bytes(e.value),
      };
      // ignore: avoid_print
      sizes.forEach((name, size) => print(
          'FRAME_BYTES $size  parts@182=${partsFor(size, iPhone)} '
          'parts@20=${partsFor(size, 20)}  $name'));

      // Every one of them fits the frame limit with room to spare, and the
      // ones that were refused or cut before now cross whole.
      for (final size in sizes.values) {
        expect(size, lessThan(BleFrame.maxFrameBytes ~/ 8));
        expect(partsFor(size, 20), lessThanOrEqualTo(BleFrame.maxParts));
      }
      expect(sizes['serve, every field']!, greaterThan(iPhone));
      expect(partsFor(sizes['serve, every field']!, iPhone), 2);
    });

    test('the directive that carries the credentials is 203 bytes with a '
        '12-character passphrase, and crosses an iPhone in two parts',
        () async {
      // It was 223 with the ten digits in it (`"code":"4081726359",` is 20
      // bytes). The digits are gone; the rest is the sealed pair and a key,
      // which cannot be dropped. A Windows PC, Linux machine or Android phone
      // that hosts and is received by an iPhone is the pairing this affects.
      final frame = {
        'link': (await sealedFrom(
                HotspotNaming.generate().ssid, 'X7K29DMQ41ZT'))
            .toJson()
      };
      final size = await bytes(frame);

      expect(size, 203);
      expect(size + utf8.encode(',"code":"4081726359"').length, 223);
      expect(size, greaterThan(iPhone));
      expect(partsFor(size, iPhone), 2);
    });

    test('a sender sends it to a notification that cannot hold it, in parts',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      radio.maxNotifyLength = iPhone;
      final b = build(_Driver(canHost: true));
      await offerOn(b);
      radio.subscribe('phone', BleGatt.data);
      await Future<void>.delayed(Duration.zero);
      final before = radio.notifications.length;
      final frame = {
        'link': (await sealedFrom(
                HotspotNaming.generate().ssid, 'X7K29DMQ41ZT'))
            .toJson()
      };

      await transports.single.sendLinkFrame(frame);

      expect(radio.notifications.length - before, 2);
      expect(radio.partsOn(BleGatt.metadata).map((p) => p.length),
          everyElement(lessThanOrEqualTo(iPhone)));
      expect(frames().last, jsonEncode(frame),
          reason: 'put back together it is what was sent, whole');
    });
  });
}

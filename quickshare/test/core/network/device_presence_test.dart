import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/device_presence.dart';
import 'package:quickshare/core/network/lan_discovery.dart';

/// Stands in for the socket half, so what this device *says* can be checked
/// without anything being sent.
class _RecordingDiscovery extends LanDiscoveryService {
  final List<DiscoveryAnnouncement> announced = [];
  bool startSucceeds = true;
  bool _running = false;

  /// When set, start waits on it — so a test can hold a start in flight and
  /// see what a second caller does meanwhile.
  Completer<void>? startGate;

  @override
  bool get isRunning => _running;

  @override
  Future<bool> start(DiscoveryAnnouncement self) async {
    final gate = startGate;
    if (gate != null) await gate.future;
    announced.add(self);
    _running = startSucceeds;
    return startSucceeds;
  }

  @override
  Future<void> update(DiscoveryAnnouncement self) async => announced.add(self);

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late _RecordingDiscovery discovery;
  late DevicePresence presence;

  setUp(() {
    discovery = _RecordingDiscovery();
    presence = DevicePresence(discovery: discovery);
  });

  tearDown(() async {
    // A start with a prompt binds a real socket; leaving it open would keep
    // the test isolate alive.
    await presence.dispose();
  });

  group('what this device says about itself', () {
    test('announces a name, a platform, and no port until it serves one',
        () async {
      await presence.start(name: 'Test Machine');

      final said = discovery.announced.single;
      expect(said.name, equals('Test Machine'));
      expect(said.platform, equals(Platform.operatingSystem));
      expect(said.port, isZero,
          reason: 'present is not the same as offering a transfer');
      expect(said.tlsFingerprint, isEmpty);
    });

    test('the identifier is new every launch', () async {
      // A persistent one would let anyone in radio range of two networks tell
      // that the same machine was on both. The list only needs to be stable
      // while it is on screen.
      final firstDiscovery = _RecordingDiscovery();
      final secondDiscovery = _RecordingDiscovery();
      await DevicePresence(discovery: firstDiscovery).start(name: 'A');
      await DevicePresence(discovery: secondDiscovery).start(name: 'B');

      expect(
        firstDiscovery.announced.single.id,
        isNot(equals(secondDiscovery.announced.single.id)),
      );
    });

    test('the identifier is stable across announcements', () async {
      await presence.start(name: 'Test Machine');
      presence.nowServing(port: 8000, tlsFingerprint: 'abc');
      presence.noLongerServing();

      final ids = discovery.announced.map((a) => a.id).toSet();
      expect(ids, hasLength(1),
          reason: 'a device heard three times is one row, not three');
    });
  });

  group('serving', () {
    test('gaining a session adds what it takes to dial it', () async {
      await presence.start(name: 'Test Machine');
      presence.nowServing(port: 8000, tlsFingerprint: 'fingerprint');

      final said = discovery.announced.last;
      expect(said.port, equals(8000));
      expect(said.tlsFingerprint, equals('fingerprint'));
      expect(said.name, equals('Test Machine'),
          reason: 'the rest of the identity does not change with the session');
    });

    test('ending a session leaves the device listed, just not serving',
        () async {
      await presence.start(name: 'Test Machine');
      presence.nowServing(port: 8000, tlsFingerprint: 'fingerprint');
      presence.noLongerServing();

      final said = discovery.announced.last;
      expect(said.port, isZero);
      expect(said.tlsFingerprint, isEmpty);
      expect(said.name, equals('Test Machine'));
    });

    test('ending a session that never started says nothing new', () async {
      await presence.start(name: 'Test Machine');
      presence.noLongerServing();

      expect(discovery.announced, hasLength(1),
          reason: 'an announcement that repeats itself is wasted airtime');
    });

    test('serving before starting is ignored rather than crashing', () {
      // The order is the caller's business, and a screen torn down mid-session
      // can get here.
      expect(() => presence.nowServing(port: 8000, tlsFingerprint: 'x'),
          returnsNormally);
      expect(discovery.announced, isEmpty);
    });
  });

  group('start', () {
    test('reports a network that will not carry announcements', () async {
      // Guest Wi-Fi and captive portals block multicast. The screen has to
      // know, because an empty list then means "we cannot look here" rather
      // than "nobody is nearby".
      discovery.startSucceeds = false;
      expect(await presence.start(name: 'Test Machine'), isFalse);
    });
  });

  group('a repeated start', () {
    test('keeps the invitation port in the announcement', () async {
      // Every screen with a device list calls start on the shared presence,
      // and none of them passes a prompt — the shared one already has it. A
      // repeat rebuilding the announcement without it dropped the port while
      // the listener kept listening, and senders saw a device they could not
      // ask.
      await presence.start(
          name: 'Test Machine', onInvitation: (_, __) async => true);
      final port = discovery.announced.single.invitePort;
      expect(port, greaterThan(0),
          reason: 'a device with a prompt is one that can be asked');

      expect(await presence.start(), isTrue);

      expect(discovery.announced.single.invitePort, equals(port),
          reason: 'the first start owns the announcement');
    });

    test('on a running discovery says nothing new', () async {
      await presence.start(name: 'Test Machine');

      expect(await presence.start(name: 'Test Machine'), isTrue);

      expect(discovery.announced, hasLength(1),
          reason: 'an announcement that repeats itself is wasted airtime');
    });

    test('one already in flight is joined, not run twice', () async {
      // A screen can appear while the app's own start is still waiting on the
      // platform — a deep link lands on the code-entry page straight away. A
      // second start must not race the first into publishing twice.
      discovery.startGate = Completer<void>();

      final first = presence.start(name: 'Test Machine');
      final second = presence.start(name: 'A Different Name');

      discovery.startGate!.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);

      expect(discovery.announced, hasLength(1));
      expect(discovery.announced.single.name, equals('Test Machine'),
          reason: 'the first call owns the announcement');
    });

    test('while discovery is down retries with the same announcement',
        () async {
      discovery.startSucceeds = false;
      expect(
          await presence.start(
              name: 'Test Machine', onInvitation: (_, __) async => true),
          isFalse);

      discovery.startSucceeds = true;
      expect(await presence.start(), isTrue);

      expect(discovery.announced, hasLength(2));
      expect(discovery.announced.last.id, equals(discovery.announced.first.id),
          reason: 'a retry is the same device, not a new one');
      expect(discovery.announced.last.invitePort,
          equals(discovery.announced.first.invitePort),
          reason: 'the invitation port survives the retry');
    });
  });

  group('describeThisDevice', () {
    test('is something a person would recognise in a list', () {
      final name = DevicePresence.describeThisDevice();

      expect(name, isNotEmpty);
      expect(name, isNot(endsWith('.local')),
          reason: 'Bonjour puts that there; nobody thinks of it as the name');
    });
  });
}

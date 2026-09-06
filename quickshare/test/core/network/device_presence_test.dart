import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/device_presence.dart';
import 'package:quickshare/core/network/lan_discovery.dart';

/// Stands in for the socket half, so what this device *says* can be checked
/// without anything being sent.
class _RecordingDiscovery extends LanDiscoveryService {
  final List<DiscoveryAnnouncement> announced = [];
  bool startSucceeds = true;

  @override
  Future<bool> start(DiscoveryAnnouncement self) async {
    announced.add(self);
    return startSucceeds;
  }

  @override
  void update(DiscoveryAnnouncement self) => announced.add(self);

  @override
  Future<void> stop() async {}

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

  group('describeThisDevice', () {
    test('is something a person would recognise in a list', () {
      final name = DevicePresence.describeThisDevice();

      expect(name, isNotEmpty);
      expect(name, isNot(endsWith('.local')),
          reason: 'Bonjour puts that there; nobody thinks of it as the name');
    });
  });
}

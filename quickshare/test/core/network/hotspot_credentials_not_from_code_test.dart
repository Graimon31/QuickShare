// What a device that raises a network puts on the air, and what comes back.
//
// A network's name is broadcast in the clear. It used to be a hash of the
// session code, and so was the passphrase: anybody in range read the name, tried
// the ten billion codes against it (about thirty of the code's thirty-three bits
// are in it, so a handful matched), and had the passphrase. These raise a
// network through the real service, on each platform's path, read what it was
// told to use, and run that search.
//
// The control is the old scheme, searched the same way: it finds its code. That
// is what makes finding nothing mean something.
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/hotspot_naming.dart';
import 'package:quickshare/core/network/linux_hotspot.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';

import '../../support/legacy_network_derivation.dart';

/// Records what NetworkManager is asked to raise.
class _FakeLinux extends LinuxHotspot {
  _FakeLinux() : super(runner: _never);

  static Future<ProcessResult> _never(String _, List<String> __) =>
      throw StateError('no shell here');

  final List<({String ssid, String passphrase})> raised = [];

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> get canHost async => true;

  @override
  Future<void> start(
      {required String ssid,
      required String passphrase,
      String? interfaceName}) async {
    raised.add((ssid: ssid, passphrase: passphrase));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('quickshare/hotspot');
  final asked = <MethodCall>[];

  /// What the platform answers to `startHotspot`: Windows echoes what it was
  /// told, Android answers with a network it named itself.
  Map<String, Object?> Function(Map args) answer = (args) => {
        'ssid': args['ssid'],
        'passphrase': args['passphrase'],
      };

  setUp(() {
    asked.clear();
    answer = (args) => {'ssid': args['ssid'], 'passphrase': args['passphrase']};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      asked.add(call);
      if (call.method == 'startHotspot') return answer(call.arguments as Map);
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  /// The service on [os], not waiting for a network interface that a test
  /// machine will never grow.
  LocalHotspotService serviceOn(String os, {Random? random, LinuxHotspot? linux}) =>
      LocalHotspotService(
          channel: channel,
          operatingSystem: os,
          random: random,
          linux: linux,
          addressAttempts: 1,
          addressInterval: Duration.zero);

  LocalHotspotService windows([Random? random]) =>
      serviceOn('windows', random: random);

  Map startedWith() => asked.singleWhere((c) => c.method == 'startHotspot')
      .arguments as Map;

  group('the search an eavesdropper runs', () {
    // Every ten-digit code that starts with five known digits: a hundred
    // thousand of the ten billion, hashed once. The answer is the same as for
    // all of them; only the haystack is smaller.
    const firstFive = '40817';
    late Map<String, String> codeByLegacyName;
    late Set<String> legacyPassphrases;

    setUpAll(() {
      codeByLegacyName = {};
      legacyPassphrases = {};
      for (final code in codesStartingWith(firstFive)) {
        final network = legacyNetworkOf(code);
        codeByLegacyName[network.ssid] = code;
        legacyPassphrases.add(network.passphrase);
      }
    });

    test('finds the code behind a name the old scheme made — the control', () {
      const code = '4081726359';
      final old = legacyNetworkOf(code);

      expect(codeByLegacyName[old.ssid], code,
          reason: 'the search has to work on the old values, or it proves '
              'nothing about the new ones');
      expect(legacyNetworkOf(codeByLegacyName[old.ssid]!).passphrase,
          old.passphrase,
          reason: 'and from the name it goes on to the passphrase');
    });

    test('finds nothing behind the name of a network a Windows PC raises',
        () async {
      final random = Random(2026);
      for (var i = 0; i < 200; i++) {
        asked.clear();
        await windows(random).startHosting();
        final ssid = startedWith()['ssid'] as String;

        expect(codeByLegacyName.containsKey(ssid), isFalse,
            reason: '$ssid led back to a code, and the passphrase follows');
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('nor behind the passphrase', () async {
      final random = Random(2026);
      for (var i = 0; i < 200; i++) {
        asked.clear();
        await windows(random).startHosting();

        expect(legacyPassphrases.contains(startedWith()['passphrase']), isFalse);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('a Windows PC', () {
    test('is told a pair drawn for this network, in the shape WPA2 takes',
        () async {
      await windows().startHosting();
      final sent = startedWith();

      expect(sent['ssid'], matches(RegExp(r'^DirectDrop-[0-9A-HJKMNP-TV-Z]{6}$')));
      expect(sent['passphrase'], matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{12}$')));
    });

    test('is told a different pair each time it is asked', () async {
      final service = windows();
      final pairs = <String>{};
      for (var i = 0; i < 20; i++) {
        asked.clear();
        await service.startHosting();
        pairs.add('${startedWith()['ssid']}/${startedWith()['passphrase']}');
      }

      expect(pairs, hasLength(20),
          reason: 'two networks raised one after the other share nothing');
    });

    test('gets back what the platform says is on the air', () async {
      final credentials = await windows().startHosting();
      final sent = startedWith();

      expect(credentials.ssid, sent['ssid']);
      expect(credentials.passphrase, sent['passphrase']);
    });
  });

  group('an Android phone', () {
    test('names its own network, and what comes back is that, not what it was '
        'told', () async {
      answer = (_) => {'ssid': 'AndroidShare_7712', 'passphrase': 'q3Vn8xKpL2mZ'};

      final credentials = await serviceOn('android').startHosting();

      expect(credentials.ssid, 'AndroidShare_7712');
      expect(credentials.passphrase, 'q3Vn8xKpL2mZ');
      expect(credentials.ssid, isNot(startedWith()['ssid']),
          reason: 'what Android was asked for is not what it raised');
    });

    test('a network with no passphrase is returned as it is, not made up',
        () async {
      answer = (_) => {'ssid': 'AndroidShare_1', 'passphrase': ''};

      final credentials = await serviceOn('android').startHosting();

      expect(credentials.passphrase, isEmpty);
    });
  });

  group('a Linux machine', () {
    test('has NetworkManager raise a pair drawn for this network', () async {
      final linux = _FakeLinux();
      final service = serviceOn('linux', linux: linux);

      final credentials = await service.startHosting();

      expect(linux.raised.single.ssid, credentials.ssid);
      expect(linux.raised.single.passphrase, credentials.passphrase);
      expect(credentials.ssid, matches(RegExp(r'^DirectDrop-[0-9A-HJKMNP-TV-Z]{6}$')));
      expect(credentials.passphrase, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{12}$')));
    });

    test('and a different pair the next time', () async {
      final linux = _FakeLinux();
      final service = serviceOn('linux', linux: linux);

      await service.startHosting();
      await service.startHosting();

      expect(linux.raised[0].ssid, isNot(linux.raised[1].ssid));
      expect(linux.raised[0].passphrase, isNot(linux.raised[1].passphrase));
    });
  });

  group('the platforms that cannot host', () {
    test('say so, and raise nothing', () async {
      for (final os in ['ios', 'macos']) {
        final service = serviceOn(os);

        await expectLater(service.startHosting(),
            throwsA(isA<HotspotException>()),
            reason: os);
      }
      expect(asked.where((c) => c.method == 'startHotspot'), isEmpty);
    });
  });

  test('the service takes no code to name a network from', () {
    final source =
        File('lib/core/network/local_hotspot_service.dart').readAsStringSync();
    final code = source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('///'))
        .join('\n');

    expect(code, isNot(contains('SessionCode')));
    expect(code, isNot(contains('session_code')));
    expect(code, contains('HotspotNaming.generate('));
    expect(HotspotNaming.ssidPrefix, 'DirectDrop-');
  });
}

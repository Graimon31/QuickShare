import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/linux_hotspot.dart';

/// Records what was asked of the shell and answers with what it was told to.
///
/// The point of injecting the runner: none of this needs NetworkManager, so
/// the argument lists and the parsing are checked on any machine, including
/// the Macs this is written on and a CI container with no Wi-Fi at all.
class _FakeShell {
  final List<List<String>> calls = [];
  final Map<String, ProcessResult> answers;
  final ProcessResult fallback;

  _FakeShell({
    this.answers = const {},
    ProcessResult? fallback,
  }) : fallback = fallback ?? ProcessResult(0, 0, '', '');

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add([executable, ...arguments]);
    for (final entry in answers.entries) {
      if (arguments.join(' ').contains(entry.key)) return entry.value;
      if (executable == entry.key) return entry.value;
    }
    return fallback;
  }
}

void main() {
  ProcessResult ok(String stdout) => ProcessResult(0, 0, stdout, '');
  ProcessResult failed(String stderr, [int code = 1]) =>
      ProcessResult(0, code, '', stderr);

  group('isAvailable', () {
    test('true when nmcli answers', () async {
      final shell = _FakeShell(answers: {'--version': ok('nmcli tool 1.44.2')});
      expect(await LinuxHotspot(runner: shell.run).isAvailable, isTrue);
    });

    test('false when nmcli is not installed', () async {
      Future<ProcessResult> missing(String _, List<String> __) async =>
          throw const ProcessException('nmcli', [], 'No such file');
      expect(await LinuxHotspot(runner: missing).isAvailable, isFalse);
    });
  });

  group('canHost', () {
    test('true when the driver lists AP among its modes', () async {
      // Asked before offering to host: plenty of adapters, USB ones above all,
      // cannot do AP at all, and NetworkManager only says so once you try.
      const iwOutput = '''
	Supported interface modes:
		 * IBSS
		 * managed
		 * AP
		 * AP/VLAN
		 * monitor
''';
      final shell = _FakeShell(answers: {'iw': ok(iwOutput)});
      expect(await LinuxHotspot(runner: shell.run).canHost, isTrue);
    });

    test('false when the driver cannot be an access point', () async {
      const iwOutput = '''
	Supported interface modes:
		 * managed
		 * monitor
''';
      final shell = _FakeShell(answers: {'iw': ok(iwOutput)});
      expect(await LinuxHotspot(runner: shell.run).canHost, isFalse);
    });

    test('AP/VLAN alone is not AP', () async {
      // A different capability that happens to contain the same letters.
      // Matching the word loosely would promise hosting on hardware that
      // cannot do it.
      const iwOutput = '''
	Supported interface modes:
		 * managed
		 * AP/VLAN
''';
      final shell = _FakeShell(answers: {'iw': ok(iwOutput)});
      expect(await LinuxHotspot(runner: shell.run).canHost, isFalse);
    });

    test('a missing iw declines rather than assuming', () async {
      Future<ProcessResult> missing(String _, List<String> __) async =>
          throw const ProcessException('iw', [], 'No such file');
      expect(await LinuxHotspot(runner: missing).canHost, isFalse);
    });
  });

  group('start', () {
    test('asks nmcli for exactly the network we mean', () async {
      final shell = _FakeShell();
      await LinuxHotspot(runner: shell.run)
          .start(ssid: 'DirectDrop-K7M2P4', passphrase: 'secret123456');

      expect(shell.calls.single, [
        'nmcli',
        'device',
        'wifi',
        'hotspot',
        'ssid',
        'DirectDrop-K7M2P4',
        'password',
        'secret123456',
      ]);
    });

    test('names an interface when told which one', () async {
      final shell = _FakeShell();
      await LinuxHotspot(runner: shell.run).start(
        ssid: 'DirectDrop-K7M2P4',
        passphrase: 'secret123456',
        interfaceName: 'wlan0',
      );

      expect(shell.calls.single, containsAllInOrder(['ifname', 'wlan0']));
    });

    test('a refusal carries what nmcli said, not just a code', () async {
      final shell = _FakeShell(
          fallback: failed('Error: Failed to add/activate new connection: '
              'Device does not support AP mode'));

      await expectLater(
        LinuxHotspot(runner: shell.run)
            .start(ssid: 'x', passphrase: 'yyyyyyyy'),
        throwsA(isA<HotspotCommandException>().having(
          (e) => e.message,
          'message',
          allOf(contains('AP mode'), isNot(startsWith('Error:'))),
        )),
      );
    });
  });

  group('scan', () {
    test('reads the terse output and drops duplicates', () async {
      // The same network is reported once per band and per access point; a
      // list on screen wants one row.
      final shell = _FakeShell(
          answers: {'list': ok('HomeNet\nDirectDrop-AB12CD\nHomeNet\n\n')});

      final found = await LinuxHotspot(runner: shell.run).scan();
      expect(found, equals(['DirectDrop-AB12CD', 'HomeNet']));
    });

    test('filters to our own networks when asked', () async {
      final shell = _FakeShell(
          answers: {'list': ok('HomeNet\nDirectDrop-AB12CD\nCafe WiFi\n')});

      final found =
          await LinuxHotspot(runner: shell.run).scan(prefix: 'DirectDrop-');
      expect(found, equals(['DirectDrop-AB12CD']));
    });

    test('unescapes the colons nmcli escapes', () async {
      // Colon is nmcli's field separator, so it escapes any inside a value.
      // Left as-is, a network named "a:b" would come back as "a\:b".
      final shell = _FakeShell(answers: {'list': ok(r'Guest\:Net')});
      expect(await LinuxHotspot(runner: shell.run).scan(),
          equals(['Guest:Net']));
    });

    test('asks in the machine-readable form', () async {
      // The aligned table changes shape between versions; terse is what nmcli
      // documents for scripting.
      final shell = _FakeShell(answers: {'list': ok('')});
      await LinuxHotspot(runner: shell.run).scan();

      expect(shell.calls.single, containsAllInOrder(['--terse', '--fields', 'SSID']));
    });
  });

  group('currentSsid', () {
    test('picks the active network', () async {
      final shell = _FakeShell(
          answers: {'ACTIVE': ok('no:HomeNet\nyes:DirectDrop-AB12CD\nno:Cafe\n')});
      expect(await LinuxHotspot(runner: shell.run).currentSsid(),
          equals('DirectDrop-AB12CD'));
    });

    test('null when nothing is connected', () async {
      final shell = _FakeShell(answers: {'ACTIVE': ok('no:HomeNet\nno:Cafe\n')});
      expect(await LinuxHotspot(runner: shell.run).currentSsid(), isNull);
    });

    test('null rather than an exception when the command fails', () async {
      // Used on paths that only want to put the machine back afterwards;
      // failing there must not take a finished transfer down with it.
      final shell = _FakeShell(fallback: failed('NetworkManager is not running'));
      expect(await LinuxHotspot(runner: shell.run).currentSsid(), isNull);
    });
  });

  group('stop', () {
    test('takes down the connection nmcli created', () async {
      final shell = _FakeShell();
      await LinuxHotspot(runner: shell.run).stop();

      expect(shell.calls.single,
          equals(['nmcli', 'connection', 'down', LinuxHotspot.connectionName]));
    });

    test('never throws, because it runs on the way out', () async {
      // Including out of a transfer that already failed. A second error there
      // tells the user nothing they can act on.
      Future<ProcessResult> broken(String _, List<String> __) async =>
          throw const ProcessException('nmcli', [], 'boom');
      await expectLater(LinuxHotspot(runner: broken).stop(), completes);
    });
  });
}

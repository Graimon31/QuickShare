import 'dart:io';

import 'package:quickshare/core/utils/app_logger.dart';

/// Runs one command and reports what it said. Injected so the logic here can
/// be tested on a machine that has no NetworkManager — which is every machine
/// this project is developed on.
typedef CommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Raising and joining Wi-Fi networks on Linux, through NetworkManager.
///
/// No native plugin: `nmcli` is the interface NetworkManager itself documents,
/// it is present on every desktop distribution that ships GNOME or KDE, and
/// shelling out to it is both less code and less to keep working across
/// distributions than a C++ plugin talking D-Bus.
///
/// The catch is that a Wi-Fi adapter has to support AP mode to host at all.
/// Plenty do not — USB dongles especially — and NetworkManager reports that as
/// a failure only once you try. So [canHost] asks the driver first rather than
/// letting a transfer get as far as "creating network…" and then stop.
class LinuxHotspot {
  /// The connection NetworkManager creates for `device wifi hotspot`. Named by
  /// nmcli itself, and needed again to take it down.
  static const String connectionName = 'Hotspot';

  final CommandRunner _run;

  LinuxHotspot({CommandRunner? runner}) : _run = runner ?? _defaultRunner;

  static Future<ProcessResult> _defaultRunner(
    String executable,
    List<String> arguments,
  ) =>
      Process.run(executable, arguments);

  /// Whether NetworkManager is here to talk to.
  Future<bool> get isAvailable async {
    try {
      final result = await _run('nmcli', const ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      // Not installed, or not on PATH. Either way there is nothing to drive.
      return false;
    }
  }

  /// Whether this machine's Wi-Fi hardware can act as an access point.
  ///
  /// `iw list` reports the modes the driver supports, and "AP" appearing in
  /// them is the difference between hosting working and failing halfway. Asked
  /// before offering to host rather than after: a device that cannot do it
  /// should not be presented as if it can.
  Future<bool> get canHost async {
    try {
      final result = await _run('iw', const ['list']);
      if (result.exitCode != 0) return false;
      final output = result.stdout.toString();
      // The block is indented under "Supported interface modes:", and the
      // entry is a bare `* AP` — matching the word alone would also match
      // "AP/VLAN", which is not the same capability.
      return RegExp(r'^\s*\*\s*AP\s*$', multiLine: true).hasMatch(output);
    } catch (_) {
      // `iw` missing is not proof either way, but claiming the capability on
      // no evidence is worse than declining it.
      return false;
    }
  }

  /// Raises a network with the given name and passphrase.
  ///
  /// The passphrase is passed as an argument, which puts it in this machine's
  /// process list for the moment the command runs. That is acceptable here and
  /// nowhere else: it is a throwaway credential for a network that exists for
  /// one transfer, and anyone able to read the process list is already on the
  /// machine that raised it.
  Future<void> start({
    required String ssid,
    required String passphrase,
    String? interfaceName,
  }) async {
    final arguments = [
      'device',
      'wifi',
      'hotspot',
      if (interfaceName != null) ...['ifname', interfaceName],
      'ssid',
      ssid,
      'password',
      passphrase,
    ];

    final result = await _run('nmcli', arguments);
    if (result.exitCode != 0) {
      throw HotspotCommandException(_explain(result));
    }
    AppLogger.info('NetworkManager raised $ssid', tag: 'HOTSPOT');
  }

  /// Takes the network down.
  ///
  /// Never throws: this runs on the way out of a transfer, including one that
  /// already failed, and a second error there tells the user nothing they can
  /// use. A network left up is visible in their system menu and can be closed
  /// from it.
  Future<void> stop() async {
    try {
      final result = await _run('nmcli', const [
        'connection',
        'down',
        connectionName,
      ]);
      if (result.exitCode != 0) {
        AppLogger.warning(
            'NetworkManager would not take the hotspot down: '
            '${_explain(result)}',
            tag: 'HOTSPOT');
      }
    } catch (e) {
      AppLogger.warning('Could not stop the hotspot: $e', tag: 'HOTSPOT');
    }
  }

  /// The networks in range, optionally only those whose name starts with
  /// [prefix].
  ///
  /// `--terse` because the human-readable table is aligned with spaces and
  /// changes shape between versions; the terse form is one field per line and
  /// is what nmcli documents for scripting.
  Future<List<String>> scan({String? prefix}) async {
    final result = await _run('nmcli', const [
      '--terse',
      '--fields',
      'SSID',
      'device',
      'wifi',
      'list',
    ]);
    if (result.exitCode != 0) {
      throw HotspotCommandException(_explain(result));
    }

    final seen = <String>{};
    for (final line in result.stdout.toString().split('\n')) {
      // nmcli escapes colons inside a field, since colon is its separator.
      final ssid = line.trim().replaceAll(r'\:', ':');
      if (ssid.isEmpty) continue;
      if (prefix != null && !ssid.startsWith(prefix)) continue;
      seen.add(ssid);
    }
    return seen.toList()..sort();
  }

  /// The network this machine is on, or null when it is on none.
  Future<String?> currentSsid() async {
    try {
      final result = await _run('nmcli', const [
        '--terse',
        '--fields',
        'ACTIVE,SSID',
        'device',
        'wifi',
      ]);
      if (result.exitCode != 0) return null;

      for (final line in result.stdout.toString().split('\n')) {
        if (!line.startsWith('yes:')) continue;
        final ssid = line.substring(4).trim().replaceAll(r'\:', ':');
        if (ssid.isNotEmpty) return ssid;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Joins a network somebody else raised.
  Future<void> join({
    required String ssid,
    required String passphrase,
  }) async {
    final result = await _run('nmcli', [
      'device',
      'wifi',
      'connect',
      ssid,
      'password',
      passphrase,
    ]);
    if (result.exitCode != 0) {
      throw HotspotCommandException(_explain(result));
    }
  }

  /// Turns nmcli's output into something worth showing someone.
  ///
  /// stderr first, because that is where nmcli puts the reason; the exit code
  /// alone says only that something went wrong.
  static String _explain(ProcessResult result) {
    final stderr = result.stderr.toString().trim();
    if (stderr.isNotEmpty) {
      // nmcli prefixes its own errors, and repeating that in a dialog reads
      // like a stutter.
      return stderr.replaceFirst(RegExp(r'^Error:\s*'), '');
    }
    final stdout = result.stdout.toString().trim();
    if (stdout.isNotEmpty) return stdout;
    return 'nmcli exited with code ${result.exitCode}';
  }
}

/// A command that failed, with what it said about why.
class HotspotCommandException implements Exception {
  final String message;
  const HotspotCommandException(this.message);
  @override
  String toString() => message;
}

import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/utils/device_name.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';

/// Finds the device offering a typed code.
///
/// The only reason this device ever listens for a sender. Nothing browses
/// while the app is open, while a screen is up, or while a code is being
/// typed: a browser is built when a complete code arrives, hands what it hears
/// to the resolver and to nothing else — no screen draws it — and is stopped
/// when the search ends, whatever the outcome.
class CodeLookup {
  CodeLookup({
    RendezvousBrowser Function()? browser,
    String? deviceName,
    this.discoveryWindow = const Duration(seconds: 4),
    this.probeTargets,
  })  : _browser = browser ?? NsdRendezvousBrowser.new,
        _deviceName = deviceName;

  final RendezvousBrowser Function() _browser;
  final String? _deviceName;

  /// How long to keep listening for an announcement that has not arrived yet
  /// before concluding there is nobody.
  final Duration discoveryWindow;

  /// See [CodeSessionResolver.probeTargets].
  final Future<List<ProbeTarget>> Function(List<RendezvousCandidate> matching)?
      probeTargets;

  /// Looks for the sender of [code] and asks it for the session. See
  /// [CodeSessionResolver] for what is trusted along the way, which is
  /// nothing the sender says about itself.
  Future<CodeSessionOutcome> find(SessionCode code) async {
    final browser = _browser();
    try {
      final listening = await browser.start();
      return await CodeSessionResolver(
        peers: () => browser.current,
        // A browse the platform would not start has nothing to wait for.
        peerUpdates: listening ? browser.candidates : null,
        refresh: listening ? browser.refresh : null,
        probeTargets: probeTargets,
        deviceName: _deviceName ?? describeThisDevice(),
        discoveryWindow: discoveryWindow,
      ).resolve(code);
    } finally {
      await browser.stop();
    }
  }
}

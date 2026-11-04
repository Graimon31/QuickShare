import 'dart:async';

import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/utils/device_name.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/receiver/data/client/internet_code_search.dart';

/// Finds the device offering a typed code, wherever it is: on the local
/// network, or anywhere on the internet.
///
/// The two searches run side by side, because a code does not say which kind
/// of offer it belongs to. **The first to prove the code wins** and the other
/// is stopped and cleaned up before this returns; neither is ever believed on
/// what a device or a mailbox says about itself, only on a proof that nobody
/// without the code can make (see [CodeSessionResolver] and
/// [InternetCodeSearch]).
///
/// The only reason this device ever listens for a sender. Nothing browses
/// while the app is open, while a screen is up, or while a code is being
/// typed: a browser is built when a complete code arrives, hands what it hears
/// to the resolver and to nothing else — no screen draws it — and is stopped
/// when the search ends, whatever the outcome. The same goes for the public
/// mailbox: it is opened for a search and closed with it, every topic
/// released.
class CodeLookup {
  CodeLookup({
    RendezvousBrowser Function()? browser,
    String? deviceName,
    this.discoveryWindow = const Duration(seconds: 4),
    this.probeTargets,
    InternetCodeSearch? internet,
    bool lanOnly = false,
  })  : _browser = browser ?? NsdRendezvousBrowser.new,
        _deviceName = deviceName,
        _internet = lanOnly ? null : (internet ?? InternetCodeSearch());

  final RendezvousBrowser Function() _browser;
  final String? _deviceName;
  final InternetCodeSearch? _internet;

  /// How long to keep listening for an announcement that has not arrived yet
  /// before concluding there is nobody.
  final Duration discoveryWindow;

  /// See [CodeSessionResolver.probeTargets].
  final Future<List<ProbeTarget>> Function(List<RendezvousCandidate> matching)?
      probeTargets;

  /// Looks for the sender of [code] and asks it for the session.
  ///
  /// With a [control], the caller can stop the search at any stage and learns
  /// which stage it is in; whatever either search had open is released before
  /// this returns. Without one, it simply runs to its end.
  ///
  /// A search that was stopped returns [CodeSessionNotFound]; a caller that
  /// stopped it knows to ignore that.
  Future<CodeSessionOutcome> find(SessionCode code,
      {CodeSearchControl? control}) async {
    final own = control ?? CodeSearchControl();
    final arbiter = CodeSearchArbiter(own);
    final name = _deviceName ?? describeThisDevice();

    Object? lanError;
    StackTrace? lanStack;
    final lan = _findOnLan(code, arbiter.gate('lan')).then<CodeSessionOutcome>(
      (outcome) => outcome,
      onError: (Object e, StackTrace st) {
        // The other search is pointless once this one is broken.
        lanError = e;
        lanStack = st;
        arbiter.abort();
        return const CodeSessionNotFound();
      },
    );
    final internet = _internet?.run(code,
            deviceName: name, gate: arbiter.gate('internet')) ??
        Future<CodeSessionOutcome>.value(const CodeSessionNotFound());

    final results = await Future.wait([lan, internet]);
    // Read before the control is let go: letting it go cancels it.
    final cancelled = own.isCancelled;
    if (control == null) await own.dispose();

    if (lanError != null) Error.throwWithStackTrace(lanError!, lanStack!);

    // The person gave up: whatever the searches made of being stopped is not
    // an answer.
    if (cancelled) return const CodeSessionNotFound();

    // Whoever won is the answer, whatever the other made of being stopped.
    switch (arbiter.winner) {
      case 'lan':
        return results[0];
      case 'internet':
        return results[1];
    }

    // Nobody proved anything. The most useful thing to say, in order: the
    // devices speak another version; the internet could not be reached at all
    // (so "check the code" would be the wrong advice); nothing there.
    if (results.any((r) => r is CodeSessionUpdateRequired)) {
      return const CodeSessionUpdateRequired();
    }
    if (results[1] is CodeSessionNoNetwork) return const CodeSessionNoNetwork();
    return const CodeSessionNotFound();
  }

  Future<CodeSessionOutcome> _findOnLan(
      SessionCode code, SearchGate gate) async {
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
      ).resolve(code, gate: gate);
    } finally {
      await browser.stop();
    }
  }
}

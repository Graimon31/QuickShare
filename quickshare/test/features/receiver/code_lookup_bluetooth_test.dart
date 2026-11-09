import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/features/receiver/data/client/bluetooth_code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_lookup.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/receiver/data/client/internet_code_search.dart';

// These stand-ins isolate arbitration and cleanup. Cryptography and the real
// sender/receiver radio path are tested in bluetooth_code_radio_integration.
class _Bluetooth extends BluetoothCodeSearch {
  bool stopped = false;
  @override
  Future<CodeSessionOutcome> run(SessionCode code,
      {required SearchGate gate}) async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (!gate.tryClaim()) {
      stopped = true;
      return const CodeSessionNotFound();
    }
    return const CodeSessionFoundBluetooth('authenticated-bluetooth-offer');
  }
}

class _Internet extends InternetCodeSearch {
  bool stopped = false;
  @override
  Future<CodeSessionOutcome> run(SessionCode code,
      {required String deviceName,
      required SearchGate gate,
      void Function(Future<void> Function())? onOfferCancellation}) async {
    await gate.stopped;
    stopped = true;
    return const CodeSessionNotFound();
  }
}

class _Browser implements RendezvousBrowser {
  _Browser({this.neverStarts = false});
  final bool neverStarts;
  bool closed = false;
  final started = Completer<bool>();
  @override
  bool get isRunning => !closed;
  @override
  List<RendezvousCandidate> get current => const [];
  @override
  Stream<List<RendezvousCandidate>> get candidates => const Stream.empty();
  @override
  Future<bool> start() => neverStarts ? started.future : Future.value(true);
  @override
  Future<void> refresh() async {}
  @override
  Future<void> stop() async => closed = true;
}

void main() {
  const code = SessionCode('1234567890');

  for (final stage in ['browse', 'probe', 'error']) {
    test('Bluetooth wins and cleans up with a stalled/failed LAN $stage', () async {
      final browser = _Browser(neverStarts: stage == 'browse');
      final internet = _Internet();
      final lookup = CodeLookup(
        browser: () => browser,
        deviceName: 'test',
        bluetooth: _Bluetooth(),
        internet: internet,
        probeTargets: (_) => stage == 'error'
            ? Future.error(StateError('LAN failed'))
            : Completer<List<ProbeTarget>>().future,
      );
      final result = await lookup.find(code).timeout(const Duration(seconds: 1));
      expect(result, isA<CodeSessionFoundBluetooth>());
      expect((result as CodeSessionFoundBluetooth).payload,
          'authenticated-bluetooth-offer');
      expect(internet.stopped, isTrue);
      expect(browser.closed, isTrue);
      if (stage == 'browse') {
        // A plugin may finish after cancellation: it is stopped again.
        browser.closed = false;
        browser.started.complete(true);
        await Future<void>.delayed(Duration.zero);
        expect(browser.closed, isTrue);
      }
    });
  }

  test('cancelled searches cannot hand a Bluetooth offer to the screen', () async {
    final browser = _Browser(neverStarts: true);
    final internet = _Internet();
    final bluetooth = _Bluetooth();
    final control = CodeSearchControl();
    final pending = CodeLookup(
      browser: () => browser,
      deviceName: 'test',
      internet: internet,
      bluetooth: bluetooth,
    ).find(code, control: control);
    control.cancel();
    expect(await pending.timeout(const Duration(seconds: 1)),
        isA<CodeSessionNotFound>());
    expect(bluetooth.stopped, isTrue);
    expect(internet.stopped, isTrue);
    expect(browser.closed, isTrue);
    await control.dispose();
  });
}

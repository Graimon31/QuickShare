// A typed code is the only reason this device ever listens for a sender.
//
// Nothing browses the network while the app is open, while a screen is up, or
// while a code is being typed. The browse starts when a complete code is
// handed to the lookup, is never shown to anyone, and ends when the lookup
// does — whatever the outcome.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/features/receiver/data/client/code_lookup.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';

class _Browser implements RendezvousBrowser {
  final List<String> log = [];
  final _updates = StreamController<List<RendezvousCandidate>>.broadcast();
  List<RendezvousCandidate> heard = [];

  @override
  Stream<List<RendezvousCandidate>> get candidates => _updates.stream;
  @override
  List<RendezvousCandidate> get current => heard;
  @override
  bool get isRunning => log.contains('start') && !log.contains('stop');

  @override
  Future<bool> start() async {
    log.add('start');
    return true;
  }

  @override
  Future<void> refresh() async => log.add('refresh');

  @override
  Future<void> stop() async {
    log.add('stop');
    await _updates.close();
  }
}

void main() {
  const code = SessionCode('1234567890');

  CodeLookup lookup(_Browser browser, {List<String>? trace}) => CodeLookup(
        browser: () {
          trace?.add('built');
          return browser;
        },
        deviceName: 'Test Laptop',
        discoveryWindow: Duration.zero,
        probeTargets: (_) async => const [],
      );

  test('building a lookup listens for nothing', () {
    final browser = _Browser();
    final trace = <String>[];
    lookup(browser, trace: trace);

    expect(trace, isEmpty, reason: 'no browser is even built');
    expect(browser.log, isEmpty);
  });

  test('finding a code starts the browse, and ends it, whatever the outcome',
      () async {
    final browser = _Browser();

    final outcome = await lookup(browser).find(code);

    expect(outcome, isA<CodeSessionNotFound>());
    expect(browser.log.first, 'start');
    expect(browser.log.last, 'stop');
    expect(browser.isRunning, isFalse);
  });

  test('the browse ends even when the search throws', () async {
    final browser = _Browser();
    final throwing = CodeLookup(
      browser: () => browser,
      deviceName: 'Test Laptop',
      discoveryWindow: Duration.zero,
      probeTargets: (_) async => throw StateError('boom'),
    );

    await expectLater(throwing.find(code), throwsStateError);

    expect(browser.log.last, 'stop');
  });

  test('a browser that cannot start is not the end of the search', () async {
    final browser = _BrokenBrowser();

    final outcome = await CodeLookup(
      browser: () => browser,
      deviceName: 'Test Laptop',
      discoveryWindow: Duration.zero,
      probeTargets: (_) async => const [],
    ).find(code);

    expect(outcome, isA<CodeSessionNotFound>(),
        reason: 'the search carries on without the browse');
  });
}

class _BrokenBrowser extends _Browser {
  @override
  Future<bool> start() async => false;
}

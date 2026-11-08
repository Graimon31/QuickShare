// One typed code, two places it might be: the local network and the internet.
//
// Both searches run at once and the first to prove the code wins. This file
// puts a real local sender (a `LocalHttpServer` on loopback) and a real
// internet sender (`InternetCodeSender` on an in-memory mailbox) on either
// side of a real `CodeLookup`, and checks who wins, who is stopped, and that
// what the loser opened is gone before the answer comes back.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/network/internet_code.dart';
import 'package:quickshare/core/network/internet_code_sender.dart';
import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/features/receiver/data/client/code_lookup.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/receiver/data/client/internet_code_search.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';

import '../../support/fake_mailbox.dart';
import '../../support/sample_offer.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

class _Browser implements RendezvousBrowser {
  final List<String> log = [];
  final _updates = StreamController<List<RendezvousCandidate>>.broadcast();

  @override
  Stream<List<RendezvousCandidate>> get candidates => _updates.stream;
  @override
  List<RendezvousCandidate> get current => const [];
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

const _inline = InternetCodePake(inline: true);

void main() {
  setUpAll(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());

  const code = SessionCode('4815162342');

  late FakeMailboxHub hub;
  late _Browser browser;
  FakeMailbox? receiverBox;
  final cleanups = <Future<void> Function()>[];

  setUp(() {
    hub = FakeMailboxHub();
    browser = _Browser();
    receiverBox = null;
  });

  tearDown(() async {
    for (final cleanup in cleanups.reversed) {
      await cleanup();
    }
    cleanups.clear();
  });

  /// A lookup whose LAN side looks at [lanTargets] and whose internet side
  /// uses the in-memory mailbox.
  CodeLookup lookup({
    List<ProbeTarget> lanTargets = const [],
    CodeMailbox Function()? mailbox,
    InternetCodeTimings timings = const InternetCodeTimings(
      findTimeout: Duration(milliseconds: 600),
      approvalWait: Duration(seconds: 5),
    ),
  }) =>
      CodeLookup(
        browser: () => browser,
        deviceName: 'Receiving Mac',
        discoveryWindow: Duration.zero,
        probeTargets: (_) async => lanTargets,
        internet: InternetCodeSearch(
          mailbox: mailbox ?? () => receiverBox = hub.endpoint('receiver'),
          timings: timings,
          pake: _inline,
        ),
      );

  /// An internet sender listening on the hub, which says yes to everyone.
  Future<({InternetCodeSender sender, List<String> asked})> internetSender({
    bool approves = true,
    Completer<bool>? decision,
    String offer = 'QS1placeholder',
  }) async {
    final asked = <String>[];
    final sender = InternetCodeSender(
      mailbox: hub.endpoint('sender'),
      code: code,
      offer: () async => offer,
      approve: (name) {
        asked.add(name);
        return decision?.future ?? Future.value(approves);
      },
      pake: _inline,
    );
    await sender.start();
    cleanups.add(sender.stop);
    return (sender: sender, asked: asked);
  }

  /// A local sender on loopback, with a person who says [approves].
  Future<({LocalHttpServer server, List<String> asked, int port})> lanSender({
    bool approves = true,
  }) async {
    final server = LocalHttpServer();
    final asked = <String>[];
    server.onApprovalRequested = (request) async {
      asked.add(request.deviceName);
      return approves;
    };
    final port = await server.startQhtpSessionWhileIndexing(
      sessionId: 'lan-session',
      index: Future.value(QhtpIndexerResult(
        manifest: QhtpManifest(
          sessionId: 'lan-session',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          itemCount: 2,
          totalBytes: 1234,
          items: const [QhtpItem(id: 'i', path: 'f.txt', size: 1234)],
        ),
        itemIdToAbsPathMap: {'i': '/tmp/f.txt'},
      )),
      authToken: 'a-token-of-some-length-for-the-lan-session',
      sessionCode: code,
    );
    cleanups.add(server.stop);
    return (server: server, asked: asked, port: port);
  }

  ProbeTarget at(int port) =>
      (address: InternetAddress.loopbackIPv4, port: port);

  group('the sender is on the internet', () {
    test('is found, the browse is stopped and the mailbox released', () async {
      final offer = sampleOffer();
      final sender = await internetSender(offer: offer);
      final control = CodeSearchControl();

      final outcome = await lookup().find(code, control: control);

      expect(outcome, isA<CodeSessionFoundOnline>());
      expect((outcome as CodeSessionFoundOnline).payload, offer);
      expect(sender.asked, ['Receiving Mac']);
      expect(browser.log.last, 'stop');
      expect(receiverBox!.isClosed, isTrue);
      expect(receiverBox!.subscribed, isEmpty);
      expect(control.phase, CodeSearchPhase.awaitingApproval);
    });

    test('a refusal is a refusal', () async {
      await internetSender(approves: false);

      final outcome = await lookup().find(code);

      expect(outcome, isA<CodeSessionDeclined>());
      expect(receiverBox!.isClosed, isTrue);
    });
  });

  group('the sender is on the local network', () {
    test('is found, and the internet search is stopped and released',
        () async {
      final lan = await lanSender();

      final outcome = await lookup(lanTargets: [at(lan.port)]).find(code);

      expect(outcome, isA<CodeSessionFound>());
      expect((outcome as CodeSessionFound).payload.port, lan.port);
      expect(lan.asked, ['Receiving Mac']);
      expect(receiverBox!.isClosed, isTrue);
      expect(receiverBox!.subscribed, isEmpty);
      expect(hub.listenedTopics, isEmpty);
      expect(browser.log.last, 'stop');
    });

    test('a refusal there is a refusal', () async {
      final lan = await lanSender(approves: false);

      final outcome = await lookup(lanTargets: [at(lan.port)]).find(code);

      expect(outcome, isA<CodeSessionDeclined>());
    });

    test('found even when the internet cannot be reached at all', () async {
      final lan = await lanSender();
      final down = hub.endpoint('down')..down = true;

      final outcome = await lookup(
        lanTargets: [at(lan.port)],
        mailbox: () => down,
      ).find(code);

      expect(outcome, isA<CodeSessionFound>());
    });
  });

  group('the sender is on both', () {
    test('only one of them is asked, and it is the first to prove the code; '
        'the other never learns who is asking', () async {
      final lan = await lanSender();
      final net = await internetSender();

      final outcome = await lookup(lanTargets: [at(lan.port)]).find(code);

      expect(outcome, anyOf(isA<CodeSessionFound>(), isA<CodeSessionFoundOnline>()));
      expect(lan.asked.length + net.asked.length, 1,
          reason: 'this device names itself to one sender, not two');
      expect(receiverBox!.isClosed, isTrue);
      expect(browser.log.last, 'stop');
    });
  });

  group('the sender is nowhere', () {
    test('the answer is not found, once both searches have given up', () async {
      final watch = Stopwatch()..start();

      final outcome = await lookup().find(code);

      expect(outcome, isA<CodeSessionNotFound>());
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 500)),
          reason: 'the internet is given its time even when the LAN is quick');
      expect(receiverBox!.isClosed, isTrue);
      expect(browser.log.last, 'stop');
    });

    test('a wrong code is not found either, and nobody is asked', () async {
      final net = await internetSender();
      final lan = await lanSender();
      // Off by one digit: usually another topic, so usually unheard, and
      // never believed if heard. Either way nobody is asked.
      const wrong = SessionCode('4815162343');

      final outcome = await lookup(lanTargets: [at(lan.port)]).find(wrong);

      expect(outcome, isA<CodeSessionNotFound>());
      expect(net.asked, isEmpty);
      expect(lan.asked, isEmpty);
    });

    test('with the internet unreachable it says so, instead of blaming the '
        'code, and at once', () async {
      final down = hub.endpoint('down')..down = true;
      final watch = Stopwatch()..start();

      final outcome = await lookup(
        mailbox: () => down,
        timings: const InternetCodeTimings(findTimeout: Duration(seconds: 20)),
      ).find(code);

      expect(outcome, isA<CodeSessionNoNetwork>());
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'not the twenty seconds a wrong code takes');
    });

    test('a reply from a newer version says "update"', () async {
      final search = lookup();
      final pending = search.find(code);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final request = hub.published
          .map((m) => CodeRequest.tryParse(m.payload))
          .whereType<CodeRequest>()
          .single;
      hub.inject(
          request.reply,
          Uint8List.fromList(
              '{"v":2,"pB":"x","cB":"y"}'.codeUnits));

      final outcome = await pending;

      expect(outcome, isA<CodeSessionUpdateRequired>());
    });
  });

  group('the person gives up', () {
    test('while looking', () async {
      final control = CodeSearchControl();
      final pending = lookup().find(code, control: control);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(receiverBox!.subscribed, isNotEmpty);

      control.cancel();
      final outcome = await pending.timeout(const Duration(seconds: 2));

      expect(outcome, isA<CodeSessionNotFound>());
      expect(receiverBox!.isClosed, isTrue);
      expect(receiverBox!.subscribed, isEmpty);
      expect(hub.listenedTopics, isEmpty);
      expect(browser.log.last, 'stop');
    });

    test('while a person on the internet side is deciding', () async {
      final decision = Completer<bool>();
      final net = await internetSender(decision: decision);
      final control = CodeSearchControl();
      final pending = lookup().find(code, control: control);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(control.phase, CodeSearchPhase.awaitingApproval);
      expect(net.asked, hasLength(1));

      control.cancel();
      final outcome = await pending.timeout(const Duration(seconds: 2));

      expect(outcome, isA<CodeSessionNotFound>());
      expect(receiverBox!.isClosed, isTrue);
      expect(receiverBox!.subscribed, isEmpty);
    });

    test('while a person on the local side is deciding', () async {
      final server = LocalHttpServer();
      final asked = Completer<void>();
      server.onApprovalRequested = (request) {
        asked.complete();
        return Completer<bool>().future;
      };
      final port = await server.startQhtpSessionWhileIndexing(
        sessionId: 's',
        index: Future.value(QhtpIndexerResult(
          manifest: QhtpManifest(
            sessionId: 's',
            createdAt: DateTime.now().millisecondsSinceEpoch,
            itemCount: 1,
            totalBytes: 1,
            items: const [QhtpItem(id: 'i', path: 'f', size: 1)],
          ),
          itemIdToAbsPathMap: {'i': '/tmp/f'},
        )),
        authToken: 'a-token-of-some-length-for-the-lan-session',
        sessionCode: code,
      );
      cleanups.add(server.stop);
      final control = CodeSearchControl();
      final pending = lookup(lanTargets: [at(port)]).find(code, control: control);
      await asked.future.timeout(const Duration(seconds: 5));
      expect(control.phase, CodeSearchPhase.awaitingApproval);

      control.cancel();
      final outcome = await pending.timeout(const Duration(seconds: 3));

      expect(outcome, isA<CodeSessionNotFound>());
      expect(receiverBox!.isClosed, isTrue);
      expect(browser.log.last, 'stop');
    });

    test('before it began: nothing is left behind', () async {
      final control = CodeSearchControl()..cancel();

      final outcome = await lookup().find(code, control: control)
          .timeout(const Duration(seconds: 2));

      expect(outcome, isA<CodeSessionNotFound>());
      expect(hub.listenedTopics, isEmpty);
      expect(hub.published, isEmpty,
          reason: 'a search that was cancelled asks nobody anything');
    });
  });

  test('a broken local search still allows an authenticated internet sender',
      () async {
    await internetSender();
    final throwing = CodeLookup(
      browser: () => browser,
      deviceName: 'Receiving Mac',
      discoveryWindow: Duration.zero,
      probeTargets: (_) async => throw StateError('boom'),
      internet: InternetCodeSearch(
        mailbox: () => receiverBox = hub.endpoint('receiver'),
        pake: _inline,
      ),
    );
    final result = await throwing.find(code).timeout(const Duration(seconds: 5));
    expect(result, isA<CodeSessionFoundOnline>());
    expect(receiverBox!.isClosed, isTrue);
    expect(browser.log.last, 'stop');
  });

  test('building a lookup opens nothing', () {
    lookup();
    CodeLookup();
    expect(hub.openEndpoints, 0);
    expect(browser.log, isEmpty);
  });
}

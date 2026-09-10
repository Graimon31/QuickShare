// The link a Bluetooth-paired transfer runs over is negotiated, not assumed:
// the side that can host does, the other joins, and a failure climbs a ladder
// — retry, redelegate, retry — before anyone is told. These tests walk the
// ladder rung by rung with a driver that fails on cue.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/network/session_code.dart';

class _FakeDriver implements DirectLinkDriver {
  _FakeDriver({
    this.canHost = true,
    this.wifiReady = true,
    this.canPeerLink = false,
  });

  @override
  final bool canHost;
  final bool wifiReady;

  /// Apple only in life; a flag here, so the pair that has nothing else can
  /// be walked through without a radio.
  @override
  final bool canPeerLink;

  /// Each peer-link attempt consumes one entry: an [Exception] to throw, or
  /// an [int] to hand back as the loopback port. Running off the end means
  /// success on the hosting side.
  final List<Object> peerLinkPlan = [];

  final List<String> peerLinksHosted = [];
  final List<String> peerLinksJoined = [];
  int peerLinkStops = 0;

  /// Each hosting attempt consumes one entry: a [HotspotCredentials] to
  /// return or an [Exception] to throw.
  final List<Object> hostPlan = [];

  /// Each join consumes one entry; running off the end means success.
  final List<Object> joinPlan = [];

  int hostCalls = 0;
  int joinCalls = 0;
  int stopCalls = 0;
  int ensureCalls = 0;
  final List<HotspotCredentials> joined = [];

  @override
  Future<HotspotCredentials> host(SessionCode code) async {
    final planned = hostPlan[hostCalls++];
    if (planned is Exception) throw planned;
    return planned as HotspotCredentials;
  }

  @override
  Future<void> joinNetwork(HotspotCredentials credentials) async {
    joined.add(credentials);
    joinCalls++;
    if (joinPlan.length >= joinCalls) {
      final planned = joinPlan[joinCalls - 1];
      if (planned is Exception) throw planned;
    }
  }

  @override
  Future<bool> ensureWifiReady() async {
    ensureCalls++;
    return wifiReady;
  }

  @override
  Future<void> stopHosting() async {
    stopCalls++;
  }

  @override
  Future<void> hostPeerLink(String serviceName, int localPort) async {
    peerLinksHosted.add(serviceName);
    if (peerLinkPlan.length >= peerLinksHosted.length) {
      final planned = peerLinkPlan[peerLinksHosted.length - 1];
      if (planned is Exception) throw planned;
    }
  }

  @override
  Future<int> joinPeerLink(String serviceName) async {
    peerLinksJoined.add(serviceName);
    if (peerLinkPlan.length >= peerLinksJoined.length) {
      final planned = peerLinkPlan[peerLinksJoined.length - 1];
      if (planned is Exception) throw planned;
      if (planned is int) return planned;
    }
    return 51234;
  }

  @override
  Future<void> stopPeerLink() async {
    peerLinkStops++;
  }
}

class _FakeSignal implements DirectLinkSignal {
  final sentDirectives = <DirectLinkDirective>[];
  final sentOffers = <({String ssid, String passphrase})>[];

  /// Emitted in answer to the next hostByReceiver directive, the way a
  /// receiver that just raised its network would answer.
  ({String ssid, String passphrase})? autoOffer;

  final _directives = StreamController<DirectLinkDirective>.broadcast();
  final _offers =
      StreamController<({String ssid, String passphrase})>.broadcast();

  @override
  Stream<DirectLinkDirective> get directives => _directives.stream;

  @override
  Stream<({String ssid, String passphrase})> get apOffers => _offers.stream;

  @override
  Future<void> sendDirective(DirectLinkDirective directive) async {
    sentDirectives.add(directive);
    final offer = autoOffer;
    if (directive.receiverHosts && offer != null) {
      // A timer, not a microtask: the coordinator starts listening after the
      // send returns, and a broadcast stream forgives nothing.
      Timer(Duration.zero, () => _offers.add(offer));
    }
  }

  @override
  Future<void> sendApOffer(String ssid, String passphrase) async {
    sentOffers.add((ssid: ssid, passphrase: passphrase));
  }

  void pushDirective(DirectLinkDirective directive) {
    _directives.add(directive);
  }
}

DirectLinkCoordinator _coordinator(
  _FakeDriver driver,
  _FakeSignal signal, {
  Future<bool> Function()? probe,
}) =>
    DirectLinkCoordinator(
      driver: driver,
      signal: signal,
      probeLink: probe,
      hostAttempts: 2,
      joinAttempts: 3,
      offerRounds: 2,
      retryPause: const Duration(milliseconds: 1),
      apOfferTimeout: const Duration(milliseconds: 30),
      negotiationBudget: const Duration(milliseconds: 200),
    );

HotspotCredentials _creds(String ssid) =>
    HotspotCredentials(ssid: ssid, passphrase: 'X7K29DMQ41ZT', hostAddress: '192.168.49.1');

void main() {
  final code = SessionCode.parse('0123456789')!;

  group('sender', () {
    test('hosts when it can, and the directive carries the live credentials',
        () async {
      // Not the code-derived pair: Android names its own network, and the
      // name that went on air is the one the receiver must join.
      final driver = _FakeDriver()
        ..hostPlan.add(_creds('AndroidShare_4821'));
      final signal = _FakeSignal();

      final outcome = await _coordinator(driver, signal).runSender(code);

      expect(outcome, isA<DirectLinkReady>());
      expect((outcome as DirectLinkReady).hosting, isTrue);
      expect(driver.hostCalls, equals(1));
      final directive = signal.sentDirectives.single;
      expect(directive.receiverHosts, isFalse);
      expect(directive.ssid, equals('AndroidShare_4821'));
    });

    test('delegates when hosting fails every attempt', () async {
      final driver = _FakeDriver()
        ..hostPlan.add(const HotspotException('adapter busy'))
        ..hostPlan.add(const HotspotException('adapter busy'));
      final signal = _FakeSignal()
        ..autoOffer = (ssid: 'DirectDrop-9F2C18', passphrase: 'X7K29DMQ41ZT');

      final outcome = await _coordinator(driver, signal).runSender(code);

      expect(outcome, isA<DirectLinkReady>());
      expect((outcome as DirectLinkReady).hosting, isFalse);
      expect(driver.hostCalls, equals(2));
      expect(signal.sentDirectives.last.receiverHosts, isTrue);
      expect(driver.joined.single.ssid, equals('DirectDrop-9F2C18'));
    });

    test('delegates straight away when it cannot host', () async {
      // iPhone, Mac: hosting is not a failure to retry, it is a fact.
      final driver = _FakeDriver(canHost: false);
      final signal = _FakeSignal()
        ..autoOffer = (ssid: 'AndroidShare_7712', passphrase: 'X7K29DMQ41ZT');

      final outcome = await _coordinator(driver, signal).runSender(code);

      expect(outcome, isA<DirectLinkReady>());
      expect(driver.hostCalls, equals(0));
      expect(signal.sentDirectives.single.receiverHosts, isTrue);
    });

    test('an offer that never comes is waited out, then declared', () async {
      final driver = _FakeDriver(canHost: false);
      final signal = _FakeSignal();

      final outcome = await _coordinator(driver, signal).runSender(code);

      expect(outcome, isA<DirectLinkUnavailable>());
      // One ask per round — a lost BLE write costs a round, not the session.
      expect(signal.sentDirectives.length, equals(2));
      expect(signal.sentDirectives.every((d) => d.receiverHosts), isTrue);
    });

    test('falls to the peer-to-peer link when nobody could raise a network',
        () async {
      // iPhone to Mac: neither can host and neither can be hosted, which is
      // not an edge case but the pair AirDrop exists for. Before this rung
      // the session simply died here — the ladder ran out with the one
      // radio that reaches this pair never tried.
      final driver = _FakeDriver(canHost: false, canPeerLink: true);
      final signal = _FakeSignal();

      final outcome =
          await _coordinator(driver, signal).runSender(code, servingPort: 8000);

      expect(outcome, isA<DirectLinkOverPeerLink>());
      expect((outcome as DirectLinkOverPeerLink).hosting, isTrue);
      expect(driver.peerLinksHosted.single,
          equals(PeerLinkService.serviceNameFor(code.sessionToken)));
      expect(signal.sentDirectives.last.peerLinkService,
          equals(driver.peerLinksHosted.single),
          reason: 'the receiver joins it by name, there is no network to name');
    });

    test('tries the peer link only after every network rung', () async {
      // Last on purpose: a sender cannot tell whether the far side can join
      // one, so "everyone was asked and nobody offered" is the evidence it
      // uses. Trying it first would strand a receiver that only does Wi-Fi.
      final driver = _FakeDriver(canHost: false, canPeerLink: true);
      final signal = _FakeSignal()
        ..autoOffer = (ssid: 'AndroidShare_7712', passphrase: 'X7K29DMQ41ZT');

      final outcome =
          await _coordinator(driver, signal).runSender(code, servingPort: 8000);

      expect(outcome, isA<DirectLinkReady>());
      expect(driver.peerLinksHosted, isEmpty);
    });

    test('is skipped with nothing to forward to', () async {
      // No serving port means no server on the other end of the link.
      final driver = _FakeDriver(canHost: false, canPeerLink: true);
      final outcome = await _coordinator(driver, _FakeSignal()).runSender(code);

      expect(outcome, isA<DirectLinkUnavailable>());
      expect(driver.peerLinksHosted, isEmpty);
    });

    test('a peer link that will not come up is retried, then declared',
        () async {
      final driver = _FakeDriver(canHost: false, canPeerLink: true)
        ..peerLinkPlan.addAll([Exception('awdl asleep'), Exception('again')]);

      final outcome = await _coordinator(driver, _FakeSignal())
          .runSender(code, servingPort: 8000);

      expect(outcome, isA<DirectLinkUnavailable>());
      expect(driver.peerLinksHosted.length, equals(2));
      expect(driver.peerLinkStops, equals(2),
          reason: 'a half-raised link left behind is one the next try trips on');
    });

    test('a network that refuses the first join is tried again', () async {
      // The network may still be coming up when the offer arrives; a refusal
      // a second later is not a refusal forever.
      final driver = _FakeDriver(canHost: false)
        ..joinPlan.add(const HotspotException('not found'));
      final signal = _FakeSignal()
        ..autoOffer = (ssid: 'AndroidShare_7712', passphrase: 'X7K29DMQ41ZT');

      final outcome = await _coordinator(driver, signal).runSender(code);

      expect(outcome, isA<DirectLinkReady>());
      expect(driver.joinCalls, equals(2));
    });

    test('a host the probe cannot see is torn down and delegated past',
        () async {
      final driver = _FakeDriver()
        ..hostPlan.add(_creds('AndroidShare_4821'))
        ..hostPlan.add(_creds('AndroidShare_4821'));
      final signal = _FakeSignal()
        ..autoOffer = (ssid: 'DirectDrop-9F2C18', passphrase: 'X7K29DMQ41ZT');

      final outcome = await _coordinator(driver, signal, probe: () async {
        // The own network never shows a peer; the joined one does.
        return driver.joinCalls > 0;
      }).runSender(code);

      expect(outcome, isA<DirectLinkReady>());
      expect((outcome as DirectLinkReady).hosting, isFalse);
      expect(driver.hostCalls, equals(2));
      expect(driver.stopCalls, greaterThanOrEqualTo(2));
      expect(signal.sentDirectives.last.receiverHosts, isTrue);
    });

    test('Wi-Fi that stays off ends the ladder before it starts', () async {
      final driver = _FakeDriver(wifiReady: false);
      final signal = _FakeSignal();

      final outcome = await _coordinator(driver, signal).runSender(code);

      expect(outcome, isA<DirectLinkUnavailable>());
      expect((outcome as DirectLinkUnavailable).message, contains('Wi-Fi'));
      expect(driver.hostCalls, equals(0));
      expect(driver.joinCalls, equals(0));
    });
  });

  group('receiver', () {
    test('joins the network the directive names', () async {
      final driver = _FakeDriver(canHost: false);
      final signal = _FakeSignal();

      final pending = _coordinator(driver, signal).runReceiver(code);
      await Future<void>.delayed(Duration.zero);
      signal.pushDirective(const DirectLinkDirective.hostBySender(
          ssid: 'AndroidShare_4821', passphrase: 'X7K29DMQ41ZT'));
      final outcome = await pending;

      expect(outcome, isA<DirectLinkReady>());
      expect((outcome as DirectLinkReady).hosting, isFalse);
      expect(driver.joined.single.ssid, equals('AndroidShare_4821'));
    });

    test('hosts when asked and offers the credentials it got', () async {
      final driver = _FakeDriver()
        ..hostPlan.add(_creds('AndroidShare_7712'));
      final signal = _FakeSignal();

      final pending = _coordinator(driver, signal).runReceiver(code);
      await Future<void>.delayed(Duration.zero);
      signal.pushDirective(const DirectLinkDirective.hostByReceiver());
      final outcome = await pending;

      expect(outcome, isA<DirectLinkReady>());
      expect((outcome as DirectLinkReady).hosting, isTrue);
      // The offer carries what actually went on air, not what the code
      // derives — the sender never has to guess.
      expect(signal.sentOffers.single.ssid, equals('AndroidShare_7712'));
    });

    test('a directive that never comes ends the wait', () async {
      final driver = _FakeDriver();
      final signal = _FakeSignal();

      final outcome = await _coordinator(driver, signal).runReceiver(code);

      expect(outcome, isA<DirectLinkUnavailable>());
      expect(driver.hostCalls, equals(0));
      expect(driver.joinCalls, equals(0));
    });

    test('hosting that fails once is retried before it is declared', () async {
      final driver = _FakeDriver()
        ..hostPlan.add(const HotspotException('adapter busy'))
        ..hostPlan.add(_creds('AndroidShare_7712'));
      final signal = _FakeSignal();

      final pending = _coordinator(driver, signal).runReceiver(code);
      await Future<void>.delayed(Duration.zero);
      signal.pushDirective(const DirectLinkDirective.hostByReceiver());
      final outcome = await pending;

      expect(outcome, isA<DirectLinkReady>());
      expect(driver.hostCalls, equals(2));
      expect(signal.sentOffers.length, equals(1));
    });

    test('joins the peer link the sender raised', () async {
      final driver = _FakeDriver(canHost: false, canPeerLink: true)
        ..peerLinkPlan.add(51234);
      final signal = _FakeSignal();

      final pending = _coordinator(driver, signal).runReceiver(code);
      await Future<void>.delayed(Duration.zero);
      signal.pushDirective(
          const DirectLinkDirective.overPeerLink(serviceName: 'dd-abc123'));
      final outcome = await pending;

      expect(outcome, isA<DirectLinkOverPeerLink>());
      final link = outcome as DirectLinkOverPeerLink;
      expect(link.hosting, isFalse);
      expect(link.localPort, equals(51234),
          reason: 'the file is pulled from loopback, not from the far side');
      expect(driver.peerLinksJoined.single, equals('dd-abc123'));
    });

    test('lets a directive it cannot act on pass, and takes the next',
        () async {
      // The whole reason an Apple pair works: an iPhone asked to raise a
      // network cannot, and saying so would leave the sender waiting out an
      // offer that was never coming. It keeps listening instead, and the
      // rung that does reach it arrives a moment later.
      final driver = _FakeDriver(canHost: false, canPeerLink: true);
      final signal = _FakeSignal();

      final pending = _coordinator(driver, signal).runReceiver(code);
      await Future<void>.delayed(Duration.zero);
      signal.pushDirective(const DirectLinkDirective.hostByReceiver());
      await Future<void>.delayed(Duration.zero);
      signal.pushDirective(
          const DirectLinkDirective.overPeerLink(serviceName: 'dd-abc123'));
      final outcome = await pending;

      expect(outcome, isA<DirectLinkOverPeerLink>());
      expect(driver.hostCalls, equals(0),
          reason: 'a device that cannot host must not try');
    });

    test('a peer link it cannot join is let pass too', () async {
      // Android and the desktops have no peer-to-peer radio; the sender's
      // last rung simply is not for them.
      final driver = _FakeDriver(canHost: true, canPeerLink: false)
        ..hostPlan.add(_creds('DirectDrop-9F2C18'));
      final signal = _FakeSignal();

      final pending = _coordinator(driver, signal).runReceiver(code);
      await Future<void>.delayed(Duration.zero);
      signal.pushDirective(
          const DirectLinkDirective.overPeerLink(serviceName: 'dd-abc123'));
      await Future<void>.delayed(Duration.zero);
      signal.pushDirective(const DirectLinkDirective.hostByReceiver());
      final outcome = await pending;

      expect(outcome, isA<DirectLinkReady>());
      expect(driver.peerLinksJoined, isEmpty);
    });

    test('a join that keeps failing is declared, not looped on', () async {
      final driver = _FakeDriver(canHost: false)
        ..joinPlan.add(const HotspotException('denied'))
        ..joinPlan.add(const HotspotException('denied'))
        ..joinPlan.add(const HotspotException('denied'));
      final signal = _FakeSignal();

      final pending = _coordinator(driver, signal).runReceiver(code);
      await Future<void>.delayed(Duration.zero);
      signal.pushDirective(const DirectLinkDirective.hostBySender(
          ssid: 'AndroidShare_4821', passphrase: 'X7K29DMQ41ZT'));
      final outcome = await pending;

      expect(outcome, isA<DirectLinkUnavailable>());
      expect(driver.joinCalls, equals(3));
    });
  });

  group('the directive on the wire', () {
    test('both shapes round-trip through JSON', () {
      const senderHosts = DirectLinkDirective.hostBySender(
          ssid: 'AndroidShare_4821', passphrase: 'X7K29DMQ41ZT');
      final parsedSender =
          DirectLinkDirective.fromJson(senderHosts.toJson())!;
      expect(parsedSender.receiverHosts, isFalse);
      expect(parsedSender.ssid, equals('AndroidShare_4821'));

      const receiverHosts = DirectLinkDirective.hostByReceiver();
      final parsedReceiver =
          DirectLinkDirective.fromJson(receiverHosts.toJson())!;
      expect(parsedReceiver.receiverHosts, isTrue);
      // A sender-hosted directive without credentials is not a directive —
      // the joiner would have nothing to dial.
      expect(DirectLinkDirective.fromJson(const {'host': 'sender'}), isNull);
      expect(DirectLinkDirective.fromJson(const {'host': 'nobody'}), isNull);
    });
  });
}

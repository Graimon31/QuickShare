// NET-02-C — a connection that cannot be made must END, and must say why.
//
// The target setup has a permanent VPN that makes NAT behave as symmetric, so
// the relay is the normal path there, not a nicety. When the Worker that
// issues relay credentials cannot be reached, ICE has nothing but STUN to
// work with and the session is doomed. Two things must hold then:
//
//  1. it terminates in bounded time — libwebrtc usually reports `failed`
//     itself, but an app that relies on that alone can sit in "connecting"
//     with no end, so the app keeps its own deadline;
//  2. what the person is told is true: "the relay service could not be
//     reached" — not "a relay was available but ..." and not a shrug.
//
// What this file can and cannot reach: `WebRtcTransferTransport` and
// `WebRtcReceiverTransport` call `createPeerConnection`, which needs
// flutter_webrtc's platform channel and so cannot run under `flutter test`.
// They are therefore exercised through the pure-Dart pieces they delegate to —
// the Worker fetch (`IceServers.configurationDynamic`, against a real dead
// port), the connect deadline and `diagnoseNoPath`, which is the one function
// both transports call to read what is known when ICE gives up — and the
// fake-async clock stands in for the 60 seconds. What is left is the wiring
// inside the two transports, which only a device run shows: it is
// `integration_test/relay_diagnosis_test.dart`.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/webrtc/ice_connect_deadline.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/relay_availability.dart';

void main() {
  group('IceConnectDeadline', () {
    test('ends a negotiation that never connects, exactly once', () {
      fakeAsync((async) {
        var expired = 0;
        final deadline = IceConnectDeadline(
          budget: const Duration(seconds: 60),
          onExpired: () => expired++,
        )..arm();

        async.elapse(const Duration(seconds: 59));
        expect(expired, 0);
        async.elapse(const Duration(seconds: 2));
        expect(expired, 1);
        async.elapse(const Duration(minutes: 10));
        expect(expired, 1, reason: 'one verdict, not one per tick');
        expect(deadline.isArmed, isFalse);
      });
    });

    test('a connection that comes up in time is never declared dead', () {
      fakeAsync((async) {
        var expired = 0;
        final deadline = IceConnectDeadline(
          budget: const Duration(seconds: 60),
          onExpired: () => expired++,
        )..arm();

        async.elapse(const Duration(seconds: 20));
        deadline.connected();
        async.elapse(const Duration(minutes: 10));

        expect(expired, 0);
      });
    });

    test('a connection already up is never made to wait: arming late does '
        'nothing', () {
      // The receiver arms after `publish` returns, and a relay acknowledges
      // only once the sender may long since have connected. A deadline
      // started then expired in the middle of a healthy transfer.
      fakeAsync((async) {
        var expired = 0;
        final deadline = IceConnectDeadline(
          budget: const Duration(seconds: 60),
          onExpired: () => expired++,
        );

        deadline.connected();
        deadline.arm();

        expect(deadline.isArmed, isFalse);
        async.elapse(const Duration(minutes: 10));
        expect(expired, 0);
      });
    });

    test('cancel() silences it, as stopping a session must', () {
      fakeAsync((async) {
        var expired = 0;
        IceConnectDeadline(
          budget: const Duration(seconds: 60),
          onExpired: () => expired++,
        )
          ..arm()
          ..cancel();

        async.elapse(const Duration(minutes: 10));

        expect(expired, 0);
      });
    });

    test('arming twice does not restart the clock', () {
      fakeAsync((async) {
        var expired = 0;
        final deadline = IceConnectDeadline(
          budget: const Duration(seconds: 60),
          onExpired: () => expired++,
        )..arm();

        async.elapse(const Duration(seconds: 40));
        deadline.arm();
        async.elapse(const Duration(seconds: 21));

        expect(expired, 1, reason: 'sixty seconds from the first arm()');
      });
    });

    test('the default budget is finite and outlasts the disconnect grace', () {
      expect(IceConnectDeadline.defaultBudget, greaterThan(
          const Duration(seconds: 20)));
      expect(IceConnectDeadline.defaultBudget,
          lessThanOrEqualTo(const Duration(minutes: 2)));
    });
  });

  group('NoPathDiagnosis', () {
    const wording = <RelayUnavailableReason, String>{
      RelayUnavailableReason.rateLimited: FailureCode.noPathRelayLimited,
      RelayUnavailableReason.limiterUnavailable: FailureCode.noPathRelayLimited,
      RelayUnavailableReason.unreachable: FailureCode.noPathRelayUnreachable,
      RelayUnavailableReason.timeout: FailureCode.noPathRelayUnreachable,
      RelayUnavailableReason.providerError: FailureCode.noPathRelayUnreachable,
      RelayUnavailableReason.malformedResponse:
          FailureCode.noPathRelayUnreachable,
      RelayUnavailableReason.relayDisabled: FailureCode.noPathRelayOff,
      RelayUnavailableReason.relayUnconfigured: FailureCode.noPathRelayOff,
      RelayUnavailableReason.noWorkerUrl: FailureCode.noPathRelayOff,
    };

    test('every reason has a message, and none is forgotten', () {
      expect(wording.keys.toSet(), equals(RelayUnavailableReason.values.toSet()));
    });

    for (final entry in wording.entries) {
      test('${entry.key.name} reads as ${entry.value}', () {
        final diagnosis = NoPathDiagnosis(
          relayUnavailable: RelayUnavailable(entry.key),
        );
        expect(diagnosis.failureCode, equals(entry.value));
      });
    }

    test('a relay that WAS offered does not blame the relay', () {
      const diagnosis = NoPathDiagnosis(candidates: '4 candidates (srflx: true, relay: true)');

      expect(diagnosis.failureCode, equals(FailureCode.noPathRelayWasAvailable));
      expect(diagnosis.failureCode, isNot(FailureCode.noPathRelayUnreachable));
      expect(diagnosis.failureCode, isNot(FailureCode.noPathRelayLimited));
      expect(diagnosis.failureCode, isNot(FailureCode.noPathRelayOff));
    });

    test('the English summary carries the reason and the selected pair', () {
      const diagnosis = NoPathDiagnosis(
        relayUnavailable: RelayUnavailable(RelayUnavailableReason.rateLimited,
            retryAfter: Duration(seconds: 60), statusCode: 429),
        candidates: '3 candidates (srflx: true, relay: false)',
        selectedPair: 'none',
      );

      expect(diagnosis.summary, contains('rateLimited'));
      expect(diagnosis.summary, contains('60'));
      expect(diagnosis.summary, contains('3 candidates'));
      expect(diagnosis.summary, contains('selected pair: none'));
    });

    test('the summary of a relay that was offered says so', () {
      const diagnosis = NoPathDiagnosis(selectedPair: 'local=host remote=srflx');
      expect(diagnosis.summary, contains('relay: offered'));
      expect(diagnosis.summary, contains('local=host remote=srflx'));
    });
  });

  group('describeSelectedPair', () {
    StatsReport pair(String local, String remote, {String state = 'succeeded'}) =>
        StatsReport('p', 'candidate-pair', 0.0, {
          'state': state,
          'nominated': true,
          'localCandidateId': local,
          'remoteCandidateId': remote,
        });
    StatsReport cand(String id, String type) =>
        StatsReport(id, 'local-candidate', 0.0, {'candidateType': type});

    test('names the candidate type on each end of the chosen pair', () {
      final text = describeSelectedPair([
        pair('c1', 'c2'),
        cand('c1', 'relay'),
        cand('c2', 'srflx'),
      ]);
      expect(text, equals('local=relay remote=srflx'));
    });

    test('says none when no pair ever succeeded', () {
      expect(
        describeSelectedPair([pair('c1', 'c2', state: 'failed'), cand('c1', 'host')]),
        equals('none'),
      );
      expect(describeSelectedPair(const []), equals('none'));
    });
  });

  group('diagnoseNoPath', () {
    RTCIceCandidate candidate(String type) => RTCIceCandidate(
        'candidate:1 1 udp 2113937151 192.0.2.1 5000 typ $type', '0', 0);

    test('reads the relay, the candidates and the pair, in that order of '
        'importance', () async {
      final gathering = IceGatheringTracker()
        ..observe(candidate('host'))
        ..observe(candidate('srflx'));

      final diagnosis = await diagnoseNoPath(
        relayUnavailable:
            const RelayUnavailable(RelayUnavailableReason.rateLimited),
        gathering: gathering,
        connection: _FakeConnection(const []),
      );

      expect(diagnosis.relayUnavailable?.reason,
          equals(RelayUnavailableReason.rateLimited));
      expect(diagnosis.candidates, equals('2 candidates (srflx: true, relay: false)'));
      expect(diagnosis.selectedPair, equals('none'));
      expect(diagnosis.failureCode, equals(FailureCode.noPathRelayLimited));
    });

    test('a relay that was offered is not blamed', () async {
      final diagnosis = await diagnoseNoPath(
        relayUnavailable: null,
        gathering: IceGatheringTracker()..observe(candidate('relay')),
        connection: _FakeConnection(const []),
      );

      expect(diagnosis.relayUnavailable, isNull);
      expect(diagnosis.failureCode, equals(FailureCode.noPathRelayWasAvailable));
      expect(diagnosis.candidates, contains('relay: true'));
    });

    test('without a connection the pair is unknown, not an error', () async {
      final diagnosis = await diagnoseNoPath(
        relayUnavailable: null,
        gathering: IceGatheringTracker(),
      );

      expect(diagnosis.selectedPair, equals('unknown'));
      expect(diagnosis.candidates, equals('0 candidates (srflx: false, relay: false)'));
    });

    test('a connection that cannot be read leaves the pair unknown', () async {
      final diagnosis = await diagnoseNoPath(
        relayUnavailable: null,
        gathering: IceGatheringTracker(),
        connection: _FakeConnection.failing(),
      );

      expect(diagnosis.selectedPair, equals('unknown'));
    });
  });

  group('NET-02-C: Worker unreachable', () {
    test('ends in a terminal failure that names the relay as unreachable',
        () async {
      // Real network failure: nothing listens on port 1.
      final setup = await IceServers.configurationDynamic(
        workerBaseUrl: 'http://127.0.0.1:1',
      );
      expect(setup.relayAvailable, isFalse);
      expect(IceServers.containsTurn(setup.configuration), isFalse);

      // What the transport has at that point: gathering found only
      // STUN-derived candidates, the peer never answers, nothing connects.
      final gathering = IceGatheringTracker()
        ..observe(RTCIceCandidate(
            'candidate:1 1 udp 2113937151 192.0.2.1 5000 typ host', '0', 0))
        ..observe(RTCIceCandidate(
            'candidate:2 1 udp 1677729535 198.51.100.7 5000 typ srflx', '0', 0));
      final reported = <NoPathDiagnosis>[];
      fakeAsync((async) {
        // The transports' own `onExpired`: read the diagnosis with the
        // function they both call, and report it.
        IceConnectDeadline(
          onExpired: () => unawaited(diagnoseNoPath(
            relayUnavailable: setup.relayUnavailable,
            gathering: gathering,
            connection: _FakeConnection(const []),
          ).then(reported.add)),
        ).arm();

        async.elapse(IceConnectDeadline.defaultBudget +
            const Duration(seconds: 1));
        async.flushMicrotasks();
      });

      expect(reported, hasLength(1),
          reason: 'with no relay the negotiation must end, not wait');
      final diagnosis = reported.single;
      expect(diagnosis.relayUnavailable?.reason,
          equals(RelayUnavailableReason.unreachable));
      expect(diagnosis.failureCode, equals(FailureCode.noPathRelayUnreachable));
      expect(
          diagnosis.summary,
          equals('No usable path between the devices (ICE gave up). '
              'relay: unreachable; '
              '2 candidates (srflx: true, relay: false); '
              'selected pair: none'));
    });

    test('a rate-limited Worker is told apart from an unreachable one',
        () async {
      // Same shape, different cause: the message must not say "unreachable"
      // about a Worker that answered, and must say when to try again.
      const diagnosis = NoPathDiagnosis(
        relayUnavailable: RelayUnavailable(RelayUnavailableReason.rateLimited,
            retryAfter: Duration(seconds: 60), statusCode: 429),
      );
      expect(diagnosis.failureCode, equals(FailureCode.noPathRelayLimited));
    });
  });
}

/// A peer connection that can be asked for statistics and nothing else.
class _FakeConnection extends Fake implements RTCPeerConnection {
  _FakeConnection(this._reports) : _fails = false;
  _FakeConnection.failing()
      : _reports = const [],
        _fails = true;

  final List<StatsReport> _reports;
  final bool _fails;

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async {
    if (_fails) throw StateError('the connection is closed');
    return _reports;
  }
}

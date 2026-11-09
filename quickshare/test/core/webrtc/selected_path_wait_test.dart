import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';

class _StatsConnection extends Fake implements RTCPeerConnection {
  _StatsConnection(this.read);
  final Future<List<StatsReport>> Function() read;

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) => read();
}

void main() {
  test('a channel opening before native stats does not hide the relay',
      () async {
    var reads = 0;
    final pc = _StatsConnection(() async {
      if (++reads == 1) return [];
      return [
        StatsReport('pair', 'candidate-pair', 0, {
          'state': 'succeeded',
          'nominated': true,
          'localCandidateId': 'local',
          'remoteCandidateId': 'remote',
        }),
        StatsReport('local', 'local-candidate', 0, {'candidateType': 'relay'}),
        StatsReport('remote', 'remote-candidate', 0, {'candidateType': 'host'}),
      ];
    });
    final result = await waitForSelectedPath(pc,
        pollInterval: const Duration(milliseconds: 1));
    expect(result.kind, IcePathKind.relayed);
    expect(result.pair, 'local=relay remote=host');
    expect(reads, 2);
  });

  test('an unresponsive native stats call is bounded and stays unknown',
      () async {
    final never = Completer<List<StatsReport>>();
    final result = await waitForSelectedPath(
            _StatsConnection(() => never.future),
            budget: const Duration(milliseconds: 20))
        .timeout(const Duration(seconds: 1));
    expect(result.kind, IcePathKind.unknown);
  });

  test('missing stats cannot become a direct path', () async {
    final result = await waitForSelectedPath(_StatsConnection(() async => []),
        budget: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 1));
    expect(result.kind, IcePathKind.unknown);
  });
}

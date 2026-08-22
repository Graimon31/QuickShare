import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Tracks how far ICE gathering has got, so the serverless flows can decide
/// when the description is worth freezing into a QR code.
///
/// In serverless mode there is no trickle channel: whatever is in the SDP at
/// the moment it is encoded is all the far side will ever see. Waiting a fixed
/// second was the old behaviour and it silently dropped relay candidates,
/// because a TURN allocation over TLS does not finish that fast. Losing the
/// relay candidate is exactly what makes a transfer fail behind a VPN or a
/// symmetric NAT — the two cases the relay exists for.
class IceGatheringTracker {
  bool _sawRelay = false;
  bool _sawServerReflexive = false;
  int _count = 0;

  bool get sawRelay => _sawRelay;
  bool get sawServerReflexive => _sawServerReflexive;
  int get count => _count;

  /// Feed every candidate reported by the peer connection.
  void observe(RTCIceCandidate candidate) {
    final value = candidate.candidate;
    if (value == null || value.isEmpty) return;
    _count++;
    if (value.contains('typ relay')) _sawRelay = true;
    if (value.contains('typ srflx')) _sawServerReflexive = true;
  }

  String describe() => '$_count candidates '
      '(srflx: $_sawServerReflexive, relay: $_sawRelay)';
}

/// How the connection actually ended up carrying data.
enum IcePathKind {
  /// Same network — a direct route between two local addresses.
  direct,

  /// Through a NAT via a reflexive address, still peer to peer.
  peerToPeer,

  /// Through a TURN server. Somebody else's bandwidth, billed by the gigabyte.
  relayed,

  /// Statistics were unavailable or unreadable.
  unknown,
}

/// Reads back which candidate pair WebRTC actually nominated.
///
/// This has to be asked after the connection is up, not at gathering time.
/// Gathering only says what was *offered*; which pair wins is decided by the
/// connectivity checks between both peers, and in serverless mode the far side
/// has not even scanned the QR code yet when gathering ends. A pre-flight
/// decision about relay cost is therefore only meaningful once the data
/// channel is open — but still before the first byte of payload is sent.
///
/// Returns [IcePathKind.unknown] rather than throwing: a missing stat is not a
/// reason to block a transfer the user asked for.
Future<IcePathKind> selectedPathKind(RTCPeerConnection connection) async {
  try {
    final reports = await connection.getStats();

    String? localCandidateId;
    for (final report in reports) {
      if (report.type != 'candidate-pair') continue;
      final values = report.values;
      final state = values['state'];
      final nominated = values['nominated'];
      final selected = values['selected'];
      if (state == 'succeeded' && (nominated == true || selected == true)) {
        localCandidateId = values['localCandidateId'] as String?;
        break;
      }
    }

    // Some implementations do not mark a pair nominated on a data-only
    // connection; fall back to any succeeded pair.
    if (localCandidateId == null) {
      for (final report in reports) {
        if (report.type == 'candidate-pair' &&
            report.values['state'] == 'succeeded') {
          localCandidateId = report.values['localCandidateId'] as String?;
          break;
        }
      }
    }
    if (localCandidateId == null) return IcePathKind.unknown;

    for (final report in reports) {
      if (report.id != localCandidateId) continue;
      final type = report.values['candidateType'] as String?;
      return switch (type) {
        'relay' => IcePathKind.relayed,
        'srflx' || 'prflx' => IcePathKind.peerToPeer,
        'host' => IcePathKind.direct,
        _ => IcePathKind.unknown,
      };
    }
    return IcePathKind.unknown;
  } catch (e) {
    AppLogger.warning('Could not read the selected ICE pair: $e',
        tag: 'WEBRTC');
    return IcePathKind.unknown;
  }
}

/// Whether a session of [sessionBytes] may proceed over [path].
///
/// Only a relayed path is capped. A direct or peer-to-peer route costs nobody
/// anything, and an unknown one is given the benefit of the doubt — refusing a
/// transfer because a statistic was missing would be worse than the risk.
bool relayLimitAllows(IcePathKind path, int sessionBytes, {int? limitBytes}) {
  final limit = limitBytes ?? AppConstants.maxRelayTransferBytes;
  if (path != IcePathKind.relayed) return true;
  if (limit <= 0) return true;
  return sessionBytes <= limit;
}

/// Waits for [connection] to gather something worth sending.
///
/// Returns as soon as gathering completes, or as soon as a relay candidate
/// exists — a relay works from anywhere, so there is nothing to gain by
/// waiting for the rest. Otherwise gives up at [AppConstants.iceGatheringMaxWait]
/// and lets the caller ship whatever was collected.
Future<void> waitForUsableCandidates(
  RTCPeerConnection connection,
  IceGatheringTracker tracker, {
  Duration? maxWait,
  String tag = 'WEBRTC',
}) async {
  final limit = maxWait ?? AppConstants.iceGatheringMaxWait;
  final started = DateTime.now();
  const pollInterval = Duration(milliseconds: 100);

  while (DateTime.now().difference(started) < limit) {
    if (connection.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      AppLogger.info(
          'ICE gathering complete after '
          '${DateTime.now().difference(started).inMilliseconds} ms, '
          '${tracker.describe()}',
          tag: tag);
      return;
    }
    if (tracker.sawRelay) {
      AppLogger.info(
          'ICE has a relay candidate after '
          '${DateTime.now().difference(started).inMilliseconds} ms, '
          'not waiting for the rest — ${tracker.describe()}',
          tag: tag);
      return;
    }
    await Future<void>.delayed(pollInterval);
  }

  // Worth a warning rather than a debug line: shipping an offer with neither a
  // reflexive nor a relay candidate means the only way through is a direct
  // route on the same network.
  final level = tracker.sawRelay || tracker.sawServerReflexive
      ? 'usable'
      : 'host-only';
  AppLogger.warning(
      'ICE gathering hit the ${limit.inMilliseconds} ms ceiling with a '
      '$level candidate set — ${tracker.describe()}',
      tag: tag);
}

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:quickshare/core/diagnostics/path_liveness_probe.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// One reading of a peer connection, reduced to the numbers that say which
/// layer of a transfer is alive: the chosen ICE pair, the DTLS transport under
/// the data channel, and the data channel itself.
///
/// Kept as plain data so a test can build one from canned reports and the
/// stall analysis can run on a recorded series.
class TransferStatsSample {
  const TransferStatsSample({
    required this.at,
    required this.fields,
  });

  final Duration at;
  final Map<String, Object?> fields;

  int? intOf(String key) {
    final v = fields[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  double? doubleOf(String key) {
    final v = fields[key];
    return v is num ? v.toDouble() : null;
  }

  String line(String label) {
    final seconds = (at.inMilliseconds / 1000).toStringAsFixed(1);
    final buffer = StringBuffer('$label t=$seconds');
    for (final e in fields.entries) {
      if (e.value == null) continue;
      buffer.write(' ${e.key}=${e.value}');
    }
    return buffer.toString();
  }
}

/// Reads [reports] (the result of `getStats()`) into one [TransferStatsSample].
///
/// Addresses are left out on purpose: a log line says what kind of path this
/// is (`relay`, `udp`, `tls`), not where the two ends are.
TransferStatsSample readTransferStats(
    List<StatsReport> reports, Duration at) {
  final byId = {for (final r in reports) r.id: r};
  final fields = <String, Object?>{};

  num? number(Map<dynamic, dynamic> v, String key) {
    final raw = v[key];
    if (raw is num) return raw;
    if (raw is String) return num.tryParse(raw);
    return null;
  }

  // The pair the transport says it is using; failing that, the nominated one.
  StatsReport? pair;
  for (final r in reports) {
    if (r.type != 'transport') continue;
    final id = r.values['selectedCandidatePairId'];
    if (id is String && byId[id] != null) {
      pair = byId[id];
      break;
    }
  }
  pair ??= () {
    for (final r in reports) {
      if (r.type == 'candidate-pair' &&
          r.values['state'] == 'succeeded' &&
          (r.values['nominated'] == true || r.values['selected'] == true)) {
        return r;
      }
    }
    return null;
  }();

  if (pair != null) {
    final v = pair.values;
    final local = byId[v['localCandidateId']];
    final remote = byId[v['remoteCandidateId']];
    fields['pair'] = 'L:${local?.values['candidateType'] ?? '?'}'
        '/${local?.values['protocol'] ?? '?'}'
        '${local?.values['relayProtocol'] != null ? '(${local!.values['relayProtocol']})' : ''}'
        '-R:${remote?.values['candidateType'] ?? '?'}'
        '/${remote?.values['protocol'] ?? '?'}';
    fields['pair_state'] = v['state'];
    fields['pair_tx'] = number(v, 'bytesSent');
    fields['pair_rx'] = number(v, 'bytesReceived');
    fields['pair_pkt_tx'] = number(v, 'packetsSent');
    fields['pair_pkt_rx'] = number(v, 'packetsReceived');
    fields['pair_discard_tx'] = number(v, 'packetsDiscardedOnSend');
    final rtt = number(v, 'currentRoundTripTime');
    fields['rtt_ms'] = rtt == null ? null : (rtt * 1000).round();
    final out = number(v, 'availableOutgoingBitrate');
    fields['avail_out_kbps'] = out == null ? null : (out / 1000).round();
    fields['stun_req_tx'] = number(v, 'requestsSent');
    fields['stun_resp_rx'] = number(v, 'responsesReceived');
    fields['stun_req_rx'] = number(v, 'requestsReceived');
    fields['consent_tx'] = number(v, 'consentRequestsSent');
    // Timestamps in these reports are milliseconds on libwebrtc's clock; only
    // their distance from the report's own time is meaningful.
    final now = pair.timestamp;
    double? age(String key) {
      final t = number(v, key);
      if (t == null || now == 0) return null;
      // `timestamp` is microseconds from the native layer, the `last...`
      // fields are milliseconds.
      return ((now / 1000) - t.toDouble()) / 1000;
    }

    final lastRx = age('lastPacketReceivedTimestamp');
    final lastTx = age('lastPacketSentTimestamp');
    fields['pair_rx_age_s'] = lastRx?.toStringAsFixed(1);
    fields['pair_tx_age_s'] = lastTx?.toStringAsFixed(1);
  }

  for (final r in reports) {
    final v = r.values;
    if (r.type == 'transport') {
      fields['dtls'] = v['dtlsState'];
      fields['ice'] = v['iceState'];
      fields['tr_tx'] = number(v, 'bytesSent');
      fields['tr_rx'] = number(v, 'bytesReceived');
      fields['tr_pkt_tx'] = number(v, 'packetsSent');
      fields['tr_pkt_rx'] = number(v, 'packetsReceived');
      fields['pair_changes'] = number(v, 'selectedCandidatePairChanges');
    } else if (r.type == 'data-channel') {
      fields['dc'] = v['state'];
      fields['dc_msg_tx'] = number(v, 'messagesSent');
      fields['dc_tx'] = number(v, 'bytesSent');
      fields['dc_msg_rx'] = number(v, 'messagesReceived');
      fields['dc_rx'] = number(v, 'bytesReceived');
    }
  }
  return TransferStatsSample(at: at, fields: fields);
}

/// Logs one line a second about a live peer connection, for as long as it is
/// running. Debug builds only (see `AppConstants.statsProbe`); it exists to
/// answer "which layer died first" for a transfer that stopped, from the two
/// ends' logs laid side by side.
///
/// Reads only. It touches nothing the transfer depends on, and a failed read
/// is a missing line.
class TransferStatsSampler {
  TransferStatsSampler({
    required this.label,
    required this.connection,
    this.extra,
    this.interval = const Duration(seconds: 1),
    this.withLivenessProbe = false,
    void Function(String line)? sink,
  }) : _sink = sink ?? ((line) => AppLogger.info(line, tag: 'STATS'));

  final String label;
  final RTCPeerConnection connection;

  /// The transport's own numbers (what it has queued, what it has written),
  /// added to every line so that they sit next to the network's.
  final Map<String, Object?> Function()? extra;
  final Duration interval;

  /// Also opens a TCP connection to a public address every tick, so that a
  /// connection that dies can be told apart from a host whose network has gone.
  /// See [PathLivenessProbe].
  final bool withLivenessProbe;
  final PathLivenessProbe _liveness = PathLivenessProbe();
  final void Function(String line) _sink;

  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  bool _reading = false;
  final List<TransferStatsSample> samples = [];

  void start() {
    if (_timer != null) return;
    _clock.start();
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }

  Future<void> _tick() async {
    if (_reading) return;
    _reading = true;
    try {
      final probes = withLivenessProbe
          ? _liveness.tcp()
          : null;
      final reports =
          await connection.getStats().timeout(const Duration(seconds: 2));
      final sample = readTransferStats(reports, _clock.elapsed);
      final probed = probes == null ? null : await probes;
      final merged = TransferStatsSample(
        at: sample.at,
        fields: {
          ...sample.fields,
          ...?extra?.call(),
          if (probed != null) 'tcp_probe': probed,
        },
      );
      samples.add(merged);
      _sink(merged.line(label));
    } catch (e) {
      _sink('$label t=${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} '
          'stats_error=${e.runtimeType}');
    } finally {
      _reading = false;
    }
  }
}

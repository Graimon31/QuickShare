import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Where a public MQTT broker lives and how to reach it.
class MqttBroker {
  final String host;
  final int port;
  final String path;

  /// True when the broker terminates TLS on 443, which makes the traffic
  /// indistinguishable from ordinary HTTPS to a filtering middlebox.
  bool get isHttpsPort => port == 443;

  const MqttBroker(this.host, this.port, {this.path = '/mqtt'});

  String get url => 'wss://$host$path';

  @override
  String toString() => '$host:$port';
}

/// Carries the sealed answer through a public MQTT broker over WebSocket+TLS.
///
/// Nothing is retained: the desktop subscribes before the QR code appears and
/// the phone publishes at QoS 0 with no retain flag, so the broker forwards the
/// bytes to whoever is already listening and keeps nothing afterwards. That is
/// stronger than any expiry setting — there is no copy left to expire.
class MqttAnswerChannel implements AnswerChannel {
  /// Ordered by preference. Reachability was measured from a Russian home
  /// network: every one of these answered a real TLS + WebSocket upgrade,
  /// while `broker.emqx.io:443` and `test.mosquitto.org:443` turned out to be
  /// plain web servers rather than brokers.
  static const defaultBrokers = <MqttBroker>[
    MqttBroker('broker.emqx.io', 8084),
    MqttBroker('test.mosquitto.org', 8081),
    MqttBroker('broker.hivemq.com', 8884),
  ];

  final List<MqttBroker> brokers;
  final Duration timeout;

  MqttServerClient? _client;
  MqttBroker? _connected;
  StreamSubscription? _updates;
  final _controller = StreamController<Uint8List>.broadcast();

  MqttAnswerChannel({
    List<MqttBroker>? brokers,
    this.timeout = const Duration(seconds: 8),
  }) : brokers = brokers ?? defaultBrokers;

  @override
  String get name => 'mqtt(${_connected?.host ?? 'connecting'})';

  @override
  Stream<Uint8List> get answers => _controller.stream;

  @override
  Future<void> subscribe(String topic) async {
    final client = await _connect();
    client.subscribe(_topicPath(topic), MqttQos.atMostOnce);

    _updates = client.updates?.listen((events) {
      for (final event in events) {
        final message = event.payload;
        if (message is! MqttPublishMessage) continue;
        try {
          final text = utf8.decode(message.payload.message);
          final bytes = base64Url.decode(base64Url.normalize(text.trim()));
          if (!_controller.isClosed) _controller.add(Uint8List.fromList(bytes));
        } catch (e) {
          // Public topics are shared with the whole internet; anything that
          // is not our base64 is somebody else's traffic, not an error.
          AppLogger.warning('Discarded unparsable MQTT payload: $e',
              tag: 'SIGNALING');
        }
      }
    });
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    final client = await _connect();
    final builder = MqttClientPayloadBuilder()
      ..addString(base64Url.encode(payload).replaceAll('=', ''));
    client.publishMessage(
        _topicPath(topic), MqttQos.atMostOnce, builder.payload!);

    // publishMessage only hands the frame to the outbound buffer; give the
    // socket a moment to flush before the caller tears the connection down.
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  String _topicPath(String topic) => 'quickshare/$topic/answer';

  Future<MqttServerClient> _connect() async {
    final existing = _client;
    if (existing != null &&
        existing.connectionStatus?.state == MqttConnectionState.connected) {
      return existing;
    }

    final failures = <String>[];
    for (final broker in brokers) {
      try {
        final client = _buildClient(broker);
        await client.connect().timeout(timeout);
        if (client.connectionStatus?.state != MqttConnectionState.connected) {
          throw StateError('status ${client.connectionStatus?.state}');
        }
        _client = client;
        _connected = broker;
        AppLogger.info('MQTT answer channel connected to $broker'
            '${broker.isHttpsPort ? '' : ' (non-443 port)'}', tag: 'SIGNALING');
        return client;
      } catch (e) {
        failures.add('$broker: $e');
        AppLogger.warning('MQTT broker $broker unavailable: $e',
            tag: 'SIGNALING');
      }
    }
    throw StateError('no public MQTT broker reachable — ${failures.join('; ')}');
  }

  MqttServerClient _buildClient(MqttBroker broker) {
    final suffix = Random.secure().nextInt(1 << 32).toRadixString(36);
    final client = MqttServerClient.withPort(broker.url, 'qs_$suffix', broker.port)
      ..useWebSocket = true
      ..secure = false // the wss:// scheme already selects TLS
      ..websocketProtocols = MqttClientConstants.protocolsSingleDefault
      ..keepAlivePeriod = 20
      ..autoReconnect = false
      ..logging(on: false);
    client.setProtocolV311();
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier('qs_$suffix')
        .startClean();
    return client;
  }

  @override
  Future<void> close() async {
    await _updates?.cancel();
    _updates = null;
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
    if (!_controller.isClosed) await _controller.close();
  }
}

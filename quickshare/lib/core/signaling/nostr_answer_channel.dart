import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:quickshare/core/crypto/bip340.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Carries the sealed answer through public Nostr relays over WSS on 443.
///
/// Chosen over the MQTT brokers for one measured reason: the brokers that
/// actually speak MQTT sit on 8084/8081/8884, and a filtering middlebox has no
/// trouble telling those from web traffic. Nostr relays are plain WebSocket on
/// 443, so the rendezvous looks exactly like an HTTPS session.
///
/// Relays do not gossip. An event published to one relay never reaches another,
/// so both peers fan out across the whole list — publish to all, subscribe to
/// all, first valid payload wins. A probe from the target network on
/// 2026-08-13 had two of five public relays failing at the same moment, which
/// is why fan-out is the normal mode of operation here rather than a fallback.
///
/// Events are ephemeral (kind 20000, NIP-01): relays broadcast them to current
/// subscribers and keep no copy afterwards, matching the "nothing is retained"
/// property the MQTT channel got from QoS 0 without retain.
class NostrAnswerChannel implements AnswerChannel {
  /// Measured reachable from the target network, with the full
  /// subscribe -> publish -> deliver round trip completing in 115-168 ms.
  /// `relay.damus.io` and `relay.nostr.band` are kept as spares: both failed
  /// during that probe, which is exactly the risk fan-out exists to absorb.
  static const defaultRelays = <String>[
    'wss://nos.lol',
    'wss://nostr.mom',
    'wss://relay.primal.net',
    'wss://relay.damus.io',
    'wss://relay.nostr.band',
  ];

  /// Ephemeral range: relays forward but never store.
  static const int eventKind = 20000;

  final List<String> relays;
  final Duration connectTimeout;

  final _controller = StreamController<Uint8List>.broadcast();
  final _connections = <String, WebSocketChannel>{};
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _seenEventIds = <String>{};

  /// Throwaway identity, regenerated per channel. Nostr demands a signature;
  /// it does not demand that the signer mean anything, and a stable key would
  /// let a relay operator link one transfer to the next.
  final Uint8List _secretKey;

  NostrAnswerChannel({
    List<String>? relays,
    this.connectTimeout = const Duration(seconds: 8),
    Uint8List? secretKey,
  })  : relays = relays ?? defaultRelays,
        _secretKey = secretKey ?? _newSecretKey();

  static Uint8List _newSecretKey() {
    final random = Random.secure();
    // Rejection sampling would be pedantic here: the curve order is within
    // 2^-128 of 2^256, so a draw outside range is not going to happen.
    return Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)));
  }

  @override
  String get name => 'nostr(${_connections.length}/${relays.length})';

  @override
  Stream<Uint8List> get answers => _controller.stream;

  @override
  Future<void> subscribe(String topic) async {
    final results = await Future.wait(
      relays.map((relay) => _openAndSubscribe(relay, topic)),
    );
    final live = results.where((ok) => ok).length;
    if (live == 0) {
      throw StateError(
          'no Nostr relay reachable (${relays.join(', ')})');
    }
    AppLogger.info('Nostr rendezvous listening on $live/${relays.length} relays',
        tag: 'SIGNALING');
  }

  Future<bool> _openAndSubscribe(String relay, String topic) async {
    try {
      final socket = WebSocketChannel.connect(Uri.parse(relay));
      await socket.ready.timeout(connectTimeout);
      _connections[relay] = socket;

      _subscriptions.add(socket.stream.listen(
        (raw) => _onRelayMessage(relay, raw),
        onError: (Object e) => AppLogger.warning(
            'Nostr relay $relay errored: $e',
            tag: 'SIGNALING'),
        cancelOnError: false,
      ));

      socket.sink.add(jsonEncode([
        'REQ',
        subscriptionId(topic),
        {
          'kinds': [eventKind],
          '#t': [topic],
        }
      ]));
      return true;
    } catch (e) {
      AppLogger.warning('Nostr relay $relay unavailable: $e', tag: 'SIGNALING');
      return false;
    }
  }

  void _onRelayMessage(String relay, dynamic raw) {
    if (raw is! String) return;
    try {
      final message = jsonDecode(raw) as List<dynamic>;
      if (message.isEmpty) return;
      switch (message[0]) {
        case 'EVENT':
          if (message.length < 3) return;
          final event = message[2] as Map<String, dynamic>;
          final id = event['id'] as String?;
          // The same answer arrives once per healthy relay.
          if (id != null && !_seenEventIds.add(id)) return;
          final payload = base64.decode(event['content'] as String);
          if (!_controller.isClosed) {
            _controller.add(Uint8List.fromList(payload));
          }
        case 'NOTICE':
          AppLogger.warning('Nostr relay $relay notice: ${message.skip(1)}',
              tag: 'SIGNALING');
        case 'CLOSED':
          AppLogger.warning('Nostr relay $relay closed the subscription: '
              '${message.skip(1)}', tag: 'SIGNALING');
      }
    } catch (e) {
      // Public relays carry the whole network's traffic; anything we cannot
      // parse belongs to somebody else.
      AppLogger.warning('Discarded unparsable Nostr message from $relay: $e',
          tag: 'SIGNALING');
    }
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    final event = buildEvent(topic, payload);
    final encoded = jsonEncode(['EVENT', event]);

    final results = await Future.wait(
      relays.map((relay) async {
        try {
          var socket = _connections[relay];
          if (socket == null) {
            socket = WebSocketChannel.connect(Uri.parse(relay));
            await socket.ready.timeout(connectTimeout);
            _connections[relay] = socket;
          }
          socket.sink.add(encoded);
          return true;
        } catch (e) {
          AppLogger.warning('Nostr publish to $relay failed: $e',
              tag: 'SIGNALING');
          return false;
        }
      }),
    );

    if (!results.contains(true)) {
      throw StateError('could not publish the answer to any Nostr relay');
    }

    // The sink only queues the frame; give the sockets a moment to flush
    // before the caller tears the channel down.
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  /// Builds a signed NIP-01 event. The id is the SHA-256 of the canonical
  /// serialization `[0, pubkey, created_at, kind, tags, content]`.
  @visibleForTesting
  Map<String, dynamic> buildEvent(String topic, Uint8List payload) {
    final pubkey = _hex(Bip340.publicKey(_secretKey));
    final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tags = [
      ['t', topic]
    ];
    final content = base64.encode(payload);

    final serialized =
        jsonEncode([0, pubkey, createdAt, eventKind, tags, content]);
    final id = Uint8List.fromList(sha256.convert(utf8.encode(serialized)).bytes);

    final random = Random.secure();
    final auxRand =
        Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));

    return {
      'id': _hex(id),
      'pubkey': pubkey,
      'created_at': createdAt,
      'kind': eventKind,
      'tags': tags,
      'content': content,
      'sig': _hex(Bip340.sign(id, _secretKey, auxRand)),
    };
  }

  /// Relays cap subscription ids at 64 characters.
  @visibleForTesting
  String subscriptionId(String topic) {
    final clean = topic.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return 'qs${clean.length > 32 ? clean.substring(0, 32) : clean}';
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final socket in _connections.values) {
      try {
        await socket.sink.close();
      } catch (_) {}
    }
    _connections.clear();
    if (!_controller.isClosed) await _controller.close();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:quickshare/core/crypto/bip340.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/nostr_code_mailbox.dart';

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
  /// These endpoints passed live bidirectional signed ephemeral-event delivery
  /// on 2026-11-08. Subscription acknowledgements alone do not prove delivery.
  static const defaultRelays = <String>[
    'wss://relay.nostr.net',
    'wss://nostr-pub.wellorder.net',
    'wss://relay.ditto.pub',
  ];

  /// Ephemeral range: relays forward but never store.
  static const int eventKind = 20000;

  final List<String> relays;
  final Duration connectTimeout;

  final _controller = StreamController<Uint8List>.broadcast();
  final _topics = <String>{};
  StreamSubscription<dynamic>? _messages;
  bool _closed = false;
  final Uint8List _secretKey;
  final Duration confirmTimeout;
  final Duration publishTimeout;
  final WebSocketChannel Function(Uri uri)? _connect;
  late final NostrCodeMailbox _mailbox = NostrCodeMailbox(
    relays: relays,
    secretKey: _secretKey,
    connectTimeout: connectTimeout,
    confirmTimeout: confirmTimeout,
    publishTimeout: publishTimeout,
    connect: _connect,
  );

  NostrAnswerChannel({
    List<String>? relays,
    this.connectTimeout = const Duration(seconds: 2),
    this.confirmTimeout = const Duration(milliseconds: 1500),
    this.publishTimeout = const Duration(seconds: 4),
    Uint8List? secretKey,
    WebSocketChannel Function(Uri uri)? connect,
  })  : relays = relays ?? defaultRelays,
        _secretKey = secretKey ?? _newSecretKey(),
        _connect = connect;

  static Uint8List _newSecretKey() {
    final random = Random.secure();
    // Rejection sampling would be pedantic here: the curve order is within
    // 2^-128 of 2^256, so a draw outside range is not going to happen.
    return Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)));
  }

  @override
  String get name => _mailbox.name;

  @override
  Stream<Uint8List> get answers => _controller.stream;

  @override
  Future<void> subscribe(String topic) async {
    if (_closed || relays.isEmpty) {
      throw StateError('no Nostr relays available');
    }
    _topics.add(topic);
    _messages ??= _mailbox.messages.listen((message) {
      if (_topics.contains(message.topic) && !_controller.isClosed) {
        _controller.add(message.payload);
      }
    });
    try {
      await _mailbox.subscribe(topic);
    } catch (_) {
      throw StateError('no Nostr relay confirmed the answer subscription');
    }
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    if (_closed || relays.isEmpty) {
      throw StateError('no Nostr relays available');
    }
    try {
      await _mailbox.publish(topic, payload);
    } catch (_) {
      throw StateError('no Nostr relay accepted the answer event');
    }
  }

  /// Builds a signed NIP-01 event. See [buildNostrEvent].
  @visibleForTesting
  Map<String, dynamic> buildEvent(String topic, Uint8List payload) =>
      buildNostrEvent(secretKey: _secretKey, topic: topic, payload: payload);

  /// Relays cap subscription ids at 64 characters.
  @visibleForTesting
  String subscriptionId(String topic) {
    final clean = topic.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return 'qs${clean.length > 32 ? clean.substring(0, 32) : clean}';
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _topics.clear();
    await _messages?.cancel();
    await _mailbox.close();
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}

/// A signed NIP-01 event carrying [payload] under the tag `t = topic`. The id
/// is the SHA-256 of the canonical serialization
/// `[0, pubkey, created_at, kind, tags, content]`.
///
/// Shared by every Nostr-backed channel so that what a relay checks before it
/// forwards an event is written once.
Map<String, dynamic> buildNostrEvent({
  required Uint8List secretKey,
  required String topic,
  required Uint8List payload,
}) {
  String hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  final pubkey = hex(Bip340.publicKey(secretKey));
  final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final tags = [
    ['t', topic]
  ];
  final content = base64.encode(payload);

  final serialized = jsonEncode(
      [0, pubkey, createdAt, NostrAnswerChannel.eventKind, tags, content]);
  final id = Uint8List.fromList(sha256.convert(utf8.encode(serialized)).bytes);

  final random = Random.secure();
  final auxRand =
      Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));

  return {
    'id': hex(id),
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': NostrAnswerChannel.eventKind,
    'tags': tags,
    'content': content,
    'sig': hex(Bip340.sign(id, secretKey, auxRand)),
  };
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/core/signaling/nostr_answer_channel.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// A [CodeMailbox] on public Nostr relays: WSS on 443, ephemeral kind 20000,
/// which relays forward to whoever is subscribed at that moment and keep no
/// copy of.
///
/// That last part shapes the protocol on top: a subscriber that was late
/// misses the message for good, so each end subscribes before it speaks.
///
/// Unlike [NostrAnswerChannel] — one topic, one answer, a few seconds of life —
/// this one is held open for as long as an offer's code is on screen, so it
/// lists several topics on a single connection per relay and reconnects a
/// relay that drops, re-asking for every topic that is still wanted.
class NostrCodeMailbox implements CodeMailbox {
  NostrCodeMailbox({
    List<String>? relays,
    this.connectTimeout = const Duration(seconds: 2),
    this.confirmTimeout = const Duration(milliseconds: 1500),
    this.reconnectDelay = const Duration(seconds: 3),
    this.maxReconnects = 5,
    Uint8List? secretKey,
    WebSocketChannel Function(Uri uri)? connect,
  })  : relays = relays ?? NostrAnswerChannel.defaultRelays,
        _secretKey = secretKey ?? _newSecretKey(),
        _connect = connect ?? WebSocketChannel.connect {
    for (final url in this.relays) {
      _links[url] = _Link(url);
    }
  }

  final List<String> relays;
  final Duration connectTimeout;

  /// How long [subscribe] waits for a relay to say it has registered the
  /// subscription (`EOSE`) before taking its word for it. Registering is what
  /// makes the difference between a message that is delivered and one that is
  /// lost to a subscriber the relay had not heard of yet.
  final Duration confirmTimeout;

  /// The first wait before a dropped relay is tried again; doubled each time.
  final Duration reconnectDelay;
  final int maxReconnects;

  /// Throwaway identity. Nostr demands a signature and does not demand that
  /// the signer mean anything; a stable key would let a relay operator link
  /// one transfer to the next.
  final Uint8List _secretKey;
  final WebSocketChannel Function(Uri uri) _connect;

  /// Relays cap what one event may carry; so do we, before decoding it.
  static const int _maxContentChars = 16 * 1024;
  static const int _eventMemory = 512;

  final _links = <String, _Link>{};
  final _topics = <String, String>{}; // topic -> subscription id
  final _controller = StreamController<MailboxMessage>.broadcast();
  final _seenOrder = <String>[];
  final _seen = <String>{};
  bool _closed = false;

  static Uint8List _newSecretKey() {
    final random = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)));
  }

  @override
  String get name =>
      'nostr(${_links.values.where((l) => l.socket != null).length}'
      '/${relays.length})';

  @override
  Stream<MailboxMessage> get messages => _controller.stream;

  /// How many relays are connected right now.
  int get connectedRelays => _links.values.where((l) => l.socket != null).length;

  /// Subscription ids are the topic's hash, not the topic: the id is capped at
  /// 64 characters and has to be distinct per topic on one socket.
  static String subscriptionId(String topic) =>
      'cm${sha256.convert(utf8.encode(topic)).toString().substring(0, 24)}';

  @override
  Future<void> subscribe(String topic) async {
    if (_closed) throw const MailboxUnavailable('the mailbox is closed');
    if (relays.isEmpty) throw const MailboxUnavailable('no Nostr relays');
    _topics.putIfAbsent(topic, () => subscriptionId(topic));

    final first = Completer<void>();
    var pending = relays.length;
    for (final link in _links.values) {
      unawaited(() async {
        final ok = await _ensure(link);
        if (ok) {
          await _request(link, topic);
          if (!first.isCompleted) first.complete();
        }
        pending--;
        if (pending == 0 && !first.isCompleted) {
          first.completeError(MailboxUnavailable(
              'no Nostr relay reachable (${relays.join(', ')})'));
        }
      }());
    }
    await first.future;
  }

  @override
  Future<void> unsubscribe(String topic) async {
    final id = _topics.remove(topic);
    if (id == null) return;
    for (final link in _links.values) {
      link.registered.remove(id);
      _send(link, jsonEncode(['CLOSE', id]));
    }
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    if (_closed) throw const MailboxUnavailable('the mailbox is closed');
    if (relays.isEmpty) throw const MailboxUnavailable('no Nostr relays');
    final encoded = jsonEncode([
      'EVENT',
      buildNostrEvent(secretKey: _secretKey, topic: topic, payload: payload),
    ]);

    final sent = Completer<void>();
    var pending = relays.length;
    for (final link in _links.values) {
      unawaited(() async {
        final ok = await _ensure(link);
        if (ok && _send(link, encoded) && !sent.isCompleted) sent.complete();
        pending--;
        if (pending == 0 && !sent.isCompleted) {
          sent.completeError(MailboxUnavailable(
              'could not publish to any Nostr relay (${relays.join(', ')})'));
        }
      }());
    }
    await sent.future;
  }

  // ─── Connections ───────────────────────────────────────────────────────

  Future<bool> _ensure(_Link link) {
    if (_closed) return Future.value(false);
    if (link.socket != null) return Future.value(true);
    return link.connecting ??= _open(link).whenComplete(() {
      link.connecting = null;
    });
  }

  Future<bool> _open(_Link link) async {
    WebSocketChannel? socket;
    try {
      socket = _connect(Uri.parse(link.url));
      await socket.ready.timeout(connectTimeout);
      if (_closed) {
        unawaited(socket.sink.close().catchError((_) {}));
        return false;
      }
      link.socket = socket;
      link.listening = socket.stream.listen(
        (raw) => _onRelayMessage(link, raw),
        onError: (Object e) {
          AppLogger.warning('Nostr relay ${link.url} errored: ${e.runtimeType}',
              tag: 'SIGNALING');
          _lost(link, socket!);
        },
        onDone: () => _lost(link, socket!),
        cancelOnError: false,
      );
      // Every topic still wanted, on a socket that is new to the relay.
      for (final entry in _topics.entries) {
        link.registered.putIfAbsent(entry.value, Completer<void>.new);
        _send(link, _requestFrame(entry.key, entry.value));
      }
      return true;
    } catch (e) {
      AppLogger.warning('Nostr relay ${link.url} unavailable: ${e.runtimeType}',
          tag: 'SIGNALING');
      if (socket != null) {
        unawaited(socket.sink.close().catchError((_) {}));
      }
      return false;
    }
  }

  /// A relay went away. Tried again a few times, further apart each time, for
  /// as long as anything is still wanted.
  void _lost(_Link link, WebSocketChannel socket) {
    if (!identical(link.socket, socket)) return;
    link.socket = null;
    link.registered.clear();
    unawaited(link.listening?.cancel());
    link.listening = null;
    if (_closed || _topics.isEmpty || link.reconnects >= maxReconnects) return;
    final wait = reconnectDelay * (1 << link.reconnects);
    link.reconnects++;
    link.retry?.cancel();
    link.retry = Timer(wait, () {
      link.retry = null;
      if (!_closed) unawaited(_ensure(link));
    });
  }

  bool _send(_Link link, String frame) {
    final socket = link.socket;
    if (socket == null) return false;
    try {
      socket.sink.add(frame);
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _requestFrame(String topic, String id) => jsonEncode([
        'REQ',
        id,
        {
          'kinds': [NostrAnswerChannel.eventKind],
          '#t': [topic],
        }
      ]);

  /// Asks [link]'s relay for [topic] and waits, for a moment, until the relay
  /// says it is listening.
  Future<void> _request(_Link link, String topic) async {
    final id = _topics[topic];
    if (id == null) return;
    // Asked for already — by the connection that has just been opened, which
    // asks for every topic wanted — is asked for once.
    final asked = link.registered.containsKey(id);
    final registered = link.registered.putIfAbsent(id, Completer<void>.new);
    if (!asked && !_send(link, _requestFrame(topic, id))) return;
    try {
      await registered.future.timeout(confirmTimeout);
    } on TimeoutException {
      // A relay that never says so is taken at its word that it got the
      // frame.
    }
  }

  // ─── Incoming ──────────────────────────────────────────────────────────

  void _onRelayMessage(_Link link, dynamic raw) {
    if (raw is! String || _closed) return;
    try {
      final message = jsonDecode(raw);
      if (message is! List || message.isEmpty) return;
      switch (message[0]) {
        case 'EVENT':
          if (message.length < 3 || message[2] is! Map) return;
          _onEvent(link, Map<String, dynamic>.from(message[2] as Map));
        case 'EOSE':
          if (message.length >= 2 && message[1] is String) {
            final done = link.registered[message[1]];
            if (done != null && !done.isCompleted) done.complete();
          }
        case 'OK':
          if (message.length >= 3 && message[2] == false) {
            AppLogger.warning(
                'Nostr relay ${link.url} refused an event: '
                '${message.length > 3 ? message[3] : ''}',
                tag: 'SIGNALING');
          }
        case 'NOTICE':
          AppLogger.warning('Nostr relay ${link.url} notice: ${message.skip(1)}',
              tag: 'SIGNALING');
        case 'CLOSED':
          AppLogger.warning(
              'Nostr relay ${link.url} closed a subscription: '
              '${message.skip(1)}',
              tag: 'SIGNALING');
      }
    } catch (e) {
      // Public relays carry the whole network's traffic; anything unreadable
      // belongs to somebody else.
      AppLogger.debug('Discarded an unreadable Nostr frame from ${link.url}',
          tag: 'SIGNALING');
    }
  }

  void _onEvent(_Link link, Map<String, dynamic> event) {
    if (event['kind'] != NostrAnswerChannel.eventKind) return;
    final content = event['content'];
    final tags = event['tags'];
    if (content is! String || content.length > _maxContentChars) return;
    if (tags is! List) return;

    // Trust the tag, not the subscription id the relay chose to report.
    String? topic;
    for (final tag in tags) {
      if (tag is List &&
          tag.length >= 2 &&
          tag[0] == 't' &&
          tag[1] is String &&
          _topics.containsKey(tag[1])) {
        topic = tag[1] as String;
        break;
      }
    }
    if (topic == null) return;

    final id = event['id'];
    if (id is String && !_remember(id)) return;

    final Uint8List payload;
    try {
      payload = base64.decode(content);
    } catch (_) {
      return;
    }
    if (!_controller.isClosed) {
      _controller.add(MailboxMessage(topic, payload, source: 'nostr'));
    }
  }

  bool _remember(String id) {
    if (!_seen.add(id)) return false;
    _seenOrder.add(id);
    if (_seenOrder.length > _eventMemory) _seen.remove(_seenOrder.removeAt(0));
    return true;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _topics.clear();
    for (final link in _links.values) {
      link.retry?.cancel();
      link.retry = null;
      await link.listening?.cancel();
      link.listening = null;
      final socket = link.socket;
      link.socket = null;
      if (socket != null) {
        try {
          await socket.sink.close().timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
    }
    // Not awaited: the future of a broadcast controller whose listeners have
    // already gone is not one to wait on.
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}

class _Link {
  _Link(this.url);

  final String url;
  WebSocketChannel? socket;

  // Cancelled when the relay is lost and in [NostrCodeMailbox.close].
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? listening;
  Future<bool>? connecting;
  Timer? retry;
  int reconnects = 0;

  /// Subscription ids this relay has been asked for and has not yet confirmed.
  final registered = <String, Completer<void>>{};
}

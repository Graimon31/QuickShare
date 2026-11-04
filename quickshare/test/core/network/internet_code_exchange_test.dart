// Finding an internet sender by its code, end to end, on a public mailbox that
// is as unkind as the real ones.
//
// Both ends are the real classes (`InternetCodeSender`, `InternetCodeSearch`)
// and so is the cryptography; only the mailbox is a fake, and it can lose a
// message to a subscriber that was late, repeat it, delay it, let it be
// overtaken, go down on one channel, and forge. Time is `fake_async`, so the
// 20-second search, the 90-second dialog and the 60-second hold are exact.
//
// What is checked, in the order a person would worry about it:
//   1. the right code gets exactly the offer, and nothing else does;
//   2. nothing public holds the code, the public id, the hint or the offer;
//   3. a wrong code, a foreign sender, a forgery and a replay all fail
//      quietly, and none of them stops the search for the right one;
//   4. every step has a way out: a loss, a refusal, a silence, a cancel;
//   5. the sender's budget holds.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/internet_code.dart';
import 'package:quickshare/core/network/internet_code_sender.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/receiver/data/client/internet_code_search.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';

import '../../support/fake_mailbox.dart';
import '../../support/sample_offer.dart';

final _epoch = DateTime.utc(2026, 11, 4, 12);
const _code = SessionCode('4815162342');
const _inline = InternetCodePake(inline: true);

/// Room for every attempt of a code to be waiting at once, so that a test of
/// the budget is a test of the budget and not of the cap on open exchanges.
const _roomy = InternetCodeTimings(maxPendingExchanges: 64);

/// Another code whose twelve bits agree with [code]'s: the same topic, a
/// different secret. A stranger's session on the shared topic.
SessionCode _neighbour(SessionCode code) {
  final random = Random(42);
  while (true) {
    final other = SessionCode.generate(random);
    if (other != code && InternetCode.bucket(other) == InternetCode.bucket(code)) {
      return other;
    }
  }
}

Uint8List _shareFor(SessionCode code) =>
    Spake2.start(role: Spake2Role.a, w: InternetCodePake.passwordScalar(code))
        .share;

/// Everything a test needs: the fake mailbox, a sender listening on it, and a
/// receiver search that can be started against it.
class _World {
  _World(
    this.async, {
    Duration latency = Duration.zero,
    this.timings = const InternetCodeTimings(),
    this.code = _code,
    String? offer,
  }) : offer = offer ?? sampleOffer() {
    hub.latency = latency;
  }

  final FakeAsync async;
  final InternetCodeTimings timings;
  final SessionCode code;
  final String offer;
  final hub = FakeMailboxHub();

  final dialogs = <String>[];
  final holds = <String>[];
  final pendingAnswers = <Completer<bool>>[];
  bool autoApprove = true;
  int offerReads = 0;

  late FakeMailbox senderBox;
  late InternetCodeSender sender;

  DateTime now() => _epoch.add(async.elapsed);

  InternetCodeSender buildSender({
    SessionCode? forCode,
    CodeMailbox? mailbox,
  }) {
    if (mailbox == null) senderBox = hub.endpoint('sender');
    return sender = InternetCodeSender(
      mailbox: mailbox ?? senderBox,
      code: forCode ?? code,
      offer: () async {
        offerReads++;
        return offer;
      },
      approve: (name) {
        dialogs.add(name);
        if (autoApprove) return Future.value(true);
        final answer = Completer<bool>();
        pendingAnswers.add(answer);
        return answer.future;
      },
      hold: (r) => holds.add('hold $r'),
      release: (r) => holds.add('release $r'),
      timings: timings,
      pake: _inline,
      now: now,
    );
  }

  Object? startError;
  void startSender({SessionCode? forCode, CodeMailbox? mailbox}) {
    buildSender(forCode: forCode, mailbox: mailbox)
        .start()
        .catchError((Object e) => startError = e);
    settle();
  }

  // ─── The receiver ────────────────────────────────────────────────────

  CodeSessionOutcome? outcome;
  late CodeSearchControl control;
  late CodeSearchArbiter arbiter;
  FakeMailbox? receiverBox;

  void search({
    String name = 'Alice laptop',
    SessionCode? typed,
    CodeMailbox Function()? mailbox,
  }) {
    outcome = null;
    control = CodeSearchControl();
    arbiter = CodeSearchArbiter(control);
    final gate = arbiter.gate('internet');
    InternetCodeSearch(
      mailbox: mailbox ?? () => receiverBox = hub.endpoint('receiver'),
      timings: timings,
      pake: _inline,
      now: now,
    )
        .run(typed ?? code, deviceName: name, gate: gate)
        .then((o) => outcome = o);
    settle();
  }

  void settle() => async.flushMicrotasks();

  void pass(Duration d) {
    async.elapse(d);
    async.flushMicrotasks();
  }

  // ─── Reading the mailbox as its operator would ──────────────────────

  String get requestTopic => InternetCode.requestTopic(code);

  List<PublishedMessage> on(String topic) =>
      hub.published.where((m) => m.topic == topic).toList();

  List<CodeRequest> get requests => [
        for (final m in on(requestTopic))
          if (CodeRequest.tryParse(m.payload) case final r?) r
      ];

  List<CodeReply> get replies => [
        for (final m in hub.published)
          if (CodeReply.tryParse(m.payload) case final r?) r
      ];

  /// A request as a stranger would write it, published straight on the topic.
  CodeRequest inject({
    SessionCode? as,
    Duration age = Duration.zero,
    Uint8List? n,
    Uint8List? pA,
    String? reply,
  }) {
    final request = CodeRequest(
      n: n ?? InternetCode.randomBytes(InternetCode.nonceLength),
      pA: pA ?? _shareFor(as ?? code),
      reply: reply ?? InternetCode.newReplyTopic(),
      ts: now().subtract(age).millisecondsSinceEpoch ~/ 1000,
    );
    hub.inject(requestTopic, request.encode());
    return request;
  }
}

/// A receiver written by hand, so a test can stop it at any step or have it
/// say something wrong.
class _ByHand {
  _ByHand(this.w, SessionCode typed)
      : _begun = Spake2.start(
            role: Spake2Role.a, w: InternetCodePake.passwordScalar(typed));

  final _World w;
  final Spake2 _begun;
  final n = InternetCode.randomBytes(InternetCode.nonceLength);
  final replyTopic = InternetCode.newReplyTopic();
  Spake2Keys? keys;
  InternetCodeKeys? derived;

  void ask() {
    final box = w.hub.endpoint('by-hand')..subscribed.add(replyTopic);
    box.publish(
        w.requestTopic,
        CodeRequest(
          n: n,
          pA: _begun.share,
          reply: replyTopic,
          ts: w.now().millisecondsSinceEpoch ~/ 1000,
        ).encode());
    w.settle();
  }

  CodeReply? get reply {
    for (final m in w.on(replyTopic)) {
      final r = CodeReply.tryParse(m.payload);
      if (r != null) return r;
    }
    return null;
  }

  /// Derives the keys from the sender's reply; true when its proof verifies.
  bool prove() {
    final r = reply;
    if (r == null) return false;
    keys = _begun.finish(r.pB,
        identityA: InternetCodePake.identityA(n),
        identityB: InternetCodePake.identityB(n),
        aad: utf8.encode('${InternetCode.domain}/pake'));
    derived = InternetCodeKeys.derive(keys!.ke, n);
    return keys!.verifies(Spake2Role.b, r.cB);
  }

  void confirm({Uint8List? cA, String name = 'By Hand', Uint8List? key}) {
    final box = w.hub.endpoint('by-hand-confirm');
    InternetCodeSeal.seal(
      key: key ?? derived!.aeadKey,
      role: SealRole.confirm,
      n: n,
      plaintext: utf8.encode(jsonEncode({
        'cA': InternetCode.encode(cA ?? keys!.confirmationA),
        'name': name,
      })),
    ).then((sealed) => box.publish(derived!.confirmTopic, sealed));
    w.settle();
  }
}

void main() {
  group('with the right code', () {
    test('the receiver gets exactly the sender\'s offer, after a person said yes',
        () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.search();

        expect(w.outcome, isA<CodeSessionFoundOnline>());
        expect((w.outcome as CodeSessionFoundOnline).payload, w.offer);
        expect(w.dialogs, ['Alice laptop'], reason: 'one dialog, with the name');
        expect(w.offerReads, 1);
      });
    });

    test('and goes on exactly as a scan would: the real decoder reads it', () {
      fakeAsync((async) {
        final w = _World(async, offer: sampleOffer(name: 'trip.mov'))
          ..startSender();
        w.search();

        final payload = (w.outcome as CodeSessionFoundOnline).payload;
        final decoded = QRPayloadDecoder().decode(payload);
        expect(decoded.mode, QRPayloadDecoder.serverlessMode);
        expect(decoded.sdpOffer, payload);
        expect(decoded.fileName, 'trip.mov');
      });
    });

    test('nothing is handed over until the person has answered', () {
      fakeAsync((async) {
        final w = _World(async)
          ..autoApprove = false
          ..startSender();
        w.search();

        expect(w.dialogs, hasLength(1));
        expect(w.outcome, isNull, reason: 'still waiting for the person');
        expect(w.offerReads, 0, reason: 'the offer is not even read yet');
        final before = w.hub.published.length;

        w.pass(const Duration(seconds: 30));
        expect(w.hub.published.length, before, reason: 'and nothing is sent');

        w.pendingAnswers.single.complete(true);
        w.settle();
        expect(w.outcome, isA<CodeSessionFoundOnline>());
        expect(w.offerReads, 1);
      });
    });

    test('each side listens before it provokes an answer', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.search();

        int at(String entry) => w.hub.log.indexWhere((e) => e.startsWith(entry));
        final request = w.requests.single;
        final confirm = w.on(w.requestTopic).length; // keeps the log honest
        expect(confirm, 1);

        // The receiver: reply topic before the request, payload topic before
        // the confirmation.
        expect(at('receiver subscribe ${request.reply}'),
            lessThan(at('receiver publish ${w.requestTopic}')));
        final payloadTopic = w.hub.log
            .firstWhere((e) =>
                e.startsWith('receiver subscribe') &&
                !e.endsWith(request.reply))
            .split(' ')
            .last;
        final confirmTopic = w.hub.log
            .lastWhere((e) => e.startsWith('receiver publish'))
            .split(' ')
            .last;
        expect(at('receiver subscribe $payloadTopic'),
            lessThan(at('receiver publish $confirmTopic')));

        // The sender: the confirmation topic before the reply that asks for it.
        expect(at('sender subscribe $confirmTopic'),
            lessThan(at('sender publish ${request.reply}')));
      });
    });

    test('the whole mailbox is released when the search ends', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.search();

        expect(w.outcome, isA<CodeSessionFoundOnline>());
        expect(w.receiverBox!.isClosed, isTrue);
        expect(w.receiverBox!.subscribed, isEmpty);
        // The sender is still listening on the request topic and nothing else.
        expect(w.hub.listenedTopics, {w.requestTopic});
      });
    });
  });

  group('what the public mailbox sees', () {
    test('no message or topic holds the code, the public id, the hint or the '
        'offer', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.search();
        expect(w.outcome, isA<CodeSessionFoundOnline>());

        final secrets = <String, String>{
          'the code': _code.code,
          'the code, as shown': _code.display,
          'the public id': _code.publicId,
          'the session token': _code.sessionToken,
          'the offer': w.offer,
          'the start of the offer': w.offer.substring(0, 12),
          'the middle of the offer': w.offer.substring(30, 60),
          'the seed of the offer': base64Url.encode(utf8.encode(w.offer.substring(3, 30))),
        };
        // The hint is two hex digits: not worth searching a message for, but
        // it must not be a topic.
        for (final message in w.hub.published) {
          final asText = latin1.decode(message.payload);
          final asBase64 = base64.encode(message.payload);
          final asBase64Url = base64Url.encode(message.payload);
          final asHex = message.payload
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          for (final entry in secrets.entries) {
            for (final form in [asText, asBase64, asBase64Url, asHex]) {
              expect(form.contains(entry.value), isFalse,
                  reason: '${entry.key} is public on ${message.topic}');
            }
          }
          for (final entry in secrets.entries) {
            expect(message.topic.contains(entry.value), isFalse,
                reason: '${entry.key} is a topic');
          }
          expect(message.topic, isNot(_code.discoveryHint));
          expect(message.topic, isNot(_code.publicId));
        }
      });
    });

    test('the request is the only message in the clear, and it names no code',
        () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.search();

        final readable = <String>[];
        for (final m in w.hub.published) {
          try {
            readable.add(utf8.decode(m.payload));
          } catch (_) {}
        }
        // Request and reply are JSON; everything after them is sealed.
        expect(readable, hasLength(2));
        expect(readable.first, contains('"pA"'));
        expect(readable.last, contains('"cB"'));
        expect(w.hub.published, hasLength(4));
      });
    });

    test('the request topic is shared: another session\'s sender on it hears '
        'the request and learns nothing it can use', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        final stranger = _neighbour(_code);
        final strangerBox = w.hub.endpoint('stranger');
        final strangerSender = InternetCodeSender(
          mailbox: strangerBox,
          code: stranger,
          offer: () async => 'QS1stranger',
          approve: (_) async => true,
          pake: _inline,
          now: w.now,
        )..start();
        w.settle();
        expect(strangerSender.requestTopic, w.requestTopic);

        w.search();

        expect(w.outcome, isA<CodeSessionFoundOnline>());
        expect((w.outcome as CodeSessionFoundOnline).payload, w.offer);
        // It answered the request too — and was not believed.
        expect(strangerSender.attempts, 1);
        expect(w.replies, hasLength(2));
        strangerSender.stop();
      });
    });
  });

  group('with the wrong code', () {
    test('nothing is shown, read or sent, and the search says not found after '
        'twenty seconds', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        // Almost always a different topic, so nobody even hears the request.
        var typed = const SessionCode('0000000000');
        if (InternetCode.bucket(typed) == InternetCode.bucket(_code)) {
          typed = const SessionCode('0000000001');
        }
        w.search(typed: typed);

        w.pass(const Duration(seconds: 19));
        expect(w.outcome, isNull, reason: 'still looking');
        w.pass(const Duration(seconds: 2));

        expect(w.outcome, isA<CodeSessionNotFound>());
        expect(w.dialogs, isEmpty);
        expect(w.offerReads, 0);
        expect(w.sender.attempts, 0, reason: 'nothing reached the sender');
        expect(w.hub.published, hasLength(1), reason: 'only the request');
        expect(w.receiverBox!.isClosed, isTrue);
        expect(w.receiverBox!.subscribed, isEmpty);
      });
    });

    test('a sender whose code differs only past the twelve bits is not '
        'believed either', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.search(typed: _neighbour(_code));

        w.pass(const Duration(seconds: 21));
        expect(w.outcome, isA<CodeSessionNotFound>());
        expect(w.dialogs, isEmpty);
        expect(w.offerReads, 0);
        expect(w.sender.attempts, 1, reason: 'it answered, and was not believed');
        expect(w.hub.published, hasLength(2),
            reason: 'a request and a reply, and no confirmation, no offer');
      });
    });

    test('an answer from somebody else\'s sender on the same topic does not '
        'stop the search for the right one', () {
      fakeAsync((async) {
        final w = _World(async);
        // The stranger answers at once; the real sender takes five seconds.
        final stranger = _neighbour(_code);
        final strangerBox = w.hub.endpoint('stranger');
        InternetCodeSender(
          mailbox: strangerBox,
          code: stranger,
          offer: () async => 'QS1stranger',
          approve: (_) async => true,
          pake: _inline,
          now: w.now,
        ).start();
        w.settle();
        w.startSender();
        w.senderBox.publishDelay = const Duration(seconds: 5);

        w.search();
        w.pass(const Duration(seconds: 1));
        expect(w.outcome, isNull,
            reason: 'the stranger\'s answer is not the end of the search');
        expect(w.replies, hasLength(2), reason: 'both answered the request');

        // Five seconds for its reply, five more for its offer.
        w.pass(const Duration(seconds: 16));
        expect(w.outcome, isA<CodeSessionFoundOnline>());
        expect((w.outcome as CodeSessionFoundOnline).payload, w.offer);
      });
    });

    test('junk on the reply topic neither crashes nor ends the search', () {
      fakeAsync((async) {
        final w = _World(async)
          ..startSender()
          ..senderBox.publishDelay = const Duration(seconds: 3);
        w.search();
        final replyTopic = w.requests.single.reply;

        final junk = [
          Uint8List(0),
          Uint8List.fromList([0xff, 0xfe, 0xfd]),
          Uint8List.fromList(utf8.encode('{"v":1,"pB":')),
          Uint8List.fromList(utf8.encode('[]')),
          Uint8List.fromList(utf8.encode('{"v":1,"pB":"x","cB":"y"}')),
          Uint8List(100000),
          Uint8List.fromList(utf8.encode(jsonEncode({
            'v': 1,
            'pB': InternetCode.encode(Uint8List.fromList([4, ...List.filled(64, 7)])),
            'cB': InternetCode.encode(Uint8List(32)),
          }))),
        ];
        for (final bytes in junk) {
          w.hub.inject(replyTopic, bytes);
        }
        w.settle();
        expect(w.outcome, isNull);

        w.pass(const Duration(seconds: 10));
        expect(w.outcome, isA<CodeSessionFoundOnline>());
      });
    });

    test('a reply in a newer version says "update", not "wrong code"', () {
      fakeAsync((async) {
        final w = _World(async);
        // Nobody listens on the topic; a newer sender's reply is injected.
        w.search();
        final replyTopic = w.requests.single.reply;
        w.hub.inject(
            replyTopic,
            Uint8List.fromList(utf8.encode(jsonEncode({
              'v': 2,
              'pB': InternetCode.encode(Uint8List(65)),
              'cB': InternetCode.encode(Uint8List(32)),
            }))));
        w.pass(const Duration(seconds: 21));

        expect(w.outcome, isA<CodeSessionUpdateRequired>());
      });
    });
  });

  group('a forged exchange', () {
    test('another pB, or a damaged cB, in the reply is not believed', () {
      for (final tamper in <Uint8List Function(Uint8List)>[
        (original) {
          final r = CodeReply.tryParse(original)!;
          return CodeReply(
                  pB: _shareFor(const SessionCode('1111111111')), cB: r.cB)
              .encode();
        },
        (original) {
          final r = CodeReply.tryParse(original)!;
          return CodeReply(pB: r.pB, cB: Uint8List.fromList(r.cB)..[3] ^= 1)
              .encode();
        },
      ]) {
        fakeAsync((async) {
          final w = _World(async)..startSender();
          w.hub.tamper = (topic, payload) =>
              CodeReply.tryParse(payload) == null ? payload : tamper(payload);
          w.search();

          w.pass(const Duration(seconds: 21));
          expect(w.outcome, isA<CodeSessionNotFound>());
          expect(w.dialogs, isEmpty, reason: 'it never confirmed');
          expect(w.offerReads, 0);
        });
      }
    });

    test('a reply that is not a point of the curve is dropped', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.hub.tamper = (topic, payload) {
          final r = CodeReply.tryParse(payload);
          if (r == null) return payload;
          return CodeReply(
                  pB: Uint8List.fromList([4, ...List.filled(64, 9)]), cB: r.cB)
              .encode();
        };
        w.search();

        w.pass(const Duration(seconds: 21));
        expect(w.outcome, isA<CodeSessionNotFound>());
        expect(w.dialogs, isEmpty);
      });
    });

    test('a damaged confirmation never reaches the person, and the real one '
        'that follows still does', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        var sealedSeen = 0;
        w.hub.tamper = (topic, payload) {
          final isPlain = CodeRequest.tryParse(payload) != null ||
              CodeReply.tryParse(payload) != null;
          if (isPlain) return payload;
          // The first sealed message is the confirmation.
          if (sealedSeen++ == 0) {
            return Uint8List.fromList(payload)..[payload.length - 3] ^= 0x40;
          }
          return payload;
        };
        w.search();

        w.pass(const Duration(seconds: 100));
        expect(w.dialogs, isEmpty);
        expect(w.offerReads, 0);
        expect(w.outcome, isA<CodeSessionUnreachable>(),
            reason: 'proved, then nothing came: an honest "unreachable"');
      });
    });

    test('an offer sealed under another key, for another run, or as another '
        'message is ignored by the receiver', () {
      fakeAsync((async) {
        final w = _World(async)
          ..autoApprove = false
          ..startSender();
        w.search();
        expect(w.dialogs, hasLength(1));

        // The worst case: an attacker who has somehow learned the payload
        // topic still cannot seal for it.
        final payloadTopic = w.hub.log
            .firstWhere((e) =>
                e.startsWith('receiver subscribe') &&
                !e.endsWith(w.requests.single.reply))
            .split(' ')
            .last;
        final otherKey = Uint8List.fromList(List.generate(32, (i) => i));
        final n = w.requests.single.n;
        Future<Uint8List> seal(Uint8List key, SealRole role, Uint8List forN) =>
            InternetCodeSeal.seal(
              key: key,
              role: role,
              n: forN,
              plaintext: utf8.encode(
                  jsonEncode({'k': 'offer', 'qs': sampleOffer(tag: 9)})),
            );
        seal(otherKey, SealRole.payload, n)
            .then((b) => w.hub.inject(payloadTopic, b));
        w.hub.inject(payloadTopic, Uint8List.fromList(List.filled(80, 3)));
        w.hub.inject(payloadTopic, Uint8List(0));
        w.settle();
        expect(w.outcome, isNull, reason: 'a forgery is not an answer');

        w.pendingAnswers.single.complete(true);
        w.settle();
        expect(w.outcome, isA<CodeSessionFoundOnline>());
        expect((w.outcome as CodeSessionFoundOnline).payload, w.offer,
            reason: 'the sender\'s own offer, not the forged one');
      });
    });

    test('an offer string that is not a QR payload is never passed on', () {
      fakeAsync((async) {
        final w = _World(async, offer: 'https://example.com/not-an-offer')
          ..startSender();
        w.search();

        expect(w.dialogs, hasLength(1), reason: 'the person did say yes');
        w.pass(const Duration(seconds: 100));
        expect(w.outcome, isA<CodeSessionUnreachable>(),
            reason: 'what came was not an offer, and was not passed on');
      });
    });
  });

  group('the log', () {
    test('holds no code, no topic, no name, no offer and no share, whatever '
        'happened', () {
      fakeAsync((async) {
        final lines = <String>[];
        final subscription = AppLogger.logStream.listen(lines.add);
        final w = _World(async)..startSender();

        // A good exchange, a wrong code, a forged reply, junk and a replay.
        w.search(name: 'Alice laptop');
        final replayed = w.inject();
        w.hub.inject(w.requestTopic, replayed.encode());
        w.hub.inject(w.requestTopic, Uint8List.fromList([1, 2, 3]));
        w.pass(const Duration(seconds: 2));
        final other = _World(async, code: const SessionCode('0000000009'))
          ..startSender();
        other.search(typed: const SessionCode('0000000001'));
        w.pass(const Duration(seconds: 30));
        w.settle();

        final secrets = <String, String>{
          'the code': _code.code,
          'the code as shown': _code.display,
          'the other code': '0000000009',
          'the typed code': '0000000001',
          'the name': 'Alice laptop',
          'the offer': w.offer.substring(0, 24),
          'the request topic': w.requestTopic,
          'the other topic': other.requestTopic,
          'a nonce': InternetCode.encode(replayed.n),
          'a share': InternetCode.encode(replayed.pA),
          'a reply topic': replayed.reply,
        };
        for (final request in w.requests) {
          secrets['reply topic ${request.reply}'] = request.reply;
          secrets['share ${request.reply}'] = InternetCode.encode(request.pA);
        }
        final log = lines.join('\n');
        expect(log, isNotEmpty, reason: 'it did log something');
        for (final entry in secrets.entries) {
          expect(log.contains(entry.value), isFalse,
              reason: '${entry.key} is in the log');
        }
        subscription.cancel();
      });
    });
  });

  group('the sender checks every request before it spends anything', () {
    test('a request older than two minutes is dropped, one a little younger '
        'is not', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();

        w.inject(age: const Duration(minutes: 3));
        w.settle();
        expect(w.sender.attempts, 0);
        expect(w.replies, isEmpty);

        w.inject(age: const Duration(minutes: 1, seconds: 59));
        w.settle();
        expect(w.sender.attempts, 1);
        expect(w.replies, hasLength(1));
      });
    });

    test('a request from the far future is dropped', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.inject(age: const Duration(minutes: -10));
        w.settle();
        expect(w.sender.attempts, 0);
        expect(w.replies, isEmpty);
      });
    });

    test('a request whose nonce was already seen is dropped, even much later',
        () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        final first = w.inject();
        w.settle();
        expect(w.replies, hasLength(1));

        w.pass(const Duration(seconds: 10));
        w.hub.inject(w.requestTopic, first.encode());
        w.settle();
        w.pass(const Duration(seconds: 10));
        w.hub.inject(w.requestTopic, first.encode());
        w.settle();

        expect(w.sender.attempts, 1, reason: 'a replay costs nothing and gets nothing');
        expect(w.replies, hasLength(1));
      });
    });

    test('junk, oversized and ill-typed requests are dropped without a reply '
        'and the listener lives on', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        final good = CodeRequest(
          n: InternetCode.randomBytes(16),
          pA: _shareFor(_code),
          reply: InternetCode.newReplyTopic(),
          ts: w.now().millisecondsSinceEpoch ~/ 1000,
        );
        Map<String, Object?> body() =>
            jsonDecode(utf8.decode(good.encode())) as Map<String, Object?>;
        Uint8List enc(Object o) => Uint8List.fromList(utf8.encode(jsonEncode(o)));

        final hostile = <Uint8List>[
          Uint8List(0),
          Uint8List(70000),
          Uint8List.fromList([0xc3, 0x28]),
          enc([]),
          enc('x'),
          enc(body()..['n'] = 'A' * 2000),
          enc(body()..['pA'] = InternetCode.encode(Uint8List(64))),
          enc(body()..['reply'] = '../../etc'),
          enc(body()..['reply'] = 'a' * 100),
          enc(body()..['v'] = 99),
          enc(body()..['ts'] = 'now'),
          enc(body()..['name'] = 'x' * 600),
        ];
        for (final bytes in hostile) {
          w.hub.inject(w.requestTopic, bytes);
        }
        w.settle();
        expect(w.sender.attempts, 0);
        expect(w.replies, isEmpty);
        expect(w.sender.isStopped, isFalse);

        w.pass(const Duration(seconds: 2));
        w.hub.inject(w.requestTopic, good.encode());
        w.settle();
        expect(w.replies, hasLength(1), reason: 'the next honest one is served');
      });
    });

    test('a request that asks for its reply on the request topic is dropped: '
        'nobody makes this end talk to itself', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.inject(reply: w.requestTopic);
        w.settle();
        expect(w.sender.attempts, 0);
        expect(w.replies, isEmpty);
      });
    });

    test('a share that is not on the curve is dropped, and that costs an '
        'attempt', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        for (final pA in [
          Uint8List.fromList([4, ...List.filled(64, 1)]),
          Uint8List.fromList([0, ...List.filled(64, 0)]),
          Uint8List.fromList([4, ...List.filled(64, 255)]),
        ]) {
          w.pass(const Duration(seconds: 2));
          w.inject(pA: pA);
          w.settle();
        }
        expect(w.replies, isEmpty);
        expect(w.sender.attempts, 3);
        expect(w.sender.isStopped, isFalse);
      });
    });
  });

  group('the sender\'s budget', () {
    test('at most one run a second; the others are dropped, not queued', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();

        w.inject(as: const SessionCode('1111111111'));
        w.inject(as: const SessionCode('2222222222'));
        w.inject(as: const SessionCode('3333333333'));
        w.settle();
        expect(w.sender.attempts, 1);
        expect(w.replies, hasLength(1));

        w.pass(const Duration(milliseconds: 999));
        w.inject(as: const SessionCode('4444444444'));
        w.settle();
        expect(w.sender.attempts, 1);

        w.pass(const Duration(milliseconds: 2));
        w.inject(as: const SessionCode('5555555555'));
        w.settle();
        expect(w.sender.attempts, 2);
        expect(w.replies, hasLength(2));
      });
    });

    test('the 31st attempt on one code is ignored', () {
      fakeAsync((async) {
        final w = _World(async, timings: _roomy)..startSender();
        final random = Random(1);
        for (var i = 0; i < 31; i++) {
          w.pass(const Duration(milliseconds: 1100));
          w.inject(as: SessionCode.generate(random));
          w.settle();
        }
        expect(w.sender.attempts, 30);
        expect(w.sender.exhausted, isTrue);
        expect(w.replies, hasLength(30), reason: 'the 31st got no answer');

        // And the right code is not let in either: the code is spent.
        w.pass(const Duration(seconds: 2));
        w.search();
        w.pass(const Duration(seconds: 25));
        expect(w.outcome, isA<CodeSessionNotFound>());
        expect(w.dialogs, isEmpty);
        expect(w.replies, hasLength(30));
      });
    });

    test('a wrong confirmation buys the asker nothing back', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        for (var i = 0; i < 30; i++) {
          w.pass(const Duration(milliseconds: 1100));
          // Knows the code, proves it, and then sends a wrong cA.
          final hand = _ByHand(w, _code)..ask();
          expect(hand.prove(), isTrue);
          hand.confirm(cA: Uint8List(32));
        }
        expect(w.dialogs, isEmpty, reason: 'a wrong cA never reaches a person');
        expect(w.sender.attempts, 30);
        expect(w.sender.exhausted, isTrue);

        w.pass(const Duration(seconds: 2));
        final late = _ByHand(w, _code)..ask();
        expect(late.reply, isNull, reason: 'the code is spent');
      });
    });

    test('a new code starts again: the budget belongs to the code', () {
      fakeAsync((async) {
        final w = _World(async, timings: _roomy)..startSender();
        for (var i = 0; i < 30; i++) {
          w.pass(const Duration(milliseconds: 1100));
          w.inject(as: SessionCode.generate(Random(i)));
          w.settle();
        }
        expect(w.sender.exhausted, isTrue);
        w.sender.stop();
        w.settle();

        const fresh = SessionCode('9090909090');
        final w2 = _World(async, code: fresh)..startSender();
        expect(w2.sender.attempts, 0);
        expect(w2.sender.exhausted, isFalse);
        w2.search();
        expect(w2.outcome, isA<CodeSessionFoundOnline>());
      });
    });

    test('only one person is asked at a time; a second asker is refused',
        () {
      fakeAsync((async) {
        final w = _World(async)
          ..autoApprove = false
          ..startSender();

        final first = _ByHand(w, _code)..ask();
        expect(first.prove(), isTrue);
        first.confirm(name: 'First');
        expect(w.dialogs, ['First']);

        w.pass(const Duration(seconds: 2));
        final second = _ByHand(w, _code)..ask();
        expect(second.prove(), isTrue);
        second.confirm(name: 'Second');

        expect(w.dialogs, ['First'], reason: 'one dialog per code');
        final refusals = w.on(second.derived!.payloadTopic);
        expect(refusals, hasLength(1),
            reason: 'the second asker was told no, not left waiting');
        expect(w.on(first.derived!.payloadTopic), isEmpty,
            reason: 'the first is still being decided');
      });
    });
  });

  group('what the sender holds, and for how long', () {
    test('the code is held while the person decides and until the answer '
        'arrives', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.search();

        expect(w.holds, [
          'hold ${InternetCodeSender.dialogHold}',
          'hold ${InternetCodeSender.payloadHoldReason}',
          'release ${InternetCodeSender.dialogHold}',
        ], reason: 'the new hold is taken before the old one is let go');

        w.pass(const Duration(seconds: 50));
        expect(w.holds, hasLength(3), reason: 'still held at fifty seconds');

        w.sender.answered();
        expect(w.holds.last, 'release ${InternetCodeSender.payloadHoldReason}');
      });
    });

    test('without an answer the hold ends at sixty seconds, and the code may '
        'be replaced again', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.search();
        w.pass(const Duration(seconds: 59));
        expect(w.holds.last, isNot(startsWith('release internet-code:payload')));

        w.pass(const Duration(seconds: 2));
        expect(w.holds.last, 'release ${InternetCodeSender.payloadHoldReason}');

        // Nobody was counted as having taken it: another receiver is asked.
        w.dialogs.clear();
        final again = _World(async, code: _code)..hub.latency = Duration.zero;
        expect(again.dialogs, isEmpty);
        final hand = _ByHand(w, _code)..ask();
        expect(hand.prove(), isTrue);
        hand.confirm(name: 'Second try');
        expect(w.dialogs, ['Second try']);
      });
    });

    test('a refusal lets the code go at once and tells the receiver', () {
      fakeAsync((async) {
        final w = _World(async)
          ..autoApprove = false
          ..startSender();
        w.search();
        expect(w.holds, ['hold ${InternetCodeSender.dialogHold}']);

        w.pendingAnswers.single.complete(false);
        w.settle();

        expect(w.outcome, isA<CodeSessionDeclined>());
        expect(w.holds.last, 'release ${InternetCodeSender.dialogHold}');
        expect(w.offerReads, 0, reason: 'the offer was not read');
      });
    });

    test('a dialog nobody answers is a refusal at ninety seconds', () {
      fakeAsync((async) {
        final w = _World(async)
          ..autoApprove = false
          ..startSender();
        w.search();

        w.pass(const Duration(seconds: 89));
        expect(w.outcome, isNull);
        w.pass(const Duration(seconds: 2));

        expect(w.outcome, isA<CodeSessionDeclined>());
        expect(w.holds.last, 'release ${InternetCodeSender.dialogHold}');
        expect(w.offerReads, 0);
      });
    });

    test('stopping drops everything: a late "yes" hands nothing over', () {
      fakeAsync((async) {
        final w = _World(async)
          ..autoApprove = false
          ..startSender();
        w.search();
        expect(w.dialogs, hasLength(1));

        w.sender.stop();
        w.settle();
        w.pendingAnswers.single.complete(true);
        w.settle();

        expect(w.offerReads, 0);
        expect(w.senderBox.isClosed, isTrue);
        expect(w.holds.last, startsWith('release'));
        expect(w.hub.listenedTopics, isNot(contains(w.requestTopic)));
      });
    });

    test('stopping in the middle of an exchange ends it: a later confirmation '
        'reaches no one', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        final hand = _ByHand(w, _code)..ask();
        expect(hand.prove(), isTrue);

        w.sender.stop();
        w.settle();
        hand.confirm();
        w.pass(const Duration(seconds: 1));

        expect(w.dialogs, isEmpty);
        expect(w.senderBox.isClosed, isTrue);
        expect(w.senderBox.subscribed, isEmpty);
      });
    });
  });

  group('every step has a way out', () {
    /// Drops the message at [step] (0 request, 1 reply, 2 confirmation, 3 offer).
    void dropStep(_World w, int step) {
      var sealed = 0;
      w.hub.dropIf = (topic, payload) {
        if (CodeRequest.tryParse(payload) != null) return step == 0;
        if (CodeReply.tryParse(payload) != null) return step == 1;
        return step == 2 + sealed++;
      };
    }

    test('a lost request: not found, in twenty seconds', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        dropStep(w, 0);
        w.search();
        w.pass(const Duration(seconds: 21));
        expect(w.outcome, isA<CodeSessionNotFound>());
        expect(w.dialogs, isEmpty);
      });
    });

    test('a lost reply: not found, in twenty seconds', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        dropStep(w, 1);
        w.search();
        w.pass(const Duration(seconds: 21));
        expect(w.outcome, isA<CodeSessionNotFound>());
        expect(w.dialogs, isEmpty);
        // The sender gave the exchange up on its own, and listens for nothing
        // it no longer needs.
        w.pass(const Duration(seconds: 10));
        expect(w.hub.listenedTopics, {w.requestTopic});
      });
    });

    test('a lost confirmation: unreachable, never hangs, and the sender '
        'forgets the exchange', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        dropStep(w, 2);
        w.search();
        w.pass(const Duration(seconds: 94));
        expect(w.outcome, isNull);
        w.pass(const Duration(seconds: 2));

        expect(w.outcome, isA<CodeSessionUnreachable>());
        expect(w.dialogs, isEmpty);
        expect(w.hub.listenedTopics, {w.requestTopic});
        expect(w.receiverBox!.isClosed, isTrue);
      });
    });

    test('a lost offer: unreachable, and the hold lapses by itself', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        dropStep(w, 3);
        w.search();
        expect(w.dialogs, hasLength(1));

        w.pass(const Duration(seconds: 96));
        expect(w.outcome, isA<CodeSessionUnreachable>());
        expect(w.holds.last, 'release ${InternetCodeSender.payloadHoldReason}');
      });
    });

    test('a lost refusal: unreachable, not a hang', () {
      fakeAsync((async) {
        final w = _World(async)
          ..autoApprove = false
          ..startSender();
        dropStep(w, 3);
        w.search();
        w.pendingAnswers.single.complete(false);
        w.settle();

        w.pass(const Duration(seconds: 96));
        expect(w.outcome, isA<CodeSessionUnreachable>());
      });
    });

    test('a sender that is not there at all: not found, not a hang', () {
      fakeAsync((async) {
        final w = _World(async);
        w.search();
        w.pass(const Duration(seconds: 21));
        expect(w.outcome, isA<CodeSessionNotFound>());
      });
    });

    test('a sender that started after the request was sent never hears it '
        '(nothing is kept for a late subscriber)', () {
      fakeAsync((async) {
        final w = _World(async);
        w.search();
        w.pass(const Duration(seconds: 2));
        w.startSender();
        w.pass(const Duration(seconds: 25));

        expect(w.outcome, isA<CodeSessionNotFound>());
        expect(w.sender.attempts, 0);
      });
    });
  });

  group('on a slow, repeating, reordering mailbox', () {
    test('the exchange still completes, with one dialog and one offer', () {
      fakeAsync((async) {
        final w = _World(async, latency: const Duration(milliseconds: 700));
        w.hub.duplicates = 2;
        // Later messages overtake earlier ones.
        w.hub.delayFor = (topic, payload, seq) =>
            Duration(milliseconds: 900 - (seq % 4) * 250);
        w.startSender();
        w.search();

        w.pass(const Duration(seconds: 15));
        expect(w.outcome, isA<CodeSessionFoundOnline>());
        expect((w.outcome as CodeSessionFoundOnline).payload, w.offer);
        expect(w.dialogs, ['Alice laptop']);
        expect(w.offerReads, 1);
        expect(w.sender.attempts, 1, reason: 'duplicates are not extra tries');
      });
    });

    test('three slow seconds per message still finish inside the limits', () {
      fakeAsync((async) {
        final w = _World(async, latency: const Duration(seconds: 3))
          ..startSender();
        w.search();
        w.pass(const Duration(seconds: 20));
        expect(w.outcome, isA<CodeSessionFoundOnline>());
      });
    });
  });

  group('when a channel is down', () {
    List<FakeMailbox> pair(_World w, {String prefix = 'r'}) =>
        [w.hub.endpoint('$prefix-nostr'), w.hub.endpoint('$prefix-worker')];

    test('one down on the receiver: the other carries it', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        final boxes = pair(w);
        boxes.first.down = true;
        w.search(mailbox: () => RacingCodeMailbox(boxes));

        expect(w.outcome, isA<CodeSessionFoundOnline>());
      });
    });

    test('one down on the sender: the other carries it', () {
      fakeAsync((async) {
        final w = _World(async);
        final boxes = pair(w, prefix: 's');
        boxes.last.down = true;
        w.startSender(mailbox: RacingCodeMailbox(boxes));
        w.search();

        expect(w.outcome, isA<CodeSessionFoundOnline>());
        expect(w.dialogs, ['Alice laptop']);
      });
    });

    test('both down on the receiver: a clear "no network", at once, not a '
        'twenty-second "wrong code"', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        final boxes = pair(w);
        for (final b in boxes) {
          b.down = true;
        }
        w.search(mailbox: () => RacingCodeMailbox(boxes));

        expect(w.outcome, isA<CodeSessionNoNetwork>());
        expect(async.elapsed, Duration.zero);
      });
    });

    test('both down on the sender: starting says so, instead of showing a '
        'code that leads nowhere', () {
      fakeAsync((async) {
        final w = _World(async);
        final boxes = pair(w, prefix: 's');
        for (final b in boxes) {
          b.down = true;
        }
        w.startSender(mailbox: RacingCodeMailbox(boxes));

        expect(w.startError, isA<MailboxUnavailable>());
        expect(w.sender.isStopped, isTrue);
      });
    });

    test('a channel that dies mid-exchange does not stop the other', () {
      fakeAsync((async) {
        final w = _World(async, latency: const Duration(seconds: 1))
          ..startSender();
        final boxes = pair(w);
        w.search(mailbox: () => RacingCodeMailbox(boxes));

        w.pass(const Duration(milliseconds: 1500));
        boxes.first.down = true;
        w.pass(const Duration(seconds: 12));

        expect(w.outcome, isA<CodeSessionFoundOnline>());
      });
    });
  });

  group('cancelling', () {
    test('before anything is published', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.search();
        // The search had already finished at zero latency; cancel a fresh one
        // before a single microtask runs.
        w.outcome = null;
        final control = CodeSearchControl();
        final arbiter = CodeSearchArbiter(control);
        CodeSessionOutcome? outcome;
        FakeMailbox? box;
        InternetCodeSearch(
          mailbox: () => box = w.hub.endpoint('early'),
          pake: _inline,
          now: w.now,
        )
            .run(_code, deviceName: 'x', gate: arbiter.gate('internet'))
            .then((o) => outcome = o);
        control.cancel();
        w.settle();

        expect(outcome, isA<CodeSessionNotFound>());
        expect(box!.isClosed, isTrue);
        expect(box!.subscribed, isEmpty);
      });
    });

    test('while waiting for a reply', () {
      fakeAsync((async) {
        final w = _World(async);
        w.search();
        w.pass(const Duration(seconds: 5));
        expect(w.outcome, isNull);
        expect(w.receiverBox!.subscribed, hasLength(1));

        w.control.cancel();
        w.settle();

        expect(w.outcome, isA<CodeSessionNotFound>());
        expect(w.receiverBox!.isClosed, isTrue);
        expect(w.receiverBox!.subscribed, isEmpty);
        expect(async.nonPeriodicTimerCount, 0,
            reason: 'no timer of the search is left');
      });
    });

    test('while a person is deciding on the other device', () {
      fakeAsync((async) {
        final w = _World(async)
          ..autoApprove = false
          ..startSender();
        w.search();
        expect(w.control.phase, CodeSearchPhase.awaitingApproval);

        w.control.cancel();
        w.settle();

        expect(w.outcome, isA<CodeSessionNotFound>());
        expect(w.receiverBox!.isClosed, isTrue);
        expect(w.receiverBox!.subscribed, isEmpty);
      });
    });

    test('and a late offer after that is not acted on', () {
      fakeAsync((async) {
        final w = _World(async)
          ..autoApprove = false
          ..startSender();
        w.search();
        w.control.cancel();
        w.settle();
        w.pendingAnswers.single.complete(true);
        w.settle();

        expect(w.outcome, isA<CodeSessionNotFound>());
      });
    });
  });

  group('the phases a screen draws', () {
    test('searching until a sender has proved the code, then waiting for its '
        'person', () {
      fakeAsync((async) {
        final w = _World(async)
          ..autoApprove = false
          ..startSender();
        w.control = CodeSearchControl();
        expect(w.control.phase, CodeSearchPhase.searching);

        final seen = <CodeSearchPhase>[];
        w.search();
        w.control.phases.listen(seen.add);
        // The search above raised its phase before the listener was attached;
        // what matters is where it stands.
        expect(w.control.phase, CodeSearchPhase.awaitingApproval);
        expect(w.outcome, isNull);
      });
    });

    test('a wrong code never reaches the second phase', () {
      fakeAsync((async) {
        final w = _World(async)..startSender();
        w.search(typed: const SessionCode('0000000000'));
        w.pass(const Duration(seconds: 25));
        expect(w.control.phase, CodeSearchPhase.searching);
      });
    });
  });
}

// Does finding a sender by its code work over the real public services, from
// this machine, right now?
//
//     flutter test integration_test/live_code_rendezvous_check.dart -d macos
//
// The sender and the receiver are both on this Mac, and both talk to the real
// Nostr relays and the real DirectDrop Worker. Only the exchange is run — up
// to the receiver holding the sender's offer string; no WebRTC, no file. It is
// run three times, so that each channel is shown to work on its own and then
// both together:
//
//     nostr    only the Nostr relays
//     worker   only the Worker's rooms
//     both     the two raced, as the app runs them
//
// What it prints, per run, is the time of each step as the public mailbox saw
// it, counted from the moment the receiver pressed the button, and which
// channel delivered the message that moved the exchange on:
//
//     LIVE <run> +<ms> <who> <what> [via=<channel>]
//     LIVE <run> RESULT <outcome> total_ms=<...>
//     LIVE SUMMARY ...
//
// The Worker allows ten writes a minute per address and the exchange makes four
// (two per side), so the three runs together stay inside it; if the Worker says
// 429 the lines say so, and that is a finding too.
//
// Needs the network and the deployed Worker, so it lives here rather than in
// `test/`, and is never part of a CI run. It talks to production services; it
// puts two small AEAD blobs and two small JSON messages in rooms nobody else
// uses, which expire on their own.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/network/internet_code.dart';
import 'package:quickshare/core/network/internet_code_sender.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/core/signaling/nostr_code_mailbox.dart';
import 'package:quickshare/core/signaling/worker_code_mailbox.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/receiver/data/client/internet_code_search.dart';

import '../test/support/sample_offer.dart';

/// Reports what passes through a mailbox, with the time and the channel.
class _Traced implements CodeMailbox {
  _Traced(this.inner, this.run, this.who, this.clock, this.lines);

  final CodeMailbox inner;
  final String run;
  final String who;
  final Stopwatch clock;
  final List<String> lines;
  final _controller = StreamController<MailboxMessage>.broadcast();
  StreamSubscription<MailboxMessage>? _listening;

  void _say(String what, {String? via}) {
    final line = 'LIVE $run +${clock.elapsedMilliseconds} $who $what'
        '${via == null || via.isEmpty ? '' : ' via=$via'}';
    lines.add(line);
    print(line);
  }

  /// A message's place in the exchange: the first two are readable by their
  /// shape, and what is sealed is whatever the other kind of party sends next —
  /// the receiver's confirmation, the sender's offer.
  String _role(Uint8List payload, {required bool outgoing}) {
    if (CodeRequest.tryParse(payload) != null) return 'request';
    if (CodeReply.tryParse(payload) != null) return 'reply';
    final fromReceiver = outgoing == who.startsWith('receiver');
    return '${fromReceiver ? 'confirmation' : 'offer'} (sealed, ${payload.length} B)';
  }

  @override
  String get name => inner.name;

  @override
  Stream<MailboxMessage> get messages {
    _listening ??= inner.messages.listen((m) {
      _say('heard ${_role(m.payload, outgoing: false)}', via: m.source);
      if (!_controller.isClosed) _controller.add(m);
    });
    return _controller.stream;
  }

  @override
  Future<void> subscribe(String topic) async {
    final watch = Stopwatch()..start();
    try {
      await inner.subscribe(topic);
      _say('subscribed (${watch.elapsedMilliseconds} ms)');
    } catch (e) {
      _say('subscribe FAILED: $e');
      rethrow;
    }
  }

  @override
  Future<void> unsubscribe(String topic) => inner.unsubscribe(topic);

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    final role = _role(payload, outgoing: true);
    final watch = Stopwatch()..start();
    try {
      await inner.publish(topic, payload);
      _say('published $role (${watch.elapsedMilliseconds} ms to the first channel)');
    } catch (e) {
      _say('publish $role FAILED: $e');
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    await _listening?.cancel();
    await inner.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final summary = <String>[];

  Future<void> runOnce(
    String run,
    CodeMailbox Function() channels,
  ) async {
    final clock = Stopwatch();
    final lines = <String>[];
    final code = SessionCode.generate();
    final offer = sampleOffer();
    final asked = <String>[];

    final sender = InternetCodeSender(
      mailbox: _Traced(channels(), run, 'sender  ', clock, lines),
      code: code,
      offer: () async => offer,
      approve: (name) async {
        asked.add(name);
        print('LIVE $run +${clock.elapsedMilliseconds} sender   dialog for "$name": yes');
        return true;
      },
    );

    final started = Stopwatch()..start();
    await sender.start();
    print('LIVE $run sender listening after ${started.elapsedMilliseconds} ms '
        '(topic ${InternetCode.requestTopic(code).substring(0, 6)}…)');

    // A beat for the relays and the Worker to register the subscription, as a
    // person typing ten digits would take.
    await Future<void>.delayed(const Duration(seconds: 1));

    final control = CodeSearchControl();
    final gate = CodeSearchArbiter(control).gate('internet');
    clock.start();
    print('LIVE $run +0 receiver pressed Receive');
    final outcome = await InternetCodeSearch(
      mailbox: () => _Traced(channels(), run, 'receiver', clock, lines),
    ).run(code, deviceName: 'Live-check Mac', gate: gate);
    final total = clock.elapsedMilliseconds;
    await sender.stop();

    final ok = outcome is CodeSessionFoundOnline && outcome.payload == offer;
    final what = outcome.runtimeType.toString();
    print('LIVE $run RESULT $what total_ms=$total same_offer=$ok');
    summary.add('$run: $what in $total ms, asked=$asked');

    expect(outcome, isA<CodeSessionFoundOnline>(),
        reason: 'the receiver should hold the sender\'s offer ($run)');
    expect((outcome as CodeSessionFoundOnline).payload, offer);
    expect(asked, ['Live-check Mac']);
  }

  CodeMailbox nostr() => NostrCodeMailbox();
  CodeMailbox worker() => WorkerCodeMailbox(baseUrl: AppConstants.workerBaseUrl);

  testWidgets('through the Nostr relays alone', (tester) async {
    await tester.runAsync(() => runOnce('nostr', nostr));
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('through the Worker alone', (tester) async {
    await tester.runAsync(() => runOnce('worker', worker));
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('through both, raced', (tester) async {
    await tester.runAsync(
        () => runOnce('both', () => RacingCodeMailbox([nostr(), worker()])));
  }, timeout: const Timeout(Duration(minutes: 3)));

  tearDownAll(() {
    print('LIVE SUMMARY');
    for (final line in summary) {
      print('LIVE   $line');
    }
  });
}

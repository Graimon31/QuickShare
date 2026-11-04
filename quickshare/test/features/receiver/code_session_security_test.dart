// SEC-01 — asking a sender for a session by its ten-digit code.
//
// The code is the only secret the two devices share, and it is a little over
// 33 bits. Anything the receiver sends that depends on it, to a device whose
// identity it has not yet established, can be tried against all ten billion
// codes at home; and a device that is handed the code can hand back a session
// that belongs to it. So the receiver proves the code with a PAKE bound to the
// TLS certificate of the connection it is on, and sends nothing else until the
// far side has proved it back.
//
// Everything here runs the real `CodeSessionResolver` against the real
// `LocalHttpServer` on loopback, with impostors on certificates of their own.
// The impostors record every byte they are sent, and those bytes are what the
// assertions are about.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

/// What an impostor was sent, byte for byte.
class _Seen {
  final String method;
  final String path;
  final String headers;
  final List<int> body;
  _Seen(this.method, this.path, this.headers, this.body);

  String get line => '$method $path';

  /// Everything the request carried, as one string to search.
  String get raw => '$method $path\n$headers\n${latin1.decode(body)}';
}

enum _Behaviour {
  /// Answers like a sender, with a PAKE run for a code it guessed.
  guesses,

  /// Answers health, then never answers the first round.
  hangsAtStart,

  /// Accepts the connection and never says a word.
  silent,

  /// Sends a well-formed answer made of bytes that prove nothing.
  garbage,

  /// What an earlier build answers: the bearer-token wall.
  oldBuild,

  /// A build that has never heard of the route.
  noSuchRoute,

  /// Terminates TLS with a certificate of its own and passes every request on
  /// to the real sender, unchanged.
  relays,
}

/// A device that is not the sender.
class _Impostor {
  final _Behaviour behaviour;
  final SessionTlsIdentity identity = SessionTlsIdentity.generate();
  final List<_Seen> seen = [];
  final int? upstreamPort;
  final String? upstreamFingerprint;
  HttpServer? _https;
  ServerSocket? _raw;
  late final int port;

  _Impostor(this.behaviour, {this.upstreamPort, this.upstreamFingerprint});

  Future<_Impostor> start() async {
    if (behaviour == _Behaviour.silent) {
      _raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = _raw!.port;
      final held = <Socket>[];
      _raw!.listen(held.add);
      return this;
    }
    _https = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4, 0, identity.securityContext);
    port = _https!.port;
    unawaited(_https!.forEach(_handle));
    return this;
  }

  Future<void> stop() async {
    await _https?.close(force: true);
    await _raw?.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final body = <int>[];
    await for (final chunk in request) {
      body.addAll(chunk);
    }
    final entry = _Seen(request.method, request.uri.path,
        request.headers.toString(), body);
    seen.add(entry);
    final response = request.response;

    Future<void> json(int status, Object value) async {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(value));
      await response.close();
    }

    if (entry.line == 'GET /v2/health') {
      return json(200, {'ok': true, 'protocol': 'QHTP', 'protocolVersion': 1});
    }

    switch (behaviour) {
      case _Behaviour.guesses:
        if (entry.line == 'POST /v2/pake/start') {
          final pA = CodePake.decode(
              (jsonDecode(utf8.decode(body)) as Map)['pA'],
              length: Spake2.shareLength);
          if (pA == null) return json(400, {'error': 'bad'});
          final reply = await CodePake.respond(SessionCode.generate(),
              receiverShare: pA, certFingerprint: identity.fingerprint);
          return json(200, {
            'pakeId': 'f' * 32,
            'pB': CodePake.encode(reply.share),
            'cB': CodePake.encode(reply.keys.confirmationB),
          });
        }
      case _Behaviour.hangsAtStart:
        if (entry.line == 'POST /v2/pake/start') {
          return; // The response is never written.
        }
      case _Behaviour.garbage:
        if (entry.line == 'POST /v2/pake/start') {
          final random = Random.secure();
          return json(200, {
            'pakeId': 'f' * 32,
            'pB': CodePake.encode(
                List.generate(Spake2.shareLength, (_) => random.nextInt(256))),
            'cB': CodePake.encode(
                List.generate(CodePake.tagLength, (_) => random.nextInt(256))),
          });
        }
      case _Behaviour.oldBuild:
        return json(401, {'error': 'unauthorized', 'code': 'AUTH_REQUIRED'});
      case _Behaviour.noSuchRoute:
        break;
      case _Behaviour.relays:
        return _relay(request, body);
      case _Behaviour.silent:
        break;
    }

    // What an impostor would love to be asked: hand over a session.
    if (entry.line == 'POST /v2/invite/request') {
      return json(200, {
        'outcome': 'accepted',
        'token': 'attacker-token',
        'sessionId': 'attacker-session',
        'itemCount': 1,
        'totalBytes': 1,
      });
    }
    return json(404, {'error': 'not found'});
  }

  Future<void> _relay(HttpRequest request, List<int> body) async {
    final upstream = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback =
          (cert, host, p) => SessionTlsIdentity.matches(cert, upstreamFingerprint!);
    try {
      final out = await upstream.openUrl(request.method,
          Uri.parse('https://127.0.0.1:$upstreamPort${request.uri.path}'));
      if (request.headers.contentType != null) {
        out.headers.contentType = request.headers.contentType;
      }
      out.add(body);
      final answer = await out.close();
      final answerBody = <int>[];
      await for (final chunk in answer) {
        answerBody.addAll(chunk);
      }
      request.response.statusCode = answer.statusCode;
      if (answer.headers.contentType != null) {
        request.response.headers.contentType = answer.headers.contentType;
      }
      request.response.add(answerBody);
      await request.response.close();
    } finally {
      upstream.close(force: true);
    }
  }
}

/// A device that holds the code, and so can pass the proof — and then does
/// something the proof alone does not rule out.
///
/// It speaks just enough HTTP/1.1 over a raw TLS server to answer one request
/// per connection (`Connection: close`). That is what makes the certificate a
/// per-connection choice: connection `n` is served `identities[n]`, the last
/// one for every connection after.
class _ProvingSender {
  _ProvingSender(
    this.code, {
    required this.identities,
    this.padding = const {},
    this.reportedFingerprint,
  });

  final SessionCode code;
  final List<SessionTlsIdentity> identities;

  /// Bytes of padding added to the JSON answer of a route, by `METHOD /path`.
  final Map<String, int> padding;

  /// What the final answer claims the certificate is, when it should lie.
  final String? reportedFingerprint;

  final List<_Seen> seen = [];
  int connections = 0;
  late final int port;
  late final ServerSocket _server;
  List<int>? _expectedCa;

  Future<_ProvingSender> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = _server.port;
    _server.listen((raw) {
      final index = connections++;
      unawaited(_serve(raw, identities[min(index, identities.length - 1)]));
    });
    return this;
  }

  Future<void> stop() => _server.close();

  Future<void> _serve(Socket raw, SessionTlsIdentity identity) async {
    final SecureSocket socket;
    try {
      socket = await SecureSocket.secureServer(raw, identity.securityContext);
    } catch (_) {
      raw.destroy();
      return;
    }
    final request = await _read(socket);
    if (request == null) {
      socket.destroy();
      return;
    }
    seen.add(request);
    final (status, body) = await _answer(request, identity);
    final padded = padding[request.line];
    final payload = utf8.encode(jsonEncode(
        padded == null ? body : {...body, 'pad': 'x' * padded}));
    socket.add(utf8.encode('HTTP/1.1 $status OK\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${payload.length}\r\n'
        'Connection: close\r\n\r\n'));
    socket.add(payload);
    try {
      await socket.flush();
      await socket.close();
    } catch (_) {}
    socket.destroy();
  }

  /// One request, read to the end of its body. The listener is left in place:
  /// cancelling it would close the socket under the answer.
  Future<_Seen?> _read(Socket socket) {
    final done = Completer<_Seen?>();
    final received = BytesBuilder();
    socket.listen((chunk) {
      received.add(chunk);
      final all = received.toBytes();
      final end = latin1.decode(all).indexOf('\r\n\r\n');
      if (end < 0) return;
      final head = latin1.decode(all.sublist(0, end));
      final rest = all.sublist(end + 4);
      final List<int> body;
      if (RegExp(r'transfer-encoding:\s*chunked', caseSensitive: false)
          .hasMatch(head)) {
        final decoded = _dechunk(rest);
        if (decoded == null) return; // not all of it yet
        body = decoded;
      } else {
        final match = RegExp(r'content-length:\s*(\d+)', caseSensitive: false)
            .firstMatch(head);
        final length = match == null ? 0 : int.parse(match.group(1)!);
        if (rest.length < length) return;
        body = rest.sublist(0, length);
      }
      if (done.isCompleted) return;
      final first = head.split('\r\n').first.split(' ');
      done.complete(_Seen(first[0], first[1], head, body));
    }, onError: (_) {
      if (!done.isCompleted) done.complete(null);
    }, onDone: () {
      if (!done.isCompleted) done.complete(null);
    });
    return done.future;
  }

  /// The body of a chunked message, or null while it is still incomplete.
  static List<int>? _dechunk(List<int> data) {
    final body = <int>[];
    var at = 0;
    while (true) {
      final lineEnd = latin1.decode(data.sublist(at)).indexOf('\r\n');
      if (lineEnd < 0) return null;
      final size = int.parse(
          latin1.decode(data.sublist(at, at + lineEnd)).split(';').first.trim(),
          radix: 16);
      at += lineEnd + 2;
      if (size == 0) return data.length >= at + 2 ? body : null;
      if (data.length < at + size + 2) return null;
      body.addAll(data.sublist(at, at + size));
      at += size + 2;
    }
  }

  Future<(int, Map<String, Object?>)> _answer(
      _Seen request, SessionTlsIdentity identity) async {
    switch (request.line) {
      case 'GET /v2/health':
        return (200, {'ok': true, 'protocol': 'QHTP', 'protocolVersion': 1});
      case 'POST /v2/pake/start':
        final pA = CodePake.decode(
            (jsonDecode(utf8.decode(request.body)) as Map)['pA'],
            length: Spake2.shareLength);
        if (pA == null) return (400, {'error': 'bad'});
        // The right code, and the certificate of THIS connection: the proof
        // is made on the first certificate and is a good one.
        final reply = await CodePake.respond(code,
            receiverShare: pA, certFingerprint: identity.fingerprint);
        _expectedCa = reply.keys.confirmationA;
        return (200, {
          'pakeId': 'f' * 32,
          'pB': CodePake.encode(reply.share),
          'cB': CodePake.encode(reply.keys.confirmationB),
        });
      case 'POST /v2/invite/request':
        return (200, {
          'outcome': 'accepted',
          'token': 'attacker-token',
          'sessionId': 'attacker-session',
          'itemCount': 1,
          'totalBytes': 1,
          'tlsFingerprint': reportedFingerprint ?? identity.fingerprint,
        });
    }
    return (404, {'error': 'not found'});
  }

  /// Whether the second round that reached this device carried the
  /// confirmation the proof calls for.
  bool get sawTheRightConfirmation => seen.any((r) =>
      r.line == 'POST /v2/invite/request' &&
      _expectedCa != null &&
      r.raw.contains(CodePake.encode(_expectedCa!)));
}

void main() {
  setUpAll(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());

  late SessionCode code;
  late LocalHttpServer real;
  late int realPort;
  late List<TransferApprovalRequest> prompts;
  final impostors = <_Impostor>[];
  final senders = <_ProvingSender>[];

  QhtpManifest manifest() => QhtpManifest(
        sessionId: 'sec-01-session',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        itemCount: 4,
        totalBytes: 555000,
        items: const [QhtpItem(id: 'item-1', path: 'file.txt', size: 555000)],
      );

  setUp(() async {
    code = SessionCode.generate();
    prompts = [];
    real = LocalHttpServer();
    realPort = await real.startQhtpSessionWhileIndexing(
      sessionId: 'sec-01-session',
      index: Future.value(QhtpIndexerResult(
        manifest: manifest(),
        itemIdToAbsPathMap: {'item-1': '/tmp/file.txt'},
      )),
      authToken: 'super-secret-128bit-auth-token',
      sessionCode: code,
    );
    real.onApprovalRequested = (request) async {
      prompts.add(request);
      return true;
    };
  });

  tearDown(() async {
    await real.stop();
    for (final impostor in impostors) {
      await impostor.stop();
    }
    impostors.clear();
    for (final sender in senders) {
      await sender.stop();
    }
    senders.clear();
  });

  /// A device that holds [code] and can prove it, on the given certificates.
  Future<_ProvingSender> provingSender(
    List<SessionTlsIdentity> identities, {
    Map<String, int> padding = const {},
    String? reportedFingerprint,
  }) async {
    final made = await _ProvingSender(
      code,
      identities: identities,
      padding: padding,
      reportedFingerprint: reportedFingerprint,
    ).start();
    senders.add(made);
    return made;
  }

  Future<_Impostor> impostor(_Behaviour behaviour,
      {bool relayingReal = false}) async {
    final made = await _Impostor(
      behaviour,
      upstreamPort: relayingReal ? realPort : null,
      upstreamFingerprint: relayingReal ? real.tlsFingerprint : null,
    ).start();
    impostors.add(made);
    return made;
  }

  RendezvousCandidate announced(int port, {String? hint}) =>
      RendezvousCandidate(
        address: InternetAddress.loopbackIPv4,
        port: port,
        hint: hint ?? code.discoveryHint,
      );

  CodeSessionResolver resolverFor(
    List<RendezvousCandidate> peers, {
    Duration candidateTimeout = const Duration(seconds: 4),
    List<ProbeTarget> probes = const [],
  }) =>
      CodeSessionResolver(
        peers: () => peers,
        probeTargets: (_) async => probes,
        deviceName: 'Test Laptop',
        candidateTimeout: candidateTimeout,
        discoveryWindow: Duration.zero,
        inviteTimeout: const Duration(seconds: 10),
      );

  /// The assertion the whole file is for. Whatever an impostor was sent, it
  /// was asked a question and nothing more: no code in any spelling, no device
  /// name, no confirmation, and never a request for a session.
  void expectNothingWorthStealing(_Impostor fake) {
    for (final request in fake.seen) {
      expect(request.raw, isNot(contains(code.code)));
      expect(request.raw, isNot(contains(code.display)));
      expect(request.raw, isNot(contains(code.sessionToken)));
      expect(request.raw, isNot(contains(code.publicId)));
      expect(request.raw, isNot(contains('Test Laptop')));
      expect(request.raw.toLowerCase(), isNot(contains('devicename')));
      expect(request.raw, isNot(contains('"cA"')));
      expect(request.raw, isNot(contains('invitePort')));
    }
    expect(
      fake.seen.map((r) => r.line).toSet(),
      everyElement(isIn(const ['GET /v2/health', 'POST /v2/pake/start'])),
      reason: 'an impostor must only ever be asked to prove itself',
    );
    // The first round carries one value, and it is a point.
    for (final request
        in fake.seen.where((r) => r.line == 'POST /v2/pake/start')) {
      final body = jsonDecode(utf8.decode(request.body)) as Map;
      expect(body.keys, equals(['pA']));
      expect(
        CodePake.decode(body['pA'], length: Spake2.shareLength),
        isNotNull,
      );
    }
  }

  void expectNoSessionFrom(CodeSessionOutcome outcome) {
    expect(outcome, isNot(isA<CodeSessionFound>()),
        reason: 'no session may come from a device that is not the sender');
    expect(prompts, isEmpty,
        reason: 'the real sender must not be asked anything either');
  }

  CodeSessionFound expectFound(CodeSessionOutcome outcome) {
    expect(outcome, isA<CodeSessionFound>());
    return outcome as CodeSessionFound;
  }

  group('SEC-01-A: the correct sender', () {
    test('establishes a session pinned to the certificate it really has',
        () async {
      final outcome = await resolverFor(
        [announced(realPort)],
      ).resolve(code);

      final payload = expectFound(outcome).payload;
      expect(payload.tlsFingerprint, equals(real.tlsFingerprint));
      expect(payload.token, equals('super-secret-128bit-auth-token'));
      expect(payload.sessionId, equals('sec-01-session'));
      expect(payload.mode, equals('http-lan'));
      expect(payload.ip, equals('127.0.0.1'));
      expect(payload.port, equals(realPort));
      expect(payload.itemCount, equals(4));
      expect(payload.fileSize, equals(555000));
      expect(prompts, hasLength(1));
      expect(prompts.single.deviceName, equals('Test Laptop'));
    });

    test('is found by probing when nothing was announced', () async {
      final outcome = await resolverFor(
        const [],
        probes: [(address: InternetAddress.loopbackIPv4, port: realPort)],
      ).resolve(code);

      expect(expectFound(outcome).payload.tlsFingerprint,
          equals(real.tlsFingerprint));
    });

    test('is found when the announced hint is stale', () async {
      final outcome = await resolverFor(
        [announced(realPort, hint: 'zz')],
        probes: [(address: InternetAddress.loopbackIPv4, port: realPort)],
      ).resolve(code);

      expectFound(outcome);
    });

    test('a decline is a decline, with no session in it', () async {
      real.onApprovalRequested = (request) async => false;
      final outcome = await resolverFor(
        [announced(realPort)],
      ).resolve(code);

      expect(outcome, isA<CodeSessionDeclined>());
    });

    test('the wrong code finds nothing, and the sender is never asked',
        () async {
      final wrong = SessionCode.generate();
      final outcome = await resolverFor(
        [announced(realPort, hint: wrong.discoveryHint)],
        probes: [(address: InternetAddress.loopbackIPv4, port: realPort)],
      ).resolve(wrong);

      expect(outcome, isA<CodeSessionNotFound>());
      expect(prompts, isEmpty);
    });
  });

  group('SEC-01-B: a device with a different certificate', () {
    test('a relay in front of the real sender is not trusted', () async {
      final mitm = await impostor(_Behaviour.relays, relayingReal: true);

      final outcome = await resolverFor(
        [announced(mitm.port)],
      ).resolve(code);

      expect(outcome, isA<CodeSessionNotFound>());
      expectNoSessionFrom(outcome);
      expectNothingWorthStealing(mitm);
      expect(mitm.seen, isNotEmpty, reason: 'it was reached, and it relayed');
    });

    test('announcing the right hint gets an impostor asked, and nothing more',
        () async {
      final fake = await impostor(_Behaviour.guesses);

      final outcome = await resolverFor(
        [announced(fake.port)],
      ).resolve(code);

      expect(outcome, isA<CodeSessionNotFound>());
      expectNothingWorthStealing(fake);
    });

    test('an answer made of garbage is dropped without a trace', () async {
      final fake = await impostor(_Behaviour.garbage);

      final outcome = await resolverFor([announced(fake.port)]).resolve(code);

      expect(outcome, isA<CodeSessionNotFound>());
      expectNothingWorthStealing(fake);
    });
  });

  group('SEC-01-C: no fingerprint in the presence record', () {
    test('a real sender still succeeds, through the proof alone', () async {
      final outcome =
          await resolverFor([announced(realPort)]).resolve(code);

      final payload = expectFound(outcome).payload;
      expect(payload.tlsFingerprint, isNotEmpty);
      expect(payload.tlsFingerprint, equals(real.tlsFingerprint));
    });

    test('a fake one gets no trust and no secrets', () async {
      final fake = await impostor(_Behaviour.guesses);

      final outcome = await resolverFor([announced(fake.port)]).resolve(code);

      expect(outcome, isA<CodeSessionNotFound>());
      expectNothingWorthStealing(fake);
    });

    test('with both announced the same way, the real one wins either order',
        () async {
      final fake = await impostor(_Behaviour.guesses);
      for (final peers in [
        [announced(fake.port), announced(realPort)],
        [announced(realPort), announced(fake.port)],
      ]) {
        final outcome = await resolverFor(peers).resolve(code);
        expect(expectFound(outcome).payload.tlsFingerprint,
            equals(real.tlsFingerprint));
      }
      expectNothingWorthStealing(fake);
    });
  });

  group('SEC-01-D: two servers, one announcement, two certificates', () {
    test('the real sender is chosen whichever is listed first', () async {
      final fake = await impostor(_Behaviour.guesses);
      for (final fakeFirst in [true, false]) {
        final peers = [
          announced(fake.port),
          announced(realPort),
        ];
        final outcome = await resolverFor(
          fakeFirst ? peers : peers.reversed.toList(),
        ).resolve(code);

        final payload = expectFound(outcome).payload;
        expect(payload.tlsFingerprint, equals(real.tlsFingerprint));
        expect(payload.port, equals(realPort));
        expect(payload.token, equals('super-secret-128bit-auth-token'));
      }
      expect(prompts, hasLength(2),
          reason: 'one prompt per run, and none for the impostor');
      expectNothingWorthStealing(fake);
    });

    test('the impostor receives neither the code nor the device name, and '
        'nothing that could be checked offline', () async {
      final fake = await impostor(_Behaviour.guesses);

      await resolverFor([announced(fake.port), announced(realPort)])
          .resolve(code);

      expectNothingWorthStealing(fake);
    });

    test('every candidate is given a share of its own', () async {
      // One impostor's copy is useless against the real sender, and two
      // impostors cannot compare notes to learn anything from the difference.
      final first = await impostor(_Behaviour.guesses);
      final second = await impostor(_Behaviour.guesses);

      await resolverFor([announced(first.port), announced(second.port)])
          .resolve(code);

      String shareOf(_Impostor fake) => utf8.decode(fake.seen
          .singleWhere((r) => r.line == 'POST /v2/pake/start')
          .body);
      expect(shareOf(first), isNot(equals(shareOf(second))));
    });

    test('an impostor that hangs after the health check does not hold the '
        'real sender up', () async {
      final fake = await impostor(_Behaviour.hangsAtStart);

      final clock = Stopwatch()..start();
      final outcome = await resolverFor(
        [announced(fake.port), announced(realPort)],
        candidateTimeout: const Duration(seconds: 8),
      ).resolve(code);
      clock.stop();

      expectFound(outcome);
      expect(clock.elapsed, lessThan(const Duration(seconds: 4)),
          reason: 'the real sender must not wait out the impostor\'s timeout');
      expectNothingWorthStealing(fake);
    });

    test('an impostor that accepts the connection and never speaks does not '
        'hold it up either', () async {
      final fake = await impostor(_Behaviour.silent);

      final clock = Stopwatch()..start();
      final outcome = await resolverFor(
        [announced(fake.port), announced(realPort)],
        candidateTimeout: const Duration(seconds: 8),
      ).resolve(code);
      clock.stop();

      expectFound(outcome);
      expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
    });

    test('many impostors cannot shadow the real sender', () async {
      final fakes = [
        for (var i = 0; i < 4; i++) await impostor(_Behaviour.guesses),
        for (var i = 0; i < 2; i++) await impostor(_Behaviour.hangsAtStart),
        await impostor(_Behaviour.silent),
        await impostor(_Behaviour.garbage),
      ];

      final outcome = await resolverFor([
        for (final fake in fakes) announced(fake.port),
        announced(realPort),
      ]).resolve(code);

      expect(expectFound(outcome).payload.tlsFingerprint,
          equals(real.tlsFingerprint));
      for (final fake in fakes.where((f) => f.behaviour != _Behaviour.silent)) {
        expectNothingWorthStealing(fake);
      }
    });

    test('with only impostors, giving up takes one candidate timeout, not '
        'forever', () async {
      final hung = await impostor(_Behaviour.hangsAtStart);
      final silent = await impostor(_Behaviour.silent);

      final clock = Stopwatch()..start();
      final outcome = await resolverFor(
        [announced(hung.port), announced(silent.port)],
        candidateTimeout: const Duration(milliseconds: 800),
      ).resolve(code);
      clock.stop();

      expect(outcome, isA<CodeSessionNotFound>());
      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });

  group('an old build on the other end', () {
    test('is reported as needing an update, not as a wrong code', () async {
      final old = await impostor(_Behaviour.oldBuild);

      final outcome = await resolverFor([announced(old.port)]).resolve(code);

      expect(outcome, isA<CodeSessionUpdateRequired>());
      // Nothing it could keep: it was never asked for the code.
      for (final request in old.seen) {
        expect(request.raw, isNot(contains(code.code)));
        expect(request.raw.toLowerCase(), isNot(contains('devicename')));
      }
    });

    test('a 404 for the route says the same', () async {
      final old = await impostor(_Behaviour.noSuchRoute);

      final outcome = await resolverFor([announced(old.port)]).resolve(code);

      expect(outcome, isA<CodeSessionUpdateRequired>());
    });

    test('a current sender that answered wins over it', () async {
      final old = await impostor(_Behaviour.oldBuild);

      final outcome = await resolverFor(
        [announced(old.port), announced(realPort)],
      ).resolve(code);

      expectFound(outcome);
    });

    test('a current sender that rejected the proof is "wrong code", even '
        'beside an old build', () async {
      final old = await impostor(_Behaviour.oldBuild);
      final wrong = SessionCode.generate();

      final outcome = await resolverFor(
        [announced(old.port), announced(realPort)],
      ).resolve(wrong);

      expect(outcome, isA<CodeSessionNotFound>());
    });
  });

  group('SEC-01-E: what the proof does not by itself rule out', () {
    test('a later connection that presents another certificate is refused, '
        'and is told nothing', () async {
      // The proof was made on the first certificate. Whatever answers the
      // request that follows has to be the device that made it: here a second
      // certificate takes over once the proof is done, as a device that
      // forwards the first connection and then lets it drop would.
      final real = SessionTlsIdentity.generate();
      final other = SessionTlsIdentity.generate();
      final sender = await provingSender([real, real, other]);

      final outcome = await resolverFor([announced(sender.port)]).resolve(code);

      expect(sender.connections, greaterThanOrEqualTo(3),
          reason: 'the premise: a third connection was tried');
      expect(outcome, isA<CodeSessionUnreachable>());
      expect(outcome, isNot(isA<CodeSessionFound>()),
          reason: 'a token from a device that is not the one proved');
      expect(sender.seen.map((r) => r.line),
          isNot(contains('POST /v2/invite/request')),
          reason: 'the second round must not reach a device that was not '
              'proved');
      expect(sender.sawTheRightConfirmation, isFalse);
      for (final request in sender.seen) {
        expect(request.raw, isNot(contains('Test Laptop')));
        expect(request.raw, isNot(contains('"cA"')));
      }
    });

    test('control: the same device on one certificate throughout is found',
        () async {
      final identity = SessionTlsIdentity.generate();
      final sender = await provingSender([identity]);

      final outcome = await resolverFor([announced(sender.port)]).resolve(code);

      expect(expectFound(outcome).payload.tlsFingerprint,
          equals(identity.fingerprint));
      expect(sender.sawTheRightConfirmation, isTrue,
          reason: 'the confirmation is sent once the proof has verified');
    });

    test('the certificate in the session is the one that was proved, not '
        'the one the sender says it has', () async {
      final identity = SessionTlsIdentity.generate();
      final sender = await provingSender([identity],
          reportedFingerprint: 'a-fingerprint-the-sender-made-up');

      final outcome = await resolverFor([announced(sender.port)]).resolve(code);

      final payload = expectFound(outcome).payload;
      expect(payload.tlsFingerprint, equals(identity.fingerprint));
      expect(payload.tlsFingerprint, isNot('a-fingerprint-the-sender-made-up'));
    });

    group('a device is not heard beyond 8 KB', () {
      // A device that has not proved itself yet can say anything, and the
      // receiver reads it into memory. Each answer is padded to be valid in
      // every other way, so what refuses it is its size.
      const tooBig = 20000;

      test('in the health check', () async {
        final sender = await provingSender([SessionTlsIdentity.generate()],
            padding: {'GET /v2/health': tooBig});

        final outcome =
            await resolverFor([announced(sender.port)]).resolve(code);

        expect(outcome, isA<CodeSessionNotFound>());
        expect(sender.seen.map((r) => r.line), equals(['GET /v2/health']),
            reason: 'nothing is sent to a device whose answer was not read');
      });

      test('in the first round', () async {
        final sender = await provingSender([SessionTlsIdentity.generate()],
            padding: {'POST /v2/pake/start': tooBig});

        final outcome =
            await resolverFor([announced(sender.port)]).resolve(code);

        expect(outcome, isA<CodeSessionNotFound>());
        expect(sender.seen.map((r) => r.line),
            isNot(contains('POST /v2/invite/request')));
      });

      test('in the final answer', () async {
        final sender = await provingSender([SessionTlsIdentity.generate()],
            padding: {'POST /v2/invite/request': tooBig});

        final outcome =
            await resolverFor([announced(sender.port)]).resolve(code);

        expect(outcome, isNot(isA<CodeSessionFound>()),
            reason: 'a session made of an answer that was never fully read');
        expect(outcome, isA<CodeSessionUnreachable>());
      });

      test('control: the same answers, unpadded, are accepted', () async {
        final sender = await provingSender([SessionTlsIdentity.generate()]);

        expectFound(await resolverFor([announced(sender.port)]).resolve(code));
      });
    });
  });
}

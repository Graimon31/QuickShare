// The code path never sends the session token in the clear.
//
// Entering a session code used to ask the sender to ALSO push an invitation to
// the receiver: the receiver announced a port, the sender opened a plaintext
// `http://` connection to it and POSTed the session's bearer token. Anybody on
// the same Wi-Fi who could listen on that port — or who simply sat on the
// path — read a token that unlocks the whole transfer. The token was already
// on its way back over the TLS response of the very request that asked for it,
// so the second route added a leak and nothing else.
//
// So on the code path the receiver sends no `invitePort`, and the sender
// returns the token in the TLS response only and never calls `InvitationSender`
// — even for a receiver that still sends the field (an older build, or someone
// who wants the token to be pushed to a listener of their choosing).
//
// The push-to-device feature that the QR screen offers is separate and keeps
// its invitation; it is not under test here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
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

/// A listener on a loopback port, standing in for the receiver's invitation
/// port — or for whoever else is listening there. It records every request and
/// answers 500, so a sender that does reach it fails fast instead of waiting
/// out its 50-second answer window.
class _Spy {
  late final HttpServer _server;
  final List<String> requests = [];

  int get port => _server.port;

  Future<_Spy> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_server.forEach((request) async {
      final body = await utf8.decodeStream(request);
      requests.add('${request.method} ${request.uri.path} $body');
      request.response.statusCode = 500;
      await request.response.close();
    }));
    return this;
  }

  Future<void> stop() => _server.close(force: true);
}

/// A sender that holds the right code and keeps the bytes of the invitation
/// request it is sent — what the wire really carries from a receiver.
class _RecordingSender {
  final SessionCode code;
  final SessionTlsIdentity identity = SessionTlsIdentity.generate();
  final List<Map<String, dynamic>> inviteBodies = [];
  late final HttpServer _https;

  _RecordingSender(this.code);

  int get port => _https.port;

  Future<_RecordingSender> start() async {
    _https = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4, 0, identity.securityContext);
    unawaited(_https.forEach(_handle));
    return this;
  }

  Future<void> stop() => _https.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final response = request.response..headers.contentType = ContentType.json;
    final line = '${request.method} ${request.uri.path}';

    if (line == 'GET /v2/health') {
      response.write(jsonEncode({'protocol': 'QHTP', 'protocolVersion': 1}));
    } else if (line == 'POST /v2/pake/start') {
      final pA = CodePake.decode((jsonDecode(body) as Map)['pA'],
          length: Spake2.shareLength)!;
      final reply = await CodePake.respond(code,
          receiverShare: pA, certFingerprint: identity.fingerprint);
      response.write(jsonEncode({
        'pakeId': 'a' * 32,
        'pB': CodePake.encode(reply.share),
        'cB': CodePake.encode(reply.keys.confirmationB),
      }));
    } else if (line == 'POST /v2/invite/request') {
      inviteBodies.add(jsonDecode(body) as Map<String, dynamic>);
      response.write(jsonEncode({
        'outcome': 'accepted',
        'token': 'token-from-the-tls-response',
        'sessionId': 'session',
        'itemCount': 1,
        'totalBytes': 100,
      }));
    } else {
      response.statusCode = 404;
    }
    await response.close();
  }
}

void main() {
  setUpAll(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());

  const token = 'super-secret-128bit-auth-token';
  late SessionCode code;
  late LocalHttpServer real;
  late int realPort;
  late _Spy spy;

  QhtpManifest manifest() => QhtpManifest(
        sessionId: 'test-session',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        itemCount: 1,
        totalBytes: 100,
        items: const [QhtpItem(id: 'item-1', path: 'file.txt', size: 100)],
      );

  setUp(() async {
    code = SessionCode.generate();
    spy = await _Spy().start();
    real = LocalHttpServer();
    realPort = await real.startQhtpSessionWhileIndexing(
      sessionId: 'test-session',
      index: Future.value(QhtpIndexerResult(
        manifest: manifest(),
        itemIdToAbsPathMap: {'item-1': '/tmp/file.txt'},
      )),
      authToken: token,
      sessionCode: code,
    );
    real.onApprovalRequested = (_) async => true;
  });

  tearDown(() async {
    await real.stop();
    await spy.stop();
  });

  CodeSessionResolver resolverFor(int port) => CodeSessionResolver(
        peers: () => const [],
        probeTargets: (_) async =>
            [(address: InternetAddress.loopbackIPv4, port: port)],
        deviceName: 'Test Laptop',
        discoveryWindow: Duration.zero,
      );

  group('the receiver', () {
    test('asks for the session without offering any place to push a token',
        () async {
      final sender = await _RecordingSender(code).start();
      addTearDown(sender.stop);

      final outcome = await resolverFor(sender.port).resolve(code);

      expect(outcome, isA<CodeSessionFound>());
      expect(sender.inviteBodies, hasLength(1));
      final body = sender.inviteBodies.single;
      expect(body.containsKey('invitePort'), isFalse,
          reason: 'a port to push the token to is exactly what is gone');
      expect(body.keys.toSet(), equals({'pakeId', 'cA', 'deviceName'}));
    });

    test('still receives the token, from the TLS response', () async {
      final outcome = await resolverFor(realPort).resolve(code);

      expect(outcome, isA<CodeSessionFound>());
      final found = outcome as CodeSessionFound;
      expect(found.payload.token, equals(token));
      expect(found.payload.port, equals(realPort));
      expect(spy.requests, isEmpty,
          reason: 'nothing was pushed anywhere in plaintext');
    });

    test('the code path no longer mentions an invitation port at all', () {
      for (final path in [
        'lib/features/receiver/data/client/code_session_resolver.dart',
        'lib/features/receiver/presentation/pages/code_receive_page.dart',
      ]) {
        final source = _read(path);
        expect(source, isNot(contains('invitePort')),
            reason: '$path still reads or sends an invitation port');
      }
    });
  });

  group('the sender', () {
    late Dio dio;

    setUp(() {
      dio = Dio(BaseOptions(
        validateStatus: (_) => true,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ))
        ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
          final c =
              HttpClient(context: SecurityContext(withTrustedRoots: false));
          c.badCertificateCallback =
              (cert, h, p) => SessionTlsIdentity.matches(cert, real.tlsFingerprint!);
          return c;
        });
    });

    /// Both rounds, as a receiver holding the code runs them, with [extra]
    /// added to the invitation request.
    Future<Map<String, dynamic>> askForSession(
        Map<String, dynamic> extra) async {
      final base = 'https://127.0.0.1:$realPort';
      final begun = await CodePake.begin(code);
      final started = await dio.post('$base${CodePake.startPath}',
          data: {'pA': CodePake.encode(begun.share)});
      final answer = Map<String, dynamic>.from(started.data as Map);
      final keys = await CodePake.complete(
        begun,
        senderShare:
            CodePake.decode(answer['pB'], length: Spake2.shareLength)!,
        certFingerprint: real.tlsFingerprint!,
      );
      final response = await dio.post('$base/v2/invite/request', data: {
        'pakeId': answer['pakeId'],
        'cA': CodePake.encode(keys.confirmationA),
        'deviceName': 'Test Laptop',
        ...extra,
      });
      return Map<String, dynamic>.from(response.data as Map);
    }

    test('hands the token over in the TLS response', () async {
      final body = await askForSession(const {});

      expect(body['outcome'], equals('accepted'));
      expect(body['token'], equals(token));
      expect(spy.requests, isEmpty);
    });

    test('ignores an invitation port a receiver still sends', () async {
      // An older build, or anybody who would like the token delivered to a
      // listener they control. The field is not acted on.
      final body = await askForSession({'invitePort': spy.port});

      expect(body['outcome'], equals('accepted'));
      expect(body['token'], equals(token),
          reason: 'the transfer still gets its token');
      expect(spy.requests, isEmpty,
          reason: 'no plaintext request was made to the announced port');
    });

    test('does not call InvitationSender from the invite handler', () {
      final source = _read('lib/features/sender/data/server/local_http_server.dart');
      expect(source, isNot(contains('InvitationSender')));
      expect(source, isNot(contains('invitation_sender.dart')));
    });
  });
}

String _read(String relative) {
  for (final base in ['.', 'quickshare', '..']) {
    final f = File('$base/$relative');
    if (f.existsSync()) return f.readAsStringSync();
  }
  fail('could not find $relative');
}

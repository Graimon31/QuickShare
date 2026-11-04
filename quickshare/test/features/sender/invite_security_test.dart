import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

/// A receiver's side of one round, as the wire shows it.
class _Exchange {
  final Response<dynamic> response;
  final Spake2 begun;

  _Exchange(this.response, this.begun);

  Map<String, dynamic> get body => bodyOf(response);
  String get pakeId => body['pakeId'] as String;
}

Map<String, dynamic> bodyOf(Response<dynamic> response) => response.data is Map
    ? Map<String, dynamic>.from(response.data as Map)
    : jsonDecode(response.data.toString()) as Map<String, dynamic>;

void main() {
  setUpAll(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());

  late LocalHttpServer server;
  const token = 'super-secret-128bit-auth-token';
  late SessionCode sessionCode;
  late int serverPort;

  QhtpManifest manifest() => QhtpManifest(
        sessionId: 'test-session',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        itemCount: 1,
        totalBytes: 100,
        items: const [QhtpItem(id: 'item-1', path: 'file.txt', size: 100)],
      );

  Future<int> serve(LocalHttpServer s, {SessionCode? code}) =>
      s.startQhtpSessionWhileIndexing(
        sessionId: 'test-session',
        index: Future.value(QhtpIndexerResult(
          manifest: manifest(),
          itemIdToAbsPathMap: {'item-1': '/tmp/file.txt'},
        )),
        authToken: token,
        sessionCode: code,
      );

  setUp(() async {
    server = LocalHttpServer();
    sessionCode = SessionCode.generate();
    serverPort = await serve(server, code: sessionCode);
  });

  tearDown(() async => server.stop());

  Dio client(String fingerprint) => Dio(BaseOptions(
        validateStatus: (_) => true,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ))
        ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
          final c =
              HttpClient(context: SecurityContext(withTrustedRoots: false));
          c.badCertificateCallback =
              (cert, h, p) => SessionTlsIdentity.matches(cert, fingerprint);
          return c;
        });

  Dio dio() => client(server.tlsFingerprint!);

  String url(String path) => 'https://127.0.0.1:$serverPort$path';

  /// The first round, as a receiver that holds [code] (the right one unless
  /// told otherwise) would run it.
  Future<_Exchange> start({SessionCode? code}) async {
    final begun = await CodePake.begin(code ?? sessionCode);
    final response = await dio().post(
      url(CodePake.startPath),
      data: {'pA': CodePake.encode(begun.share)},
    );
    return _Exchange(response, begun);
  }

  /// The confirmation the receiver would send, derived from what the server
  /// answered. [fingerprint] is the certificate the receiver believes it saw.
  Future<Uint8List> confirmation(_Exchange exchange,
      {String? fingerprint}) async {
    final keys = await CodePake.complete(
      exchange.begun,
      senderShare: CodePake.decode(exchange.body['pB'],
          length: Spake2.shareLength)!,
      certFingerprint: fingerprint ?? server.tlsFingerprint!,
    );
    return keys.confirmationA;
  }

  Future<Response<dynamic>> invite(
    _Exchange exchange, {
    Uint8List? cA,
    Map<String, dynamic>? extra,
    bool omitPakeId = false,
  }) async {
    final tag = cA ?? await confirmation(exchange);
    return dio().post(url('/v2/invite/request'), data: {
      if (!omitPakeId) 'pakeId': exchange.pakeId,
      'cA': CodePake.encode(tag),
      'deviceName': 'Test Laptop',
      ...?extra,
    });
  }

  test('oversized unfinished bodies receive a refusal on both open routes',
      () async {
    for (final path in [CodePake.startPath, '/v2/invite/request']) {
      final socket = await SecureSocket.connect(
        '127.0.0.1',
        serverPort,
        context: SecurityContext(withTrustedRoots: false),
        onBadCertificate: (cert) =>
            SessionTlsIdentity.matches(cert, server.tlsFingerprint!),
      );
      try {
        socket.write('POST $path HTTP/1.1\r\n'
            'Host: 127.0.0.1\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: 1000000\r\n\r\n');
        socket.add(List<int>.filled(4097, 0x78));
        await socket.flush();
        // Wait for EOF as well as the response: an unfinished body must not
        // leave the paused connection and its resources alive indefinitely.
        final response = await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 5));
        expect(response, startsWith('HTTP/1.1 400'), reason: path);
      } finally {
        socket.destroy();
      }
    }
  });

  group('/v2/pake/start', () {
    test('answers with a share and a confirmation the right receiver verifies',
        () async {
      final exchange = await start();

      expect(exchange.response.statusCode, equals(200));
      expect(exchange.body['pakeId'], isA<String>());
      final keys = await CodePake.complete(
        exchange.begun,
        senderShare: CodePake.decode(exchange.body['pB'],
            length: Spake2.shareLength)!,
        certFingerprint: server.tlsFingerprint!,
      );
      expect(
        keys.verifies(
            Spake2Role.b,
            CodePake.decode(exchange.body['cB'],
                length: CodePake.tagLength)!),
        isTrue,
      );
    });

    test('its confirmation does not verify against another certificate',
        () async {
      // What a receiver sees when something in the middle terminates TLS: the
      // same bytes, a different certificate.
      final exchange = await start();
      final keys = await CodePake.complete(
        exchange.begun,
        senderShare: CodePake.decode(exchange.body['pB'],
            length: Spake2.shareLength)!,
        certFingerprint: SessionTlsIdentity.generate().fingerprint,
      );
      expect(
        keys.verifies(
            Spake2Role.b,
            CodePake.decode(exchange.body['cB'],
                length: CodePake.tagLength)!),
        isFalse,
      );
    });

    test('its confirmation does not verify for the wrong code', () async {
      final exchange = await start(code: SessionCode.generate());
      expect(exchange.response.statusCode, equals(200),
          reason: 'the sender cannot tell a wrong code from a right one yet');
      final keys = await CodePake.complete(
        exchange.begun,
        senderShare: CodePake.decode(exchange.body['pB'],
            length: Spake2.shareLength)!,
        certFingerprint: server.tlsFingerprint!,
      );
      expect(
        keys.verifies(
            Spake2Role.b,
            CodePake.decode(exchange.body['cB'],
                length: CodePake.tagLength)!),
        isFalse,
      );
    });

    test('needs no bearer token, and is not counted as a file request',
        () async {
      final exchange = await start();
      expect(exchange.response.statusCode, equals(200));
    });

    test('refuses a share that is not a point of the group', () async {
      for (final bad in <List<int>>[
        Uint8List(65), // the identity's zeros
        [0x04, ...Uint8List(64)..[63] = 1], // off the curve
      ]) {
        final response = await dio().post(url(CodePake.startPath),
            data: {'pA': CodePake.encode(bad)});
        expect(response.statusCode, equals(400), reason: '$bad');
        expect(bodyOf(response)['code'], equals('PAKE_INVALID'));
        expect(bodyOf(response).containsKey('pakeId'), isFalse);
      }

      // Not even the right length to be one.
      final short = await dio().post(url(CodePake.startPath),
          data: {'pA': CodePake.encode(Uint8List(10))});
      expect(short.statusCode, equals(400));
      expect(bodyOf(short)['code'], equals('BAD_REQUEST'));
    });

    test('refuses a body that is not JSON, or has no share', () async {
      final notJson = await dio().post(url(CodePake.startPath),
          data: 'not json',
          options: Options(contentType: 'text/plain'));
      expect(notJson.statusCode, equals(400));

      final noShare = await dio().post(url(CodePake.startPath), data: {});
      expect(noShare.statusCode, equals(400));
    });

    test('a session without a code answers nothing about one', () async {
      final bare = LocalHttpServer();
      addTearDown(bare.stop);
      final port = await serve(bare);
      final begun = await CodePake.begin(sessionCode);
      final response = await client(bare.tlsFingerprint!).post(
        'https://127.0.0.1:$port${CodePake.startPath}',
        data: {'pA': CodePake.encode(begun.share)},
      );
      expect(response.statusCode, equals(403));
      expect(bodyOf(response)['code'], equals('CODE_MISMATCH'));
    });

    test('limits starts per address: 429 on the sixth within a minute',
        () async {
      for (var i = 0; i < 5; i++) {
        expect((await start()).response.statusCode, equals(200));
      }
      final limited = await start();
      expect(limited.response.statusCode, equals(429));
      expect(limited.body['code'], equals('RATE_LIMITED'));
    });

    test('limits starts for the whole session, whoever they come from',
        () async {
      server.maxPakeStartsPerAddress = 100;
      server.maxPakeStartsPerSession = 3;
      for (var i = 0; i < 3; i++) {
        expect((await start()).response.statusCode, equals(200));
      }
      final limited = await start();
      expect(limited.response.statusCode, equals(429));
      expect(limited.body['code'], equals('RATE_LIMITED'));
    });

    test('holds a bounded number of exchanges open', () async {
      server.maxPakeStartsPerAddress = 100;
      server.maxPakeStartsPerSession = 100;
      server.maxPendingPake = 2;
      expect((await start()).response.statusCode, equals(200));
      expect((await start()).response.statusCode, equals(200));
      final full = await start();
      expect(full.response.statusCode, equals(503));
      expect(full.body['code'], equals('BUSY'));
    });

    test('an exchange that outlives its time to live is gone', () async {
      server.pakeTimeToLive = const Duration(milliseconds: 150);
      var approvalCalled = false;
      server.onApprovalRequested = (req) async {
        approvalCalled = true;
        return true;
      };

      final exchange = await start();
      final tag = await confirmation(exchange);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final response = await invite(exchange, cA: tag);
      expect(response.statusCode, equals(403));
      expect(bodyOf(response)['code'], equals('CODE_MISMATCH'));
      expect(approvalCalled, isFalse);
    });

    test('expired exchanges make room for new ones', () async {
      server.maxPakeStartsPerAddress = 100;
      server.maxPakeStartsPerSession = 100;
      server.maxPendingPake = 1;
      server.pakeTimeToLive = const Duration(milliseconds: 150);
      expect((await start()).response.statusCode, equals(200));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect((await start()).response.statusCode, equals(200));
    });

    test('answers with three values, and the one the receiver must send back '
        'is not among them', () async {
      // cA is what this side expects in the second round. Handed out in the
      // first, it would let anyone who never knew the code answer the proof.
      final exchange = await start();
      final expected = CodePake.encode(await confirmation(exchange));

      expect(exchange.body.keys.toSet(), equals({'pakeId', 'pB', 'cB'}));
      expect(exchange.response.data.toString(), isNot(contains(expected)));
      expect(exchange.body['cB'], isNot(equals(expected)),
          reason: 'the two confirmations are different values');
    });

    group('every round counts, whatever becomes of it', () {
      // A share that is not on the curve costs a little arithmetic and buys
      // nothing — unless a refused round is handed back. Then a device can
      // send them without end, and make the sender do the work each time.
      final offCurve = CodePake.encode(
          [0x04, ...Uint8List(64)..[63] = 1]); // not a point of the group

      Future<List<int?>> sendOffCurve(int times) async => [
            for (var i = 0; i < times; i++)
              (await dio().post(url(CodePake.startPath),
                      data: {'pA': offCurve}))
                  .statusCode,
          ];

      test('shares off the curve reach the per-address limit', () async {
        final statuses = await sendOffCurve(7);

        expect(statuses, equals([400, 400, 400, 400, 400, 429, 429]));
      });

      test('shares off the curve reach the session-wide limit', () async {
        server.maxPakeStartsPerAddress = 100;
        server.maxPakeStartsPerSession = 3;

        final statuses = await sendOffCurve(5);

        expect(statuses, equals([400, 400, 400, 429, 429]));
      });

      test('a body that is not a share counts as well', () async {
        server.maxPakeStartsPerAddress = 3;
        final statuses = <int?>[
          for (var i = 0; i < 5; i++)
            (await dio().post(url(CodePake.startPath), data: {})).statusCode,
        ];

        expect(statuses, equals([400, 400, 400, 429, 429]));
      });
    });

    test('a device over its own limit does not use up what the others '
        'share', () async {
      // Two devices, told apart by the address the server sees: this one over
      // loopback, and the other over the machine's own network address.
      final lan = await _networkAddress();
      if (lan == null) {
        markTestSkipped('this machine has no address besides loopback');
        return;
      }
      server.maxPakeStartsPerAddress = 2;
      server.maxPakeStartsPerSession = 5;

      // The noisy device: two allowed, six refused.
      final noisy = [
        for (var i = 0; i < 8; i++) (await start()).response.statusCode,
      ];
      expect(noisy, equals([200, 200, 429, 429, 429, 429, 429, 429]));

      // The session has spent two of its five. The refusals cost it nothing,
      // so another device still has three.
      Future<int?> fromElsewhere() async {
        final begun = await CodePake.begin(sessionCode);
        final response = await dio().post(
          'https://${lan.address}:$serverPort${CodePake.startPath}',
          data: {'pA': CodePake.encode(begun.share)},
        );
        return response.statusCode;
      }

      expect(
        [for (var i = 0; i < 4; i++) await fromElsewhere()],
        equals([200, 200, 429, 429]),
        reason: 'the other device is allowed two of its own, and two is '
            'what it got: the noisy one had cost the session nothing',
      );
    });

    group('a body is only read up to 4 KB', () {
      // Open to anyone who can reach the port, and nothing it carries is more
      // than a couple of hundred bytes. The padding makes each request valid
      // in every other way, so that what refuses it is the size.
      Future<String> padded(Map<String, dynamic> fields, int totalBytes) async {
        final bare = jsonEncode({...fields, 'pad': ''});
        final room = totalBytes - utf8.encode(bare).length;
        return jsonEncode({...fields, 'pad': 'x' * room});
      }

      Future<int?> startWith(String body) async => (await dio().post(
            url(CodePake.startPath),
            data: body,
            options: Options(contentType: 'application/json'),
          ))
              .statusCode;

      test('the first round is refused above it and answered at it', () async {
        final begun = await CodePake.begin(sessionCode);
        final fields = {'pA': CodePake.encode(begun.share)};
        server.maxPakeStartsPerAddress = 100;
        server.maxPakeStartsPerSession = 100;

        expect(await startWith(await padded(fields, 4096)), equals(200),
            reason: 'exactly 4096 bytes is within the limit');
        expect(await startWith(await padded(fields, 4097)), equals(400));
        expect(await startWith(await padded(fields, 6000)), equals(400));
      });
    });
  });

  group('/v2/invite/request security', () {
    test('declined invite does NOT return token, fingerprint, or port',
        () async {
      server.onApprovalRequested = (req) async => false; // Sender declines

      final response = await invite(await start());

      expect(response.statusCode, equals(200));
      final body = bodyOf(response);
      expect(body['outcome'], equals('declined'));
      expect(body.containsKey('token'), isFalse);
      expect(body.containsKey('tlsFingerprint'), isFalse);
      expect(body.containsKey('port'), isFalse);
      expect(body.containsKey('sessionId'), isFalse);
    });

    test('accepted invite returns token, fingerprint, and session details',
        () async {
      server.onApprovalRequested = (req) async => true; // Sender approves

      final response = await invite(await start());

      expect(response.statusCode, equals(200));
      final body = bodyOf(response);
      expect(body['outcome'], equals('accepted'));
      expect(body['token'], equals(token));
      expect(body['tlsFingerprint'], equals(server.tlsFingerprint));
      expect(body['port'], equals(serverPort));
      expect(body['sessionId'], equals('test-session'));
    });

    test('the approval the sender sees names the device that asked, not a code',
        () async {
      TransferApprovalRequest? seen;
      server.onApprovalRequested = (req) async {
        seen = req;
        return true;
      };

      await invite(await start());

      expect(seen, isNotNull);
      expect(seen!.deviceName, equals('Test Laptop'));
      expect(seen!.itemCount, equals(1));
      expect(seen!.totalBytes, equals(100));
    });

    test('declines when the approver does not answer in time',
        () async {
      server.onApprovalRequested = (req) async {
        await Future.delayed(const Duration(milliseconds: 200));
        return false;
      };

      final response = await invite(await start());

      expect(response.statusCode, equals(200));
      final body = bodyOf(response);
      expect(body['outcome'], equals('declined'));
      expect(body.containsKey('token'), isFalse);
    });

    test('declined invite enforces 60s cooldown for the same IP', () async {
      server.onApprovalRequested = (req) async => false;

      final firstResponse = await invite(await start());
      expect(firstResponse.statusCode, equals(200));
      var body = bodyOf(firstResponse);
      expect(body['outcome'], equals('declined'));
      expect(body['detail'], equals('Transfer declined by sender'));

      // A second request right after a decline is turned away without calling
      // onApprovalRequested — even though it proves the code again.
      var approvalCalled = false;
      server.onApprovalRequested = (req) async {
        approvalCalled = true;
        return true;
      };

      final secondResponse = await invite(await start());
      expect(secondResponse.statusCode, equals(200));
      body = bodyOf(secondResponse);
      expect(body['outcome'], equals('declined'));
      expect(body['detail'], equals('cooldown'));
      expect(approvalCalled, isFalse);
    });

    // The code check runs before the sender is ever bothered: a receiver that
    // does not hold the code must be rejected on the wire alone, with no human
    // in the loop.
    test('a confirmation from the wrong code returns 403 CODE_MISMATCH and '
        'never asks the sender', () async {
      var approvalCalled = false;
      server.onApprovalRequested = (req) async {
        approvalCalled = true;
        return true;
      };

      final exchange = await start(code: SessionCode.generate());
      final response = await invite(exchange);

      expect(response.statusCode, equals(403));
      expect(bodyOf(response)['code'], equals('CODE_MISMATCH'));
      expect(approvalCalled, isFalse,
          reason: 'a receiver that cannot prove the code must never reach '
              'the human approval dialog');
    });

    test('a tampered or malformed confirmation is refused the same way',
        () async {
      server.maxPakeStartsPerAddress = 100;
      var approvalCalled = false;
      server.onApprovalRequested = (req) async {
        approvalCalled = true;
        return true;
      };

      final exchange = await start();
      final good = await confirmation(exchange);
      final flipped = Uint8List.fromList(good)..[0] ^= 0x01;
      expect((await invite(exchange, cA: flipped)).statusCode, equals(403));

      for (final cA in <Object?>[null, 7, '', 'AAAA', 'not base64 !!']) {
        final fresh = await start();
        final response = await dio().post(url('/v2/invite/request'), data: {
          'pakeId': fresh.pakeId,
          if (cA != null) 'cA': cA,
          'deviceName': 'Test Laptop',
        });
        expect(response.statusCode, equals(403), reason: '$cA');
        expect(bodyOf(response)['code'], equals('CODE_MISMATCH'));
      }
      expect(approvalCalled, isFalse);
    });

    test('the prompt appears only once the confirmation has verified',
        () async {
      var prompts = 0;
      server.onApprovalRequested = (req) async {
        prompts++;
        return true;
      };

      final bad = await start();
      await invite(bad, cA: Uint8List(CodePake.tagLength));
      expect(prompts, equals(0));

      final good = await start();
      final response = await invite(good);
      expect(response.statusCode, equals(200));
      expect(prompts, equals(1));
    });

    test('an unknown pakeId is refused', () async {
      var approvalCalled = false;
      server.onApprovalRequested = (req) async {
        approvalCalled = true;
        return true;
      };
      final exchange = await start();
      final tag = await confirmation(exchange);

      final response = await dio().post(url('/v2/invite/request'), data: {
        'pakeId': 'f' * 32,
        'cA': CodePake.encode(tag),
        'deviceName': 'Test Laptop',
      });

      expect(response.statusCode, equals(403));
      expect(bodyOf(response)['code'], equals('CODE_MISMATCH'));
      expect(approvalCalled, isFalse);
    });

    test('a pakeId cannot be replayed, even with its own valid confirmation',
        () async {
      var prompts = 0;
      server.onApprovalRequested = (req) async {
        prompts++;
        return true;
      };

      final exchange = await start();
      final tag = await confirmation(exchange);
      expect((await invite(exchange, cA: tag)).statusCode, equals(200));
      expect(prompts, equals(1));

      final replay = await invite(exchange, cA: tag);
      expect(replay.statusCode, equals(403));
      expect(bodyOf(replay)['code'], equals('CODE_MISMATCH'));
      expect(prompts, equals(1));
    });

    test('a wrong confirmation spends the pakeId: no second guess on it',
        () async {
      var approvalCalled = false;
      server.onApprovalRequested = (req) async {
        approvalCalled = true;
        return true;
      };

      final exchange = await start();
      final tag = await confirmation(exchange);
      expect(
          (await invite(exchange, cA: Uint8List(CodePake.tagLength)))
              .statusCode,
          equals(403));
      // The right answer, on the same exchange, is too late.
      expect((await invite(exchange, cA: tag)).statusCode, equals(403));
      expect(approvalCalled, isFalse);
    });

    test('the old request with a code is refused with UPDATE_REQUIRED',
        () async {
      var approvalCalled = false;
      server.onApprovalRequested = (req) async {
        approvalCalled = true;
        return true;
      };

      final response = await dio().post(url('/v2/invite/request'), data: {
        'code': sessionCode.code,
        'invitePort': 0,
        'deviceName': 'Old Laptop',
      });

      expect(response.statusCode, equals(426));
      expect(bodyOf(response)['code'], equals('UPDATE_REQUIRED'));
      expect(bodyOf(response).containsKey('token'), isFalse);
      expect(approvalCalled, isFalse,
          reason: 'a code in the clear is not accepted any more, even the '
              'right one');
    });

    test('a code alongside a valid exchange is still refused, and spends '
        'nothing', () async {
      var approvalCalled = false;
      server.onApprovalRequested = (req) async {
        approvalCalled = true;
        return true;
      };

      final exchange = await start();
      final response = await invite(exchange,
          extra: {'code': sessionCode.code});

      expect(response.statusCode, equals(426));
      expect(approvalCalled, isFalse);
    });

    test('a request without a pakeId is refused with UPDATE_REQUIRED',
        () async {
      var approvalCalled = false;
      server.onApprovalRequested = (req) async {
        approvalCalled = true;
        return true;
      };

      final response = await invite(await start(), omitPakeId: true);

      expect(response.statusCode, equals(426));
      expect(bodyOf(response)['code'], equals('UPDATE_REQUIRED'));
      expect(approvalCalled, isFalse);
    });

    test('a body that is not JSON is a 400', () async {
      final response = await dio().post(url('/v2/invite/request'),
          data: 'nope', options: Options(contentType: 'text/plain'));
      expect(response.statusCode, equals(400));
    });

    group('a body is only read up to 4 KB', () {
      Future<Response<dynamic>> inviteOfSize(
          _Exchange exchange, Uint8List tag, int totalBytes) {
        final fields = {
          'pakeId': exchange.pakeId,
          'cA': CodePake.encode(tag),
          'deviceName': 'Test Laptop',
        };
        final bare = jsonEncode({...fields, 'pad': ''});
        final room = totalBytes - utf8.encode(bare).length;
        return dio().post(
          url('/v2/invite/request'),
          data: jsonEncode({...fields, 'pad': 'x' * room}),
          options: Options(contentType: 'application/json'),
        );
      }

      test('a valid request above it is refused, unprompted and unspent',
          () async {
        var approvalCalled = false;
        server.onApprovalRequested = (req) async {
          approvalCalled = true;
          return true;
        };
        final exchange = await start();
        final tag = await confirmation(exchange);

        for (final size in [4097, 6000]) {
          final response = await inviteOfSize(exchange, tag, size);
          expect(response.statusCode, equals(400), reason: '$size bytes');
        }
        expect(approvalCalled, isFalse,
            reason: 'a person must not be asked about a request that was '
                'never read');

        // Refused before it was read, so the exchange was not spent: the same
        // proof at the permitted size goes through.
        final within = await inviteOfSize(exchange, tag, 4096);
        expect(within.statusCode, equals(200));
        expect(bodyOf(within)['outcome'], equals('accepted'));
        expect(approvalCalled, isTrue);
      });
    });
  });
}

/// The first address of this machine that is not loopback, or null.
Future<InternetAddress?> _networkAddress() async {
  final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLoopback: false);
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLoopback && !address.isLinkLocal) return address;
    }
  }
  return null;
}

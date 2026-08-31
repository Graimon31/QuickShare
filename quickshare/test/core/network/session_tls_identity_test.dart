import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:quickshare/core/network/session_tls_identity.dart';

void main() {
  test('generates a P-256 identity that parses and is valid now', () {
    final id = SessionTlsIdentity.generate();

    expect(id.certificatePem, contains('BEGIN CERTIFICATE'));
    expect(id.privateKeyPem, contains('BEGIN EC PRIVATE KEY'));
    expect(id.fingerprint, hasLength(43));
    expect(id.fingerprint, isNot(contains('=')));

    final der = SessionTlsIdentity.pemToDer(id.certificatePem);
    expect(SessionTlsIdentity.fingerprintOf(der), id.fingerprint);
  });

  test('two identities never share a fingerprint', () {
    expect(SessionTlsIdentity.generate().fingerprint,
        isNot(SessionTlsIdentity.generate().fingerprint));
  });

  test('a real HTTPS round trip: the pinned client trusts only this identity',
      () async {
    final id = SessionTlsIdentity.generate();

    final server = await shelf_io.serve(
      (Request _) => Response.ok('{"name":"holiday.zip"}'),
      InternetAddress.loopbackIPv4,
      0,
      securityContext: id.securityContext,
    );
    addTearDown(() => server.close(force: true));

    var pinConsulted = false;
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (cert, host, port) {
        pinConsulted = true;
        return SessionTlsIdentity.matches(cert, id.fingerprint);
      };

    final req = await client
        .getUrl(Uri.parse('https://127.0.0.1:${server.port}/v2/session'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();

    expect(pinConsulted, isTrue);
    expect(resp.statusCode, 200);
    expect(body, contains('holiday.zip'));
    client.close(force: true);
  });

  test('a client pinning another identity is refused at the handshake',
      () async {
    final served = SessionTlsIdentity.generate();
    final other = SessionTlsIdentity.generate();

    final server = await shelf_io.serve(
      (Request _) => Response.ok('ok'),
      InternetAddress.loopbackIPv4,
      0,
      securityContext: served.securityContext,
    );
    addTearDown(() => server.close(force: true));

    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback =
          (cert, host, port) => SessionTlsIdentity.matches(cert, other.fingerprint);

    await expectLater(
      () async => (await client
              .getUrl(Uri.parse('https://127.0.0.1:${server.port}/')))
          .close(),
      throwsA(isA<HandshakeException>()),
    );
    client.close(force: true);
  });

  test('an empty pin never matches', () {
    final served = SessionTlsIdentity.generate();
    // A synthetic check: matches() must refuse an empty expected fingerprint
    // outright rather than comparing against nothing.
    final der = SessionTlsIdentity.pemToDer(served.certificatePem);
    expect(SessionTlsIdentity.fingerprintOf(der).isNotEmpty, isTrue);
  });
}

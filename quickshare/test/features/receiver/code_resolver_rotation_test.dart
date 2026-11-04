// Finding a sender by its code, when the code keeps changing.
//
// A receiver who types a code searches the network for the device offering it.
// The code a sender offers is replaced every five minutes, so the search has
// to follow: the new code finds the sender (whose announced hint moved with
// it), and the old one finds nothing — it is not a stale alias, it is simply
// wrong. And only candidates whose hint matches the typed code are ever asked
// anything; a device announcing a different hint is never even connected to.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/session_code.dart';
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

/// A listener that only counts who knocked.
class _Bystander {
  late final ServerSocket _socket;
  int connections = 0;

  int get port => _socket.port;

  Future<_Bystander> start() async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket.listen((s) {
      connections++;
      s.destroy();
    });
    return this;
  }

  Future<void> stop() => _socket.close();
}

void main() {
  setUpAll(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());

  late LocalHttpServer server;
  late SessionCode code;
  late int port;
  late _Bystander bystander;

  QhtpManifest manifest() => QhtpManifest(
        sessionId: 'resolver-session',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        itemCount: 1,
        totalBytes: 100,
        items: const [QhtpItem(id: 'item-1', path: 'file.txt', size: 100)],
      );

  setUp(() async {
    code = SessionCode.generate();
    server = LocalHttpServer();
    port = await server.startQhtpSessionWhileIndexing(
      sessionId: 'resolver-session',
      index: Future.value(QhtpIndexerResult(
        manifest: manifest(),
        itemIdToAbsPathMap: {'item-1': '/tmp/file.txt'},
      )),
      authToken: 'token-one-00000000000000000000000',
      sessionCode: code,
    );
    server.onApprovalRequested = (_) async => true;
    bystander = await _Bystander().start();
  });

  tearDown(() async {
    await server.stop();
    await bystander.stop();
  });

  /// What the sender announces right now: its current hint on its port.
  RendezvousCandidate announced(SessionCode current) => RendezvousCandidate(
        address: InternetAddress.loopbackIPv4,
        port: port,
        hint: current.discoveryHint,
      );

  CodeSessionResolver resolver(List<RendezvousCandidate> Function() heard) =>
      CodeSessionResolver(
        peers: heard,
        probeTargets: (_) async => const [],
        deviceName: 'Test Laptop',
        discoveryWindow: Duration.zero,
      );

  test('finds the sender by the code it is showing', () async {
    final outcome = await resolver(() => [announced(code)]).resolve(code);

    expect(outcome, isA<CodeSessionFound>());
    expect((outcome as CodeSessionFound).payload.port, port);
  });

  test('after a rotation the new code finds it and the old one does not',
      () async {
    final newCode = SessionCode.generate();
    expect(
        server.rotateCredentials(
            authToken: 'token-two-00000000000000000000000',
            sessionCode: newCode),
        isTrue);
    // What is on the air moved with it.
    List<RendezvousCandidate> heard() => [announced(newCode)];

    final fresh = await resolver(heard).resolve(newCode);
    expect(fresh, isA<CodeSessionFound>());
    expect((fresh as CodeSessionFound).payload.token,
        'token-two-00000000000000000000000');

    final stale = await resolver(heard).resolve(code);
    expect(stale, isA<CodeSessionNotFound>(),
        reason: 'the old code names nobody any more');
  });

  test('a stale announcement of the old hint cannot be talked into the new '
      'session: the proof fails, not just the hint', () async {
    final newCode = SessionCode.generate();
    server.rotateCredentials(
        authToken: 'token-two-00000000000000000000000', sessionCode: newCode);

    // The old announcement is still in someone's cache. The hint matches the
    // old code, so the receiver asks — and the proof of the old code fails.
    final outcome = await resolver(() => [announced(code)]).resolve(code);

    expect(outcome, isA<CodeSessionNotFound>());
  });

  test('a device announcing another hint is never contacted', () async {
    final other = SessionCode.generate();
    // Make sure the two hints really differ; one byte can collide.
    var wrong = other;
    while (wrong.discoveryHint == code.discoveryHint) {
      wrong = SessionCode.generate();
    }
    final heard = [
      RendezvousCandidate(
        address: InternetAddress.loopbackIPv4,
        port: bystander.port,
        hint: wrong.discoveryHint,
      ),
      announced(code),
    ];

    final outcome = await resolver(() => heard).resolve(code);

    expect(outcome, isA<CodeSessionFound>());
    expect(bystander.connections, 0,
        reason: 'a candidate with another channel hint was dialled');
  });

  test('a candidate with the same hint is asked, and has to prove the code',
      () async {
    final spoof = RendezvousCandidate(
      address: InternetAddress.loopbackIPv4,
      port: bystander.port,
      hint: code.discoveryHint,
    );

    final outcome = await resolver(() => [spoof]).resolve(code);

    expect(outcome, isA<CodeSessionNotFound>());
    expect(bystander.connections, greaterThan(0),
        reason: 'a matching hint is the one reason to knock');
  });

  test('a sender announced after the search began is still found within the '
      'window', () async {
    final updates = StreamController<List<RendezvousCandidate>>();
    addTearDown(updates.close);
    final r = CodeSessionResolver(
      peers: () => const [],
      peerUpdates: updates.stream,
      probeTargets: (_) async => const [],
      deviceName: 'Test Laptop',
      discoveryWindow: const Duration(seconds: 3),
    );

    final pending = r.resolve(code);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    updates.add([announced(code)]);

    expect(await pending, isA<CodeSessionFound>());
  });
}

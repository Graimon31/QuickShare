// Two ways an internet transfer ends without sending anything, and neither
// of them is "failed unexpectedly".
//
// DD-11 — ICE never found a route. The state for it existed and the screen was
// already listening for it; nobody emitted it, so a VPN or a closed NAT
// reached the person as a snackbar in English that named no cause and offered
// no way out.
//
// DD-12 — the only route was a relay and the session was too big to put
// through somebody else's bandwidth. The transport refused correctly and then
// reported a failure on top of it; both reached the bloc, the failure arrived
// second, and it replaced the explanation on its way to the screen.
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';

class _MockSenderRepository extends Mock implements SenderRepository {}

/// Stands in for the native side, which does not exist under `flutter test`.
class _FakePeerLink extends PeerLinkService {
  const _FakePeerLink();
  @override
  bool get supported => false;
  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockSenderRepository repository;

  setUp(() {
    repository = _MockSenderRepository();
    when(() => repository.transferProgress)
        .thenAnswer((_) => const Stream.empty());
    when(() => repository.statusStream).thenAnswer((_) => const Stream.empty());
    when(() => repository.stopServer(force: any(named: 'force')))
        .thenAnswer((_) async => const Right(null));
    when(() => repository.lastQhtpClientAddress).thenReturn(null);
    when(() => repository.sessionTlsFingerprint).thenReturn('cert');
  });

  blocTest<SenderBloc, SenderState>(
    'no route reaches the screen that explains it, not an error snackbar',
    build: () => SenderBloc(
        repository: repository, peerLinkService: const _FakePeerLink()),
    act: (bloc) => bloc.add(const NoPathFound()),
    expect: () => [isA<NoUsablePathFound>()],
    verify: (_) {
      // The distinction is the whole point: `SenderError` puts "Transfer
      // failed unexpectedly" in front of somebody whose VPN is the cause.
    },
  );

  blocTest<SenderBloc, SenderState>(
    'a session too big for a relay ends on the fallback screen',
    build: () => SenderBloc(
        repository: repository, peerLinkService: const _FakePeerLink()),
    act: (bloc) => bloc.add(const RelayBlocked(3000000000, 2000000000)),
    expect: () => [
      isA<RelayTooExpensive>()
          .having((s) => s.sessionBytes, 'sessionBytes', 3000000000)
          .having((s) => s.limitBytes, 'limitBytes', 2000000000),
    ],
  );

  blocTest<SenderBloc, SenderState>(
    'and a failure arriving after it does not replace the explanation',
    // The order the transport used to produce: refusal, then failure. What
    // the person needs to read is the first one.
    build: () => SenderBloc(
        repository: repository, peerLinkService: const _FakePeerLink()),
    act: (bloc) async {
      bloc.add(const RelayBlocked(3000000000, 2000000000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      bloc.add(const TransferFailed('Transfer failed unexpectedly'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
    verify: (bloc) {
      expect(bloc.state, isA<RelayTooExpensive>(),
          reason: 'the refusal is the outcome; nothing was ever sent');
    },
  );
}

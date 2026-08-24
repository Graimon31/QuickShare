// Selecting several files and sending them over Bluetooth used to send one.
//
// The native Bluetooth bridge advertises a single file and has no manifest,
// so the sender took `files.first` and the rest of the selection vanished
// without a message, an error, or anything on screen to suggest it. The
// DataChannel path had grown a manifest and this one silently had not.
//
// Now the selection is bundled for that transport. Worse than a manifest —
// the recipient gets a .zip rather than photos in their gallery — but it
// sends what the user picked, which is the part that was not negotiable.
import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';

class _MockSenderRepository extends Mock implements SenderRepository {}

/// Stands in for the native side, which does not exist under `flutter test`.
class _FakePeerLink extends PeerLinkService {
  const _FakePeerLink();

  @override
  Future<void> host({required String serviceName, required int localPort}) async {}

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('quickshare/bluetooth');
  const events = MethodChannel('quickshare/bluetooth/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory workspace;
  late _MockSenderRepository repository;
  late List<MethodCall> nativeCalls;

  setUp(() {
    // The bridge is chosen from the target platform, not the host, so the
    // Apple path is what this exercises wherever the suite runs.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    workspace = Directory.systemTemp.createTempSync('dd_bt_multi_');
    nativeCalls = [];

    messenger.setMockMethodCallHandler(method, (call) async {
      nativeCalls.add(call);
      return null;
    });
    // The transport subscribes to the event channel on initialize().
    messenger.setMockMethodCallHandler(events, (call) async => null);

    repository = _MockSenderRepository();
    when(() => repository.transferProgress)
        .thenAnswer((_) => const Stream.empty());
    when(() => repository.statusStream).thenAnswer((_) => const Stream.empty());
    when(repository.stopServer).thenAnswer((_) async => const Right(null));
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockMethodCallHandler(events, null);
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  File write(String name) => File(p.join(workspace.path, name))
    ..writeAsStringSync('contents of $name');

  /// The path the native bridge was actually told to advertise.
  Future<String> advertisedPath(List<String> paths) async {
    final bloc = SenderBloc(repository: repository);
    addTearDown(bloc.close);

    final advertising = bloc.stream.firstWhere((s) => s is BluetoothAdvertising);
    bloc.add(StartQhtpSend(paths, mode: TransportType.bluetooth));
    await advertising.timeout(const Duration(seconds: 20));

    final call = nativeCalls.firstWhere((c) => c.method == 'startAdvertising');
    return (call.arguments as Map)['filePath'] as String;
  }

  test('progress on the fast path moves the sender off its QR code', () async {
    // The file went out over the direct link, finished, and the sender screen
    // sat on its QR the whole time — no progress, no completion, nothing to
    // say it had worked. Reported as "the QR never changed", and it is
    // indistinguishable from a hung app.
    final progress = StreamController<double>.broadcast();
    addTearDown(progress.close);
    when(() => repository.transferProgress)
        .thenAnswer((_) => progress.stream);
    when(() => repository.startQhtpTransfer(any(),
            authToken: any(named: 'authToken')))
        .thenAnswer((_) async => Right(TransferSession(
              id: 'fast-path',
              fileMetadata: const FileMetadata(
                name: 'holiday.mov',
                path: '/tmp/holiday.mov',
                size: 1000,
                mimeType: 'video/quicktime',
              ),
              serverPort: 8000,
              authToken: 'tok',
              localIp: '127.0.0.1',
              startedAt: DateTime.now(),
            )));

    final bloc = SenderBloc(
      repository: repository,
      peerLinkService: const _FakePeerLink(),
    );
    addTearDown(bloc.close);
    final advertising = bloc.stream.firstWhere((s) => s is BluetoothAdvertising);
    bloc.add(StartQhtpSend([write('holiday.mov').path],
        mode: TransportType.bluetooth));
    await advertising.timeout(const Duration(seconds: 20));

    final moved = bloc.stream.firstWhere((s) => s is Transferring);
    progress.add(0.5);
    await expectLater(moved.timeout(const Duration(seconds: 10)),
        completes);
  });

  test('the fast path accepts the token the receiver actually has', () async {
    // The receiver on the far side of a Bluetooth session holds one token:
    // the Bluetooth one. A QHTP session minting its own answered 401 to the
    // only device it existed to serve, and the screen reported a connection
    // failure before falling back on the retry.
    final captured = <String?>[];
    when(() => repository.startQhtpTransfer(any(),
            authToken: any(named: 'authToken')))
        .thenAnswer((invocation) async {
      captured.add(invocation.namedArguments[#authToken] as String?);
      return const Left(NetworkFailure('not needed for this test'));
    });

    final only = write('holiday.mov');
    await advertisedPath([only.path]);

    final advertisedToken =
        (nativeCalls.firstWhere((c) => c.method == 'startAdvertising').arguments
            as Map)['sessionToken'] as String;
    expect(captured.single, equals(advertisedToken),
        reason: 'both halves of one session have to agree on its token');
  });

  test('three files are all sent, not just the first', () async {
    final files = [write('one.txt'), write('two.txt'), write('three.txt')];

    final sent = await advertisedPath([for (final f in files) f.path]);

    expect(p.extension(sent), equals('.zip'),
        reason: 'the bridge carries one file, so the selection is bundled');

    final names = ZipDecoder()
        .decodeBytes(File(sent).readAsBytesSync())
        .files
        .map((f) => p.basename(f.name))
        .toSet();
    expect(names, containsAll(['one.txt', 'two.txt', 'three.txt']),
        reason: 'every file the user picked has to be in there');

    File(sent).deleteSync();
  });

  test('a broken fast path does not take the Bluetooth transfer with it',
      () async {
    // The direct Wi-Fi route is offered alongside Bluetooth, not instead of
    // it. The repository here has no `startQhtpTransfer` stub at all, so
    // setting that route up throws — and the transfer the user actually asked
    // for still has to go out.
    final files = [write('one.txt'), write('two.txt')];

    final sent = await advertisedPath([for (final f in files) f.path]);

    expect(p.extension(sent), equals('.zip'),
        reason: 'Bluetooth advertised regardless of the extra route failing');
  });

  test('a single file is still sent as itself, not wrapped in an archive',
      () async {
    final only = write('holiday.mov');

    final sent = await advertisedPath([only.path]);

    expect(sent, equals(only.path),
        reason: 'bundling one file would only make it harder to open');
  });
}

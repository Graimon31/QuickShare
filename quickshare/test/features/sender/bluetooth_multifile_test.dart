// Selecting several files and sending them over Bluetooth used to send one.
//
// The native Bluetooth bridge advertised a single file and had no manifest,
// so the sender took `files.first` and the rest of the selection vanished
// without a message, an error, or anything on screen to suggest it. The
// stopgap after that was a .zip: it sent everything, at the price of handing
// the recipient an archive to unpack instead of photos in their gallery.
//
// The bridge now takes the whole list, each file carrying the relative path
// it keeps on the far side — so a folder crosses Bluetooth as a folder and
// nothing is bundled into anything.
import 'dart:async';
import 'dart:io';

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

  // The fast path exists on iOS and macOS; CI runs on Linux, where the real
  // answer is false and these tests asserted an empty branch.
  @override
  bool get supported => true;

  @override
  Future<void> host({
    required String serviceName,
    required int localPort,
    Duration timeout = const Duration(seconds: 5),
  }) async {}

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

  /// The arguments the native bridge was actually handed.
  Future<Map> advertised(List<String> paths) async {
    final bloc = SenderBloc(repository: repository);
    addTearDown(bloc.close);

    final advertising = bloc.stream.firstWhere((s) => s is BluetoothAdvertising);
    bloc.add(StartQhtpSend(paths, mode: TransportType.bluetooth));
    await advertising.timeout(const Duration(seconds: 20));

    final call = nativeCalls.firstWhere((c) => c.method == 'startAdvertising');
    return call.arguments as Map;
  }

  /// The path the native bridge leads with — the session's first file.
  Future<String> advertisedPath(List<String> paths) async =>
      (await advertised(paths))['filePath'] as String;

  /// Every file the bridge was told to send, in order.
  Future<List<Map>> advertisedFiles(List<String> paths) async =>
      ((await advertised(paths))['files'] as List).cast<Map>();

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

  test('several files are never packed into an archive', () async {
    // A .zip buys nothing here — both wire protocols carry a manifest — and
    // costs the recipient an archive to unpack instead of photos that land in
    // their gallery.
    final files = [write('one.txt'), write('two.txt'), write('three.txt')];

    final sent = await advertisedPath([for (final f in files) f.path]);

    expect(p.extension(sent), isNot(equals('.zip')));
    expect(sent, equals(files.first.path),
        reason: 'the selection goes as itself, over whichever route can '
            'carry all of it');
  });

  test('a broken fast path does not take the Bluetooth transfer with it',
      () async {
    // The direct Wi-Fi route is offered alongside Bluetooth, not instead of
    // it. The repository here has no `startQhtpTransfer` stub at all, so
    // setting that route up throws — and the transfer the user actually asked
    // for still has to go out.
    final files = [write('one.txt'), write('two.txt')];

    final sent = await advertisedPath([for (final f in files) f.path]);

    expect(sent, equals(files.first.path),
        reason: 'Bluetooth advertised regardless of the extra route failing');
  });

  test('a single file is still sent as itself, not wrapped in an archive',
      () async {
    final only = write('holiday.mov');

    final sent = await advertisedPath([only.path]);

    expect(sent, equals(only.path),
        reason: 'bundling one file would only make it harder to open');
  });

  test('every file in the selection reaches the bridge', () async {
    // The whole list, not just the one whose name the QR screen shows.
    final files = [write('one.txt'), write('two.txt'), write('three.txt')];

    final advertised = await advertisedFiles([for (final f in files) f.path]);

    expect(advertised.map((f) => f['filePath']).toSet(),
        equals({for (final f in files) f.path}));
  });

  test('a folder goes as its files, each keeping where it sits', () async {
    // What used to be a .zip. The bridge gets the tree flattened into a list
    // of files, and the relative path on each is what puts the folder back
    // together on the far side.
    final trip = Directory(p.join(workspace.path, 'Trip'))..createSync();
    Directory(p.join(trip.path, 'Day 2')).createSync();
    File(p.join(trip.path, 'IMG_0001.jpg')).writeAsStringSync('a');
    File(p.join(trip.path, 'Day 2', 'IMG_0002.jpg')).writeAsStringSync('b');

    final advertised = await advertisedFiles([trip.path]);

    expect(advertised.map((f) => f['relativePath']).toList(),
        equals(['Trip/Day 2/IMG_0002.jpg', 'Trip/IMG_0001.jpg']));
    expect(advertised.map((f) => f['fileName']).toList(),
        equals(['IMG_0002.jpg', 'IMG_0001.jpg']));
    expect(advertised.every((f) => !(f['filePath'] as String).endsWith('.zip')),
        isTrue,
        reason: 'no archive is written for a folder any more');
  });

  test('a plain file announces no folder to rebuild', () async {
    final only = write('holiday.mov');

    final advertised = await advertisedFiles([only.path]);

    expect(advertised.single['relativePath'], equals('holiday.mov'));
  });
}

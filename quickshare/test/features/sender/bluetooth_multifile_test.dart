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

import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';

class _MockSenderRepository extends Mock implements SenderRepository {}

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

// A Wi-Fi transfer, on real hardware, all the way to the placement decision.
//
//     flutter test integration_test/wifi_placement_e2e_test.dart -d macos
//     flutter test integration_test/wifi_placement_e2e_test.dart -d <iphone-id>
//
// One file per invocation on macOS: two integration_test files in a single
// `flutter test` call fail the second app launch with "Unable to start the
// app on the device".
//
// Both ends run in this process over a real loopback TCP socket: the actual
// sender HTTP server, the actual QHTP receiver client, the actual transfer
// cache on this device's filesystem. Nothing is mocked, and on the phone the
// platform channels are the real ones rather than test doubles.
//
// What it is really checking is the wiring that was missing: a file arriving
// over Wi-Fi used to be written straight into Documents on iOS and Downloads
// elsewhere, so a photo never reached the gallery and a document was never
// asked about. The transfer itself was never the broken part.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const cache = TransferCache();
  final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  late Directory source;
  LocalHttpServer? server;
  final staged = <String>[];

  setUp(() async {
    source = await Directory.systemTemp.createTemp('dd_wifi_src_');
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    if (await source.exists()) await source.delete(recursive: true);
    await cache.discard(staged);
    staged.clear();
  });

  /// Runs one whole session and hands back where it landed.
  Future<Directory> transfer(List<String> paths, String id) async {
    final indexed = await FileIndexer().buildResult(
      sessionId: id,
      paths: paths,
    );

    server = LocalHttpServer();
    final token = 'token-$id';
    final port = await server!.startQhtpSession(
      manifest: indexed.manifest,
      itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
      authToken: token,
    );

    // The receiver's own staging area, exactly as the bloc now allocates it.
    final session = await cache.sessionDirectory();
    staged.add(session.path);

    final result = await QhtpReceiverClient().downloadSession(
      payload: QRPayload(
        version: 2,
        ip: '127.0.0.1',
        port: port,
        token: token,
        sessionId: indexed.manifest.sessionId,
        mode: 'http-lan',
      ),
      targetBaseDir: session.path,
    );
    result.fold((failure) => fail('transfer failed: ${failure.message}'), (_) {});
    return session;
  }

  File write(String name, int bytes) {
    final random = Random(name.hashCode);
    return File(p.join(source.path, name))
      ..writeAsBytesSync(
          Uint8List.fromList(List.generate(bytes, (_) => random.nextInt(256))));
  }

  testWidgets('several files arrive in the cache and are placed by kind',
      (tester) async {
    final photo = write('IMG_0100.HEIC', 64 * 1024);
    final video = write('clip.mov', 256 * 1024);
    final document = write('contract.pdf', 16 * 1024);

    final session = await transfer(
      [photo.path, video.path, document.path],
      'wifi-mixed',
    );

    // 1. It really is in the cache, not in Documents or Downloads.
    expect(p.isWithin((await cache.directory()).path, session.path), isTrue);
    expect(await cache.size(), greaterThanOrEqualTo(336 * 1024));

    // 2. Byte-for-byte, since a placement rule over a corrupted file would be
    //    a pointless thing to verify.
    final items = TransferCache.itemsIn(session);
    print('received on ${Platform.operatingSystem}: '
        '${items.map((i) => '${i.name} (${i.size}B)').join(', ')}');
    expect(items, hasLength(3));
    for (final original in [photo, video, document]) {
      final landed = File(p.join(session.path, p.basename(original.path)));
      expect(landed.existsSync(), isTrue, reason: '${original.path} is missing');
      expect(landed.readAsBytesSync(), equals(original.readAsBytesSync()));
    }

    // 3. And the rule reaches the verdict this platform calls for.
    final destination = SaveDestination.forCurrentPlatform();
    final verdicts = {
      for (final item in items) item.name: destination.intentFor(item),
    };

    if (isDesktop) {
      expect(verdicts.values, everyElement(equals(SaveIntent.automatic)),
          reason: 'desktop has a Downloads folder and no question to ask');
    } else {
      expect(verdicts['IMG_0100.HEIC'], equals(SaveIntent.gallery),
          reason: 'a photo over Wi-Fi belongs in the gallery like any other');
      expect(verdicts['clip.mov'], equals(SaveIntent.gallery));
      expect(verdicts['contract.pdf'], equals(SaveIntent.ask),
          reason: 'a document has no obvious home on a phone');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('a folder arrives as one item and never as gallery material',
      (tester) async {
    final folder = Directory(p.join(source.path, 'Trip'))..createSync();
    File(p.join(folder.path, 'a.jpg'))
        .writeAsBytesSync(Uint8List.fromList(List.filled(2048, 7)));
    Directory(p.join(folder.path, 'day 2')).createSync();
    File(p.join(folder.path, 'day 2', 'b.jpg'))
        .writeAsBytesSync(Uint8List.fromList(List.filled(1024, 9)));

    final session = await transfer([folder.path], 'wifi-folder');
    final items = TransferCache.itemsIn(session);

    expect(items, hasLength(1), reason: 'one decision, not one per photo');
    expect(items.single.name, equals('Trip'));
    expect(items.single.isDirectory, isTrue);
    expect(items.single.size, equals(3072), reason: 'the whole tree');
    expect(
      File(p.join(session.path, 'Trip', 'day 2', 'b.jpg')).existsSync(),
      isTrue,
      reason: 'the structure the sender chose survives the transfer',
    );

    final intent = SaveDestination.forCurrentPlatform().intentFor(items.single);
    expect(intent, equals(isDesktop ? SaveIntent.automatic : SaveIntent.ask),
        reason: 'no photo library takes a directory, whatever is inside it');
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('walking away gives the space back', (tester) async {
    final big = write('big.bin', 2 * 1024 * 1024);
    final session = await transfer([big.path], 'wifi-discard');

    final held = await cache.size();
    expect(held, greaterThanOrEqualTo(2 * 1024 * 1024));

    final items = TransferCache.itemsIn(session);
    await cache.discard([for (final i in items) i.cachePath]);

    expect(await cache.size(), lessThan(held));
    expect(session.existsSync(), isFalse,
        reason: 'the emptied staging folder goes too');
    staged.clear();
  }, timeout: const Timeout(Duration(minutes: 5)));
}

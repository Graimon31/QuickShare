// Two physical devices, one host and one receiver. Run once per direction.
// The host prints PAIR_FINGERPRINT; pass that exact value to the receiver as
// PAIR_FINGERPRINT. Both roles must use the same fresh PAIR_RUN identifier.
// Use flutter drive on a wireless iPhone; start host before receiver. Each
// run creates and removes only its own generated temporary files.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

import 'physical_test_config.dart';

final role =
    physicalString('PAIR_ROLE', const String.fromEnvironment('PAIR_ROLE'));
final run =
    physicalString('PAIR_RUN', const String.fromEnvironment('PAIR_RUN'));
final fingerprint = physicalString(
    'PAIR_FINGERPRINT', const String.fromEnvironment('PAIR_FINGERPRINT'));
final linkMode = physicalString('PAIR_LINK',
    const String.fromEnvironment('PAIR_LINK', defaultValue: 'peer'));
final hostIp = physicalString(
    'PAIR_HOST_IP', const String.fromEnvironment('PAIR_HOST_IP'));
final hostPort =
    physicalInt('PAIR_HOST_PORT', const int.fromEnvironment('PAIR_HOST_PORT'));
const size = 64 * 1024 * 1024;

Future<void> makePayload(Directory dir) async {
  final folder = Directory(p.join(dir.path, 'folder', 'nested'))
    ..createSync(recursive: true);
  File(p.join(folder.path, 'заметка 你好.txt'))
      .writeAsStringSync('physical peer folder check\n');
  File(p.join(folder.path, 'empty.bin')).writeAsBytesSync([]);
  File(p.join(dir.path, 'second.txt'))
      .writeAsStringSync('another top-level file\n');
  File(p.join(dir.path, 'folder', 'small.bin'))
      .writeAsBytesSync([0, 1, 2, 127, 128, 255]);
  final block = Uint8List(1024 * 1024);
  final random = Random(7391);
  for (var i = 0; i < block.length; i++) {
    block[i] = random.nextInt(256);
  }
  final sink = File(p.join(dir.path, 'large.bin')).openWrite();
  for (var i = 0; i < 64; i++) {
    sink.add(block);
  }
  await sink.close();
}

Future<String> digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('physical peer: file, folder, cancellation and resume',
      (tester) async {
    await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr, child: SizedBox.shrink()));
    expect(PeerLinkService.isSupported, isTrue);
    expect(['host', 'join'], contains(role));
    expect(['peer', 'lan'], contains(linkMode));
    expect(RegExp(r'^[A-Za-z0-9]{8,16}$').hasMatch(run), isTrue,
        reason:
            'PAIR_RUN must be a fresh 8–16 character alphanumeric identifier');
    final service = 'dd-$run';
    final token = 'physical-$run';
    final sessionId = 'physical-$run';
    const link = PeerLinkService();
    if (linkMode == 'peer') {
      addTearDown(link.stop);
      final events = link.events.listen((event) => print('PAIR_LINK $event'));
      addTearDown(events.cancel);
    }
    final workspace =
        await Directory.systemTemp.createTemp('dd_physical_pair_');
    addTearDown(() async {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    });
    final expected = Directory(p.join(workspace.path, 'expected'))
      ..createSync();
    await makePayload(expected);
    print('PAIR_PLATFORM ${Platform.operatingSystem} ROLE $role RUN $run');

    if (role == 'host') {
      final indexed = await FileIndexer().buildResult(
        sessionId: sessionId,
        paths: [
          p.join(expected.path, 'large.bin'),
          p.join(expected.path, 'second.txt'),
          p.join(expected.path, 'folder')
        ],
      );
      final server = LocalHttpServer();
      addTearDown(server.stop);
      final port = await server.startQhtpSession(
        manifest: indexed.manifest,
        itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
        authToken: token,
      );
      final pin = server.tlsFingerprint;
      expect(pin, isNotNull);
      expect(pin, isNotEmpty);
      final complete = Completer<void>();
      final progress = server.transferProgress.listen((value) {
        if (value >= 1 && !complete.isCompleted) complete.complete();
      });
      addTearDown(progress.cancel);
      if (linkMode == 'peer') {
        await link.host(serviceName: service, localPort: port);
      } else {
        final interfaces = await NetworkInterface.list(
            type: InternetAddressType.IPv4, includeLoopback: false);
        for (final interface in interfaces) {
          for (final address in interface.addresses) {
            print('PAIR_ADDRESS ${interface.name} ${address.address}');
          }
        }
        print('PAIR_HOST_PORT=$port');
      }
      print('PAIR_FINGERPRINT=$pin');
      print('PAIR_READY service=$service');
      await complete.future.timeout(const Duration(minutes: 10));
      print('PAIR_HOST_COMPLETE');
      return;
    }

    expect(fingerprint, isNotEmpty,
        reason: 'copy PAIR_FINGERPRINT from the host');
    var targetIp = hostIp;
    var targetPort = hostPort;
    if (linkMode == 'peer') {
      targetIp = '127.0.0.1';
      targetPort = await link.join(
          serviceName: service, timeout: const Duration(seconds: 90));
    } else {
      final address = InternetAddress.tryParse(hostIp);
      expect(address, isNotNull, reason: 'supply the host LAN IPv4 address');
      expect(address!.type, InternetAddressType.IPv4);
      expect(address.isLoopback, isFalse,
          reason: 'host must be the other physical device');
      expect(hostPort, inInclusiveRange(1, 65535));
    }
    final incoming = Directory(p.join(workspace.path, 'incoming'))
      ..createSync();
    final payload = QRPayload(
      version: 2,
      ip: targetIp,
      port: targetPort,
      token: token,
      sessionId: sessionId,
      mode: 'http-lan',
      tlsFingerprint: fingerprint,
    );
    final store = SessionStateStore(storeDirectory: workspace.path);
    final client = QhtpReceiverClient(store: store);
    var cancelled = false;
    final first = await client.downloadSession(
      payload: payload,
      targetBaseDir: incoming.path,
      onProgress: (progress) {
        if (!cancelled &&
            progress.phase == 'transferring' &&
            progress.itemPath == 'large.bin' &&
            progress.itemReceived >= 4 * 1024 * 1024 &&
            progress.itemReceived < size) {
          cancelled = true;
          print('PAIR_CANCEL at=${progress.itemReceived}');
          client.cancel();
        }
      },
    );
    first.fold(
        (failure) => print('PAIR_INITIAL_RESULT failure=${failure.message}'),
        (_) => print('PAIR_INITIAL_RESULT success'));
    expect(cancelled, isTrue, reason: 'must cancel during the large file');
    first.fold((failure) {
      expect(failure.message.toLowerCase(), contains('cancel'));
    }, (_) => fail('cancelled transfer unexpectedly completed'));
    final partial = File(p.join(incoming.path, 'large.bin.qs.partial'));
    expect(await partial.exists(), isTrue,
        reason: 'cancel must leave a resumable partial');
    final partialBytes = await partial.length();
    expect(partialBytes, greaterThan(0));
    expect(partialBytes, lessThan(size));
    print('PAIR_PARTIAL_BYTES=$partialBytes');
    final observedRanges = <String>[];
    final rangeResponses = <int?>[];
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final range = options.headers['Range'];
        if (range != null) observedRanges.add(range.toString());
        handler.next(options);
      },
      onResponse: (response, handler) {
        if (response.requestOptions.headers['Range'] != null) {
          rangeResponses.add(response.statusCode);
        }
        handler.next(response);
      },
    ));
    final resumed =
        await QhtpReceiverClient(dioClient: dio, store: store).downloadSession(
      payload: payload,
      targetBaseDir: incoming.path,
    );
    resumed.fold(
        (failure) => fail('resume failed: ${failure.message}'), (_) {});
    expect(observedRanges, contains('bytes=$partialBytes-'),
        reason: 'resume must request the saved offset');
    expect(rangeResponses, contains(206),
        reason: 'sender must serve the range');
    print('PAIR_RANGE bytes=$partialBytes- HTTP 206');
    for (final relative in [
      'large.bin',
      'second.txt',
      'folder/small.bin',
      'folder/nested/заметка 你好.txt',
      'folder/nested/empty.bin'
    ]) {
      final source = File(p.join(expected.path, relative));
      final received = File(p.join(incoming.path, relative));
      expect(await received.exists(), isTrue, reason: relative);
      final wanted = await digest(source);
      final actual = await digest(received);
      expect(actual, wanted, reason: '$relative SHA-256');
      print('PAIR_SHA256 $relative $actual');
    }
    expect(await partial.exists(), isFalse);
    print('PAIR_RECEIVER_COMPLETE');
  }, timeout: const Timeout(Duration(minutes: 15)));
}

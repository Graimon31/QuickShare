// Cleaning up what a failed download left must not reach through a link.
//
// A failed attempt removes its `.qs.partial`. The path it removes is a name
// under a folder, and if that folder was replaced by a link while the download
// ran, "the file of that name" is a file in whatever the link points at — which
// can be another transfer's partial, or anything else with a name a sender can
// choose. These put a stranger's file where a swapped folder leads, make the
// cleanup run, and look at whether it is still there.
//
// The links need a machine that can make them; one that cannot skips these and
// says why (test/support/links.dart).
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/features/receiver/data/client/http_file_downloader.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/repositories/receiver_repository_impl.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

import '../../support/links.dart';
import '../../support/scratch_path_provider.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

void main() {
  setUpAll(() => wakelockPlusPlatformInstance = _FakeWakelock());

  late Directory root;
  late Directory inside;
  late Directory outside;
  late PathProviderPlatform paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_discard_link_');
    inside = Directory(p.join(root.path, 'inside'))..createSync();
    outside = Directory(p.join(root.path, 'outside'))..createSync();
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = ScratchPathProvider(inside.path);
  });

  tearDown(() {
    PathProviderPlatform.instance = paths;
    root.deleteSync(recursive: true);
  });

  /// A folder in the destination turns into a link to [outside] — the way it
  /// would if somebody swapped it while a transfer was running.
  void swapFolderForLink(String folder) {
    Directory(folder).renameSync('$folder.moved');
    Link(folder).createSync(outside.path);
  }

  group('a failed single-file download', () {
    late LocalHttpServer server;
    late String fingerprint;
    late int port;

    setUp(() async {
      final source = File(p.join(root.path, 'offer.txt'))
        ..writeAsStringSync('the bytes the sender is offering');
      server = LocalHttpServer();
      port = await server.start(
          source.path, 'offer.txt', 'text/plain', source.lengthSync(), 'tok');
      fingerprint = server.tlsFingerprint!;
    });

    tearDown(() => server.stop());

    QRPayload offer(String fileName) => QRPayload(
          version: 1,
          ip: '127.0.0.1',
          port: port,
          token: 'tok',
          fileName: fileName,
          fileSize: 32,
          tlsFingerprint: fingerprint,
        );

    /// A downloader whose first request finds the folder swapped for a link and
    /// the server refusing: the download fails after its partial was made.
    ReceiverRepositoryImpl repositoryThatFindsFolderSwapped(String folder) {
      final downloader = HttpFileDownloader();
      downloader.dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          swapFolderForLink(folder);
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: options, statusCode: 403),
          ));
        },
      ));
      return ReceiverRepositoryImpl(
          downloader: downloader, decoder: QRPayloadDecoder());
    }

    test('does not delete a stranger\'s file of the same name through a folder '
        'that became a link', () async {
      final folder = p.join(inside.path, 'Trip');
      Directory(folder).createSync();
      final victim = File(p.join(outside.path, 'offer.txt.qs.partial'))
        ..writeAsStringSync('another transfer\'s unfinished file');
      // The probe is the same link the swap makes, so a machine that cannot
      // make one says so here, before anything has been set up.
      final probe = p.join(root.path, 'probe');
      if (!linkOrSkip(probe, outside.path)) return;
      Link(probe).deleteSync();

      final result = await repositoryThatFindsFolderSwapped(folder)
          .downloadFile(offer('Trip/offer.txt'));

      expect(result.isLeft, isTrue, reason: 'the server said no');
      expect(victim.existsSync(), isTrue,
          reason: 'the cleanup followed the link and removed a file that '
              'belongs to somebody else');
      expect(victim.readAsStringSync(), 'another transfer\'s unfinished file');
    });

    test('still removes its own partial when nothing is wrong', () async {
      final folder = p.join(inside.path, 'Trip');
      Directory(folder).createSync();
      final downloader = HttpFileDownloader();
      downloader.dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: options, statusCode: 403),
        )),
      ));
      final repository = ReceiverRepositoryImpl(
          downloader: downloader, decoder: QRPayloadDecoder());

      final result = await repository.downloadFile(offer('Trip/offer.txt'));

      expect(result.isLeft, isTrue);
      expect(Directory(folder).listSync(), isEmpty,
          reason: 'a failed download leaves nothing under either name');
    });
  });

  group('the sweep of expired sessions', () {
    late Directory dest;
    late Directory store;

    setUp(() {
      dest = Directory(p.join(root.path, 'dest'))..createSync();
      store = Directory(p.join(root.path, 'store'))..createSync();
    });

    Future<SessionStateStore> recorded(
        {required String relativePath, int partialBytes = 10}) async {
      final sessions = SessionStateStore(storeDirectory: store.path);
      await sessions.saveState(
        sessionId: 'old',
        host: '127.0.0.1',
        port: 1,
        token: 't',
        baseDir: dest.path,
        items: {
          'a': QhtpItemState(
              id: 'a',
              path: relativePath,
              size: 100,
              status: 'partial',
              partialBytes: partialBytes),
        },
      );
      return sessions;
    }

    test('removes the partial of an expired session, and counts its bytes',
        () async {
      Directory(p.join(dest.path, 'Trip')).createSync();
      final partial = File(p.join(dest.path, 'Trip', 'clip.bin.qs.partial'))
        ..writeAsBytesSync(List.filled(10, 1));
      final sessions = await recorded(relativePath: 'Trip/clip.bin');

      final freed = await sessions.cleanExpiredStates(ttl: Duration.zero);

      expect(partial.existsSync(), isFalse);
      expect(freed, 10);
    });

    test('does not delete a file outside the destination through a folder '
        'that became a link', () async {
      Directory(p.join(dest.path, 'Trip')).createSync();
      final victim = File(p.join(outside.path, 'clip.bin.qs.partial'))
        ..writeAsBytesSync(List.filled(64, 7));
      final sessions = await recorded(relativePath: 'Trip/clip.bin');
      if (!linkOrSkip(p.join(root.path, 'probe'), outside.path)) return;
      Link(p.join(root.path, 'probe')).deleteSync();
      swapFolderForLink(p.join(dest.path, 'Trip'));

      final freed = await sessions.cleanExpiredStates(ttl: Duration.zero);

      expect(victim.existsSync(), isTrue,
          reason: 'the sweep followed the link out of the destination');
      expect(freed, 0, reason: 'nothing of ours was removed');
    });

    test('a link standing where the partial goes is removed as a link; what '
        'it points at is neither deleted nor counted', () async {
      Directory(p.join(dest.path, 'Trip')).createSync();
      final target = File(p.join(outside.path, 'precious'))
        ..writeAsBytesSync(List.filled(500, 9));
      final sessions = await recorded(relativePath: 'Trip/clip.bin');
      final link = p.join(dest.path, 'Trip', 'clip.bin.qs.partial');
      if (!linkOrSkip(link, target.path)) return;

      final freed = await sessions.cleanExpiredStates(ttl: Duration.zero);

      expect(FileSystemEntity.typeSync(link, followLinks: false),
          FileSystemEntityType.notFound);
      expect(target.existsSync(), isTrue);
      expect(freed, lessThan(500),
          reason: 'the target\'s size is not ours to claim as freed');
    });

    test('leaves a completed item\'s file alone, as before', () async {
      Directory(p.join(dest.path, 'Trip')).createSync();
      final done = File(p.join(dest.path, 'Trip', 'clip.bin'))
        ..writeAsBytesSync(List.filled(10, 1));
      final sessions = SessionStateStore(storeDirectory: store.path);
      await sessions.saveState(
        sessionId: 'old',
        host: '127.0.0.1',
        port: 1,
        token: 't',
        baseDir: dest.path,
        items: {
          'a': const QhtpItemState(
              id: 'a', path: 'Trip/clip.bin', size: 10, status: 'completed'),
        },
      );

      await sessions.cleanExpiredStates(ttl: Duration.zero);

      expect(done.existsSync(), isTrue);
    });
  });
}

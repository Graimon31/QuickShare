// The single-file HTTP path (`HttpFileDownloader`, used by `downloadFile`)
// wrote with `dio.download(url, savePath)`: truncating whatever was at
// `savePath` — through a symlink if that is what was there — and leaving a
// half-written file under the final name if the connection broke.
//
// It now downloads into a guarded `.qs.partial` and only then gives the file
// its name, without replacing anything.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/features/receiver/data/client/http_file_downloader.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/repositories/receiver_repository_impl.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

void main() {
  setUpAll(() => wakelockPlusPlatformInstance = _FakeWakelock());

  late Directory root;
  late Directory source;
  late Directory dest;
  late Directory outside;
  late LocalHttpServer server;
  late String url;
  late String fingerprint;
  const token = 'legacy-token';
  const content = 'the bytes the sender is offering';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('dd_legacy_');
    source = Directory(p.join(root.path, 'src'))..createSync();
    dest = Directory(p.join(root.path, 'dest'))..createSync();
    outside = Directory(p.join(root.path, 'outside'))..createSync();
    final file = File(p.join(source.path, 'offer.txt'))
      ..writeAsStringSync(content);
    server = LocalHttpServer();
    final port = await server.start(
        file.path, 'offer.txt', 'text/plain', content.length, token);
    url = 'https://127.0.0.1:$port/download';
    fingerprint = server.tlsFingerprint!;
  });

  tearDown(() async {
    await server.stop();
    root.deleteSync(recursive: true);
  });

  Future<String> download(String savePath) => HttpFileDownloader().download(
        url: url,
        token: token,
        savePath: savePath,
        tlsFingerprint: fingerprint,
      );

  test('an ordinary download lands under its name, with no partial left',
      () async {
    final saved = await download(p.join(dest.path, 'offer.txt'));
    expect(saved, p.join(dest.path, 'offer.txt'));
    expect(File(saved).readAsStringSync(), content);
    expect(dest.listSync().map((e) => p.basename(e.path)), ['offer.txt']);
  });

  test('a file already there is kept; the download takes the next name',
      () async {
    File(p.join(dest.path, 'offer.txt')).writeAsStringSync('mine');
    final saved = await download(p.join(dest.path, 'offer.txt'));
    expect(saved, p.join(dest.path, 'offer (1).txt'));
    expect(File(p.join(dest.path, 'offer.txt')).readAsStringSync(), 'mine');
    expect(File(saved).readAsStringSync(), content);
  });

  test('a dangling link at the name is not written through', () async {
    final ghost = File(p.join(outside.path, 'ghost'));
    Link(p.join(dest.path, 'offer.txt')).createSync(ghost.path);
    final saved = await download(p.join(dest.path, 'offer.txt'));
    expect(ghost.existsSync(), isFalse);
    expect(saved, p.join(dest.path, 'offer (1).txt'));
    expect(File(saved).readAsStringSync(), content);
  });

  test('a link in the partial slot does not lead the bytes anywhere',
      () async {
    final victim = File(p.join(outside.path, 'victim'))
      ..writeAsStringSync('precious');
    Link(p.join(dest.path, 'offer.txt.qs.partial')).createSync(victim.path);
    final saved = await download(p.join(dest.path, 'offer.txt'));
    expect(victim.readAsStringSync(), 'precious');
    expect(File(saved).readAsStringSync(), content);
  });

  test('a failed download leaves nothing under the final name', () async {
    await server.stop();
    await expectLater(download(p.join(dest.path, 'offer.txt')), throwsA(anything));
    expect(File(p.join(dest.path, 'offer.txt')).existsSync(), isFalse);
  });

  test('the repository will not resolve a name through a link', () {
    Link(p.join(dest.path, 'Trip')).createSync(outside.path);
    final repository = ReceiverRepositoryImpl(
      downloader: HttpFileDownloader(),
      decoder: QRPayloadDecoder(),
    );
    expect(() => repository.sanitizePath('Trip/offer.txt', dest.path),
        throwsA(anything));
    expect(repository.sanitizePath('offer.txt', dest.path),
        p.join(dest.path, 'offer.txt'));
  });
}

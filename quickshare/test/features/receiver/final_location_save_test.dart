// `saveToFinalLocation` copies a received file into the transfer cache and
// gives the copy its name. The name is chosen before the copy starts and used
// when it ends, and the copy of a large file takes long enough for anything to
// happen in between — including another program making a file of that name.
//
// A plain rename would replace it without a word. The commit has to give way
// instead: the file that appeared stays what it was, and the copy is numbered.
// `SafePath.debugRace` is how a test does what that other program would, at
// the exact moment.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:quickshare/core/storage/safe_path.dart';
import 'package:quickshare/features/receiver/data/client/http_file_downloader.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/repositories/receiver_repository_impl.dart';

class _ScratchPaths extends PathProviderPlatform {
  _ScratchPaths(this.root);
  final Directory root;

  Future<String> _dir(String name) async =>
      (Directory(p.join(root.path, name))..createSync(recursive: true)).path;

  @override
  Future<String?> getApplicationCachePath() => _dir('cache');
  @override
  Future<String?> getTemporaryPath() => _dir('tmp');
}

void main() {
  late Directory root;
  late ReceiverRepositoryImpl repository;
  late PathProviderPlatform original;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dd_final_location_');
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _ScratchPaths(root);
    repository = ReceiverRepositoryImpl(
      downloader: HttpFileDownloader(),
      decoder: QRPayloadDecoder(),
    );
  });

  tearDown(() {
    SafePath.debugRace = null;
    PathProviderPlatform.instance = original;
    root.deleteSync(recursive: true);
  });

  File received(String content) =>
      File(p.join(root.path, 'incoming.bin'))..writeAsStringSync(content);

  Future<String> save(File temp, String name) async {
    final result = await repository.saveToFinalLocation(temp.path, name);
    late String path;
    result.fold(
      (failure) => fail('expected the save to work, got "${failure.message}"'),
      (saved) => path = saved,
    );
    return path;
  }

  test('a file saved into a free name gets that name', () async {
    final saved = await save(received('payload'), 'report.pdf');

    expect(p.basename(saved), 'report.pdf');
    expect(File(saved).readAsStringSync(), 'payload');
  });

  test('a name that was free when chosen and taken when the copy ended is '
      'not replaced', () async {
    String? taken;
    SafePath.debugRace = (stage, path) {
      if (stage != 'commit') return;
      taken = path;
      File(path).writeAsStringSync('arrived meanwhile');
    };

    final saved = await save(received('payload'), 'report.pdf');

    expect(taken, isNotNull, reason: 'the premise: the moment was reached');
    expect(File(taken!).readAsStringSync(), 'arrived meanwhile',
        reason: 'a file that was not ours was replaced');
    expect(p.basename(saved), 'report (1).pdf');
    expect(File(saved).readAsStringSync(), 'payload');
  });

  test('the temp file is only removed once the copy has its name', () async {
    final temp = received('payload');

    await save(temp, 'report.pdf');

    expect(temp.existsSync(), isFalse);
  });
}

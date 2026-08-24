// Is the transfer measurement limited by the link or by the build?
//
// `flutter test` only builds integration tests in debug, where Dart runs
// under the JIT with no optimisation. Before blaming the radio for a number,
// find out what this device can do with no radio in the way at all.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('what this device does with no network involved', (tester) async {
    final dir = Directory.systemTemp.createTempSync('dd_speed_');
    addTearDown(() => dir.deleteSync(recursive: true));

    const mb = 64;
    final block = Uint8List(1024 * 1024);
    for (var i = 0; i < block.length; i++) {
      block[i] = (i * 31 + 7) & 0xFF;
    }

    final file = File(p.join(dir.path, 'payload.bin'));
    var started = DateTime.now();
    final sink = file.openSync(mode: FileMode.write);
    for (var i = 0; i < mb; i++) {
      sink.writeFromSync(block);
    }
    sink.closeSync();
    var seconds = DateTime.now().difference(started).inMicroseconds / 1000000;
    print('write $mb MB: ${(mb / seconds).toStringAsFixed(1)} MB/s');

    started = DateTime.now();
    final digest = sha256.convert(file.readAsBytesSync());
    seconds = DateTime.now().difference(started).inMicroseconds / 1000000;
    print('sha256 $mb MB: ${(mb / seconds).toStringAsFixed(1)} MB/s '
        '(${digest.toString().substring(0, 8)})');
    print('^ QHTP checksums every item, so this is a ceiling on any transfer '
        'measured in this build.');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

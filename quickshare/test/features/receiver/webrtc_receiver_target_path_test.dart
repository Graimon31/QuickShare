import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';

void main() {
  group('WebRtcReceiverTransport.resolveTargetPath', () {
    late WebRtcReceiverTransport transport;
    late Directory base;

    setUp(() {
      transport = WebRtcReceiverTransport();
      base = Directory.systemTemp.createTempSync('qs_recv_');
    });

    tearDown(() => base.deleteSync(recursive: true));

    test('rejects an unset base directory', () {
      // Regression: the serverless receive path left _baseDir at '', and
      // p.isWithin('', 'photo.jpg') is true, so the traversal guard passed a
      // relative path through and the file landed in the process working
      // directory — unwritable inside the iOS sandbox.
      expect(() => transport.resolveTargetPath('photo.jpg', ''),
          throwsA(isA<Exception>()));
    });

    test('rejects a relative base directory', () {
      expect(() => transport.resolveTargetPath('photo.jpg', 'downloads'),
          throwsA(isA<Exception>()));
    });

    test('resolves inside an absolute base directory', () {
      final resolved = transport.resolveTargetPath('photo.jpg', base.path);
      expect(p.isAbsolute(resolved), isTrue);
      expect(p.isWithin(base.path, resolved), isTrue);
      expect(p.basename(resolved), equals('photo.jpg'));
    });

    test('strips directory components out of the announced name', () {
      final resolved =
          transport.resolveTargetPath('../../etc/passwd', base.path);
      expect(p.isWithin(base.path, resolved), isTrue);
      expect(p.basename(resolved), equals('passwd'));
    });

    test('falls back to a placeholder for unusable names', () {
      expect(p.basename(transport.resolveTargetPath('...', base.path)),
          equals('received_file'));
      expect(p.basename(transport.resolveTargetPath('   ', base.path)),
          equals('received_file'));
    });
  });
}

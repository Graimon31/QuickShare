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

  group('folders', () {
    late WebRtcReceiverTransport transport;
    late Directory base;

    setUp(() {
      transport = WebRtcReceiverTransport();
      base = Directory.systemTemp.createTempSync('qs_recv_dir_');
    });

    tearDown(() => base.deleteSync(recursive: true));

    test('rebuilds the folders an item came from', () {
      // The whole point of the manifest carrying a path: a folder arrives as
      // a folder rather than as a heap of files or a .zip to unpack.
      final resolved =
          transport.resolveTargetPath('Trip/Day 1/IMG_0042.HEIC', base.path);

      expect(p.isWithin(base.path, resolved), isTrue);
      expect(p.relative(resolved, from: base.path),
          equals(p.join('Trip', 'Day 1', 'IMG_0042.HEIC')));
    });

    test('a climb out of the destination is dropped, not resolved', () {
      // Every segment came off the wire. `..` is removed rather than applied,
      // so no arrangement of them walks back up out of the destination.
      final resolved = transport.resolveTargetPath(
          'Trip/../../../etc/passwd', base.path);

      expect(p.isWithin(base.path, resolved), isTrue);
      expect(p.relative(resolved, from: base.path),
          equals(p.join('Trip', 'etc', 'passwd')));
    });

    test('an absolute path loses its root', () {
      final resolved =
          transport.resolveTargetPath('/etc/passwd', base.path);

      expect(p.isWithin(base.path, resolved), isTrue);
      expect(p.relative(resolved, from: base.path),
          equals(p.join('etc', 'passwd')));
    });

    test('a separator smuggled inside a segment cannot add a level', () {
      // Backslashes are treated as separators and then each segment is
      // cleaned, so neither spelling of a separator survives inside a name.
      final resolved =
          transport.resolveTargetPath(r'Trip\..\..\escape.txt', base.path);

      expect(p.isWithin(base.path, resolved), isTrue);
      expect(p.basename(resolved), equals('escape.txt'));
    });

    test('every segment is cleaned the way a flat name is', () {
      final resolved = transport
          .resolveTargetPath('Tr:ip/Day*1/IMG?0042.HEIC', base.path);

      expect(p.relative(resolved, from: base.path),
          equals(p.join('Tr_ip', 'Day_1', 'IMG_0042.HEIC')));
    });

    test('a path of nothing usable still lands somewhere', () {
      expect(p.basename(transport.resolveTargetPath('../../..', base.path)),
          equals('received_file'));
    });
  });
}

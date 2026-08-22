// The limits the protocol spec declares, checked against what the code does.
//
// Three of them used to exist only in HEAVY_TRANSFER_PROTOCOL.md: the
// per-segment name cap was absent entirely, the manifest ceiling was a
// constant nobody read, and the per-file cap was enforced on the sending side
// only. A spec that documents behaviour the code does not have is worse than
// no spec, so these pin the code to it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';

void main() {
  final client = QhtpReceiverClient();
  const limit = AppConstants.qhtpMaxNameBytes;

  group('MAX_NAME_BYTES', () {
    test('an ordinary name is untouched', () {
      expect(client.sanitizeSegment('holiday photo.jpg'),
          equals('holiday photo.jpg'));
    });

    test('an over-long name is shortened to something the filesystem takes',
        () {
      final long = '${'a' * 400}.jpg';
      final result = client.sanitizeSegment(long);

      expect(utf8.encode(result).length, lessThanOrEqualTo(limit));
      expect(result, endsWith('.jpg'),
          reason: 'the extension decides whether the file opens afterwards');
    });

    test('counts bytes, not characters', () {
      // 200 Cyrillic characters are 400 UTF-8 bytes. Measuring in characters
      // would let this through and then fail at create() with ENAMETOOLONG.
      final cyrillic = '${'я' * 200}.txt';
      expect(cyrillic.length, lessThan(limit),
          reason: 'the precondition: it is short in characters');

      final result = client.sanitizeSegment(cyrillic);
      expect(utf8.encode(result).length, lessThanOrEqualTo(limit));
      expect(result, endsWith('.txt'));
    });

    test('never cuts a character in half', () {
      final result = client.sanitizeSegment('${'ё' * 300}.dat');
      // A byte-wise cut through a two-byte sequence would leave a replacement
      // character behind.
      expect(result.contains('�'), isFalse);
      expect(utf8.decode(utf8.encode(result)), equals(result));
    });

    test('a name that is one long "extension" keeps its budget for the stem',
        () {
      // ".<400 chars>" is not an extension, and treating it as one would leave
      // no room for anything else.
      final result = client.sanitizeSegment('report.${'x' * 400}');
      expect(utf8.encode(result).length, lessThanOrEqualTo(limit));
      expect(result, isNotEmpty);
    });

    test('an over-long name still produces a usable path', () {
      final base = Directory.systemTemp.createTempSync('dd_names_');
      addTearDown(() => base.deleteSync(recursive: true));

      final resolved =
          client.materializePath('${'z' * 400}.bin', base.path);
      // The real check: the filesystem accepts it.
      File(resolved).writeAsStringSync('ok');
      expect(File(resolved).existsSync(), isTrue);
      expect(p.isWithin(base.path, resolved), isTrue);
    });

    test('shortening does not defeat the traversal guard', () {
      final base = Directory.systemTemp.createTempSync('dd_names2_');
      addTearDown(() => base.deleteSync(recursive: true));

      final resolved =
          client.materializePath('../../${'y' * 400}.bin', base.path);
      expect(p.isWithin(base.path, resolved), isTrue);
    });
  });

  group('declared limits match the spec', () {
    test('the numbers are the ones HEAVY_TRANSFER_PROTOCOL.md states', () {
      expect(AppConstants.qhtpMaxFileBytes, equals(100 * 1024 * 1024 * 1024));
      expect(
          AppConstants.qhtpMaxSessionBytes, equals(500 * 1024 * 1024 * 1024));
      expect(AppConstants.qhtpMaxFileCount, equals(100000));
      expect(AppConstants.qhtpMaxPathDepth, equals(32));
      expect(AppConstants.qhtpMaxRelPathChars, equals(512));
      expect(AppConstants.qhtpMaxNameBytes, equals(255));
      expect(AppConstants.qhtpManifestMaxBytes, equals(32 * 1024 * 1024));
      expect(AppConstants.qhtpSessionTimeoutSeconds, equals(30 * 60));
    });
  });
}

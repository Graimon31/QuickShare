// The parts of the remote peer check that are plain functions: which receiver
// is accepted, what a receiver is refused to start without, the file the
// sender makes, the numbers it reports. The check itself needs two machines
// and the public internet and is run by hand (integration_test/CI_PEER.md).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/constants/app_constants.dart';

import '../../integration_test/ci_peer_support.dart';

void main() {
  group('which receiver is accepted', () {
    test('the one that was named, and no other', () {
      expect(ciPeerNameMatches('ci-peer-1a2b3c', 'ci-peer-1a2b3c'), isTrue);
      expect(ciPeerNameMatches('ci-peer-1a2b3c', 'ci-peer-1a2b3d'), isFalse);
      expect(ciPeerNameMatches('ci-peer-1a2b3c', 'Receiving Mac'), isFalse);
      expect(ciPeerNameMatches('ci-peer-1a2b3c', 'ci-peer-1a2b3c2'), isFalse);
    });

    test('case counts: a different spelling is a different device', () {
      expect(ciPeerNameMatches('ci-peer-abc', 'CI-PEER-ABC'), isFalse);
    });

    test('names are compared the way the sender shows them, cleaned', () {
      // The sender is handed the name after cleaning, whatever was typed.
      expect(ciPeerNameMatches('ci-peer  one', 'ci-peer one'), isTrue);
      expect(ciPeerNameMatches('ci-peer one', 'ci-peer\u202E one'), isTrue);
    });

    test('no name accepts no receiver, not even a nameless one', () {
      expect(ciPeerNameMatches('', ''), isFalse);
      expect(ciPeerNameMatches('   ', ''), isFalse);
      expect(ciPeerNameMatches('', 'anyone'), isFalse);
    });
  });

  group('the receiver does not start without what it needs', () {
    const good = (
      code: '0123456789',
      name: 'ci-peer-1a2b3c',
      bytes: 52428800,
      sha: '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
    );

    List<String> problems({
      String? code,
      String? name,
      int? bytes,
      String? sha,
    }) =>
        ciPeerReceiverProblems(
          code: code ?? good.code,
          name: name ?? good.name,
          bytes: bytes ?? good.bytes,
          sha256Hex: sha ?? good.sha,
        );

    test('complete settings have no problem', () {
      expect(problems(), isEmpty);
    });

    test('each missing or malformed one is named', () {
      expect(problems(code: ''), [contains('CI_PEER_CODE')]);
      expect(problems(code: '12345'), [contains('CI_PEER_CODE')]);
      expect(problems(code: 'abcdefghij'), [contains('CI_PEER_CODE')]);
      expect(problems(name: ' '), [contains('CI_PEER_NAME')]);
      expect(problems(bytes: -1), [contains('CI_PEER_BYTES')]);
      expect(problems(bytes: 0), [contains('CI_PEER_BYTES')]);
      expect(problems(sha: ''), [contains('CI_PEER_SHA256')]);
      expect(problems(sha: 'abc'), [contains('CI_PEER_SHA256')]);
    });

    test('all of them at once', () {
      expect(ciPeerReceiverProblems(code: '', name: '', bytes: -1, sha256Hex: ''),
          hasLength(4));
    });

    test('a code typed with its space is still a code', () {
      expect(problems(code: '01234 56789'), isEmpty);
    });
  });

  group('the file the sender makes', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('dd_ci_peer_unit_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('has exactly the size asked for, and the hash it reports', () async {
      // Not a multiple of the block, nor of the word the bytes are made in.
      const size = 2 * 1024 * 1024 + 1027;
      final file = File(p.join(dir.path, 'a.bin'));
      final reported = await ciPeerWriteRandomFile(file, size);

      expect(file.lengthSync(), size);
      expect(reported, sha256.convert(file.readAsBytesSync()).toString());
      expect(await ciPeerHashFile(file), reported);
      expect(reported, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('is random: two files differ, and nothing repeats inside one',
        () async {
      final a = File(p.join(dir.path, 'a.bin'));
      final b = File(p.join(dir.path, 'b.bin'));
      final hashA = await ciPeerWriteRandomFile(a, 256 * 1024);
      final hashB = await ciPeerWriteRandomFile(b, 256 * 1024);
      expect(hashA, isNot(hashB));

      // A file that compresses would measure the compressor, not the path.
      final bytes = a.readAsBytesSync();
      final compressed = zlib.encode(bytes);
      expect(compressed.length, greaterThan(bytes.length * 0.99));
    });

    test('a seeded source makes the same file twice', () async {
      final a = File(p.join(dir.path, 'a.bin'));
      final b = File(p.join(dir.path, 'b.bin'));
      expect(
        await ciPeerWriteRandomFile(a, 100001, random: Random(7)),
        await ciPeerWriteRandomFile(b, 100001, random: Random(7)),
      );
    });

    test('an empty file has the hash of nothing', () async {
      final file = File(p.join(dir.path, 'empty.bin'));
      expect(await ciPeerWriteRandomFile(file, 0), sha256.convert([]).toString());
      expect(file.lengthSync(), 0);
    });
  });

  group('what is reported', () {
    test('speed, in both units', () {
      final s = ciPeerSpeed(50 * 1024 * 1024, const Duration(seconds: 10));
      expect(s.mibPerSecond, closeTo(5, 1e-9));
      expect(s.mbitPerSecond, closeTo(41.943, 1e-3));
    });

    test('a transfer that took no time has no speed, not an infinite one', () {
      final s = ciPeerSpeed(1000, Duration.zero);
      expect(s.mibPerSecond, 0);
      expect(s.mbitPerSecond, 0);
    });

    test('whatever the other end called a file is made plain', () {
      expect(ciPeerPlainText('ci-peer-payload.zip'), 'ci-peer-payload.zip');
      expect(ciPeerPlainText('a`b|c\nd<e>'), 'a?b?c?d?e?');
      expect(ciPeerPlainText('x' * 200), hasLength(80));
    });

    test('a report is JSON, lines and a table, and says how it ended', () {
      final report = CiPeerReport('receiver')
        ..status = 'failure'
        ..error = 'SHA-256 differs | really'
        ..fields['ice_path'] = 'relayed'
        ..fields['ice_pair'] = 'local=relay remote=srflx'
        ..fields['skipped'] = null;

      expect(jsonDecode(jsonEncode(report.toJson())), {
        'role': 'receiver',
        'status': 'failure',
        'error': 'SHA-256 differs | really',
        'ice_path': 'relayed',
        'ice_pair': 'local=relay remote=srflx',
        'skipped': null,
      });
      expect(report.lines(), contains('ice_pair: local=relay remote=srflx'));
      expect(report.lines().any((l) => l.startsWith('skipped')), isFalse);
      expect(report.succeeded, isFalse);

      final md = report.markdown();
      expect(md, contains('FAILED'));
      expect(md, contains('| ice_path | relayed |'));
      // A pipe in a value must not open a new column.
      expect(md, contains(r'SHA-256 differs \| really'));
    });

    test('a report that succeeded says so', () {
      final report = CiPeerReport('sender')..status = 'success';
      expect(report.succeeded, isTrue);
      expect(report.markdown(title: 'Sent'), contains('### Sent: OK'));
    });
  });

  group('the step summary', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('dd_ci_peer_unit_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('is appended to, not replaced', () async {
      final summary = File(p.join(dir.path, 'summary.md'))
        ..writeAsStringSync('earlier step\n');
      final env = {'GITHUB_STEP_SUMMARY': summary.path};

      expect(await ciPeerAppendStepSummary('one', environment: env), isTrue);
      expect(await ciPeerAppendStepSummary('two', environment: env), isTrue);
      expect(summary.readAsStringSync(), 'earlier step\none\ntwo\n');
    });

    test('is not written when there is none, and says so', () async {
      expect(await ciPeerAppendStepSummary('x', environment: {}), isFalse);
      expect(
          await ciPeerAppendStepSummary('x',
              environment: {'GITHUB_STEP_SUMMARY': ''}),
          isFalse);
    });

    test('one that cannot be written is a "no", not a crash', () async {
      final env = {'GITHUB_STEP_SUMMARY': p.join(dir.path, 'missing', 's.md')};
      expect(await ciPeerAppendStepSummary('x', environment: env), isFalse);
    });
  });

  group('the settings', () {
    test('the offer is rebuilt as often as the app rebuilds its own', () {
      // The one difference from the app is that the code stays; the offer's
      // age must not.
      expect(CiPeerDefines.offerRefreshSeconds,
          AppConstants.sessionCodeLifetime.inSeconds);
    });

    test('the sender waits forty minutes and sends 50 MiB, unless told', () {
      expect(CiPeerDefines.waitFor, const Duration(minutes: 40));
      expect(CiPeerDefines.defaultBytes, 50 * 1024 * 1024);
    });

    test('a receiver given nothing is told what is missing', () {
      expect(
        ciPeerReceiverProblems(
          code: CiPeerDefines.code,
          name: CiPeerDefines.name,
          bytes: CiPeerDefines.bytes,
          sha256Hex: CiPeerDefines.sha256Hex,
        ),
        isNotEmpty,
        reason: 'the test run itself is given no CI_PEER_* defines',
      );
    });
  });
}

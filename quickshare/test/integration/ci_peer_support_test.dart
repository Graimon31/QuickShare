// The parts of the remote peer check that are plain functions: which receiver
// is accepted, what a receiver is refused to start without, the file the
// sender makes, the numbers it reports. The check itself needs two machines
// and the public internet and is run by hand (integration_test/CI_PEER.md).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

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

    test('a seed stands in for the SHA-256, and for nothing else', () {
      List<String> withSeed({String sha = '', String seed = ''}) =>
          ciPeerReceiverProblems(
            code: good.code,
            name: good.name,
            bytes: good.bytes,
            sha256Hex: sha,
            seedHex: seed,
          );
      expect(withSeed(seed: good.sha), isEmpty);
      expect(withSeed(seed: good.sha.toUpperCase()), isEmpty);
      expect(withSeed(seed: 'abc'), [contains('CI_PEER_SEED')]);
      // Two descriptions of the file that could disagree.
      expect(withSeed(sha: good.sha, seed: good.sha), [contains('not both')]);
      // Neither: the missing hash is what is named.
      expect(withSeed(), [contains('CI_PEER_SHA256')]);
    });
  });

  group('a sender that is given its code and its file', () {
    const seed = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
    List<String> problems({
      String code = '0123456789',
      String name = 'ci-peer-1a2b3c',
      int bytes = 1000,
      String seedHex = seed,
    }) =>
        ciPeerGivenSenderProblems(
          code: code,
          expectName: name,
          bytes: bytes,
          seedHex: seedHex,
        );

    test('complete settings have no problem', () {
      expect(problems(), isEmpty);
    });

    test('each missing one is named, and a missing size is not defaulted', () {
      expect(problems(code: ''), [contains('CI_PEER_CODE')]);
      expect(problems(code: '123'), [contains('CI_PEER_CODE')]);
      expect(problems(name: ' '), [contains('CI_PEER_EXPECT_NAME')]);
      // The receiver expects the size peer.json says: a default here would be a
      // second opinion about it.
      expect(problems(bytes: -1), [contains('CI_PEER_BYTES')]);
      expect(problems(seedHex: ''), [contains('CI_PEER_SEED')]);
      expect(problems(seedHex: 'xyz'), [contains('CI_PEER_SEED')]);
    });

    test('given nothing at all, all four are named', () {
      expect(
        ciPeerGivenSenderProblems(
            code: CiPeerDefines.code,
            expectName: CiPeerDefines.expectName,
            bytes: CiPeerDefines.bytes,
            seedHex: CiPeerDefines.seed),
        hasLength(4),
      );
    });
  });

  group('how long a search goes on', () {
    const pause = Duration(seconds: 10);

    test('by count, when there is no time to search for', () {
      bool again(int attempt, {Duration elapsed = Duration.zero}) =>
          ciPeerMaySearchAgain(
              attempt: attempt,
              elapsed: elapsed,
              findAttempts: 5,
              pause: pause);
      expect(again(1), isTrue);
      expect(again(4), isTrue);
      expect(again(5), isFalse);
      // Time means nothing when counting.
      expect(again(1, elapsed: const Duration(hours: 3)), isTrue);
    });

    test('by time, when there is: the attempt count means nothing', () {
      bool again(int attempt, Duration elapsed) => ciPeerMaySearchAgain(
            attempt: attempt,
            elapsed: elapsed,
            findAttempts: 5,
            pause: pause,
            findFor: const Duration(minutes: 40),
          );
      expect(again(1, const Duration(seconds: 25)), isTrue);
      expect(again(500, const Duration(minutes: 20)), isTrue);
      expect(again(2, const Duration(minutes: 39, seconds: 49)), isTrue,
          reason: 'the next search can still start before the forty minutes');
      expect(again(2, const Duration(minutes: 39, seconds: 50)), isFalse,
          reason: 'after the pause there would be no time left to search');
      expect(again(2, const Duration(minutes: 41)), isFalse);
    });
  });

  group('a receiver that searches until a sender is up', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('dd_ci_peer_unit_'));
    tearDown(() => dir.deleteSync(recursive: true));

    final code = SessionCode.parse('0123456789')!;
    const sha = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

    /// Receives with a search that answers from [outcomes], one per search, and
    /// says what each was asked.
    Future<(CiPeerReport, List<String>)> receive(
      List<Object> outcomes, {
      Duration? findFor,
      int findAttempts = 5,
    }) async {
      final asked = <String>[];
      var i = 0;
      final report = await ciPeerReceive(
        code: code,
        name: 'mac-1a2b3c',
        expectedBytes: 100,
        expectedSha256: sha,
        destination: dir,
        findAttempts: findAttempts,
        findFor: findFor,
        findPause: const Duration(milliseconds: 5),
        lookup: (c, name, control) async {
          asked.add('${c.code} as $name');
          final next = outcomes[min(i++, outcomes.length - 1)];
          if (next is! CodeSessionOutcome) throw next;
          return next;
        },
        log: (_) {},
      );
      return (report, asked);
    }

    test('goes on after a search that found nothing, until one does', () async {
      final (report, asked) = await receive([
        const CodeSessionNotFound(),
        const CodeSessionNotFound(),
        const CodeSessionFoundOnline('not an offer'),
      ], findFor: const Duration(seconds: 30));

      // It got as far as reading the offer, which here is not one: the point
      // is that three searches were made and the third was believed.
      expect(asked, hasLength(3));
      expect(asked.toSet(), {'0123456789 as mac-1a2b3c'});
      expect(report.fields['find_attempts'], 3);
      expect(report.fields['find_seconds'], isNotNull);
      expect(report.error, isNot(contains('no sender answered')));
    });

    test('a search that broke, and no network at all, are the same as nothing',
        () async {
      // The VPN dropping the relays for a minute must not end the check.
      final (report, asked) = await receive([
        Exception('relay unreachable'),
        const CodeSessionNoNetwork(),
        const CodeSessionUnreachable(),
        const CodeSessionFoundOnline('not an offer'),
      ], findFor: const Duration(seconds: 30));
      expect(asked, hasLength(4));
      expect(report.fields['find_seconds'], isNotNull);
      expect(report.error, isNot(contains('no sender answered')));
    });

    test('gives up when the time is up, and says what the last search was',
        () async {
      final (report, asked) = await receive(
        [const CodeSessionNoNetwork()],
        findFor: const Duration(milliseconds: 200),
      );
      expect(report.status, 'failure');
      expect(asked.length, greaterThan(3),
          reason: 'more searches than the five a count would allow here');
      expect(report.error, contains('no sender answered the code'));
      expect(report.error, contains('CodeSessionNoNetwork'));
      expect(report.fields['find_attempts'], asked.length);
    });

    test('a search that keeps breaking ends with what broke', () async {
      final (report, _) = await receive(
        [StateError('x')],
        findFor: const Duration(milliseconds: 100),
      );
      expect(report.status, 'failure');
      expect(report.error, contains('a search that broke (StateError)'));
    });

    test('without a time to search for, it is by count, as before', () async {
      final (report, asked) = await receive(
        [const CodeSessionNotFound()],
        findAttempts: 3,
      );
      expect(asked, hasLength(3));
      expect(report.error, contains('no sender answered the code in 3 searches'));
    });

    test('a sender that declines ends it at once, whatever time is left',
        () async {
      final (report, asked) = await receive(
        [const CodeSessionNotFound(), const CodeSessionDeclined()],
        findFor: const Duration(minutes: 40),
      );
      expect(asked, hasLength(2));
      expect(report.status, 'failure');
      expect(report.error, contains('declined this device'));
    });

    test('so does one on another version, and one found on the local network',
        () async {
      final (version, a) = await receive(
          [const CodeSessionUpdateRequired()],
          findFor: const Duration(minutes: 40));
      expect(a, hasLength(1));
      expect(version.error, contains('another version'));

      final (lan, b) = await receive([
        const CodeSessionFound(QRPayload(
          version: 1,
          ip: '192.0.2.1',
          port: 1,
          token: 't',
          sessionId: 's',
          mode: 'http-lan',
        )),
      ], findFor: const Duration(minutes: 40));
      expect(b, hasLength(1));
      expect(lan.error, contains('local network'));
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

    test('a file made from a seed is the same on every machine', () async {
      const seed =
          '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
      // Not a multiple of the block, nor of the 32 bytes a hash gives.
      const size = 3 * 1024 * 1024 + 77;
      final a = File(p.join(dir.path, 'a.bin'));
      final b = File(p.join(dir.path, 'b.bin'));
      final written = await ciPeerWriteSeededFile(a, size, seed);
      final again = await ciPeerWriteSeededFile(b, size, seed.toUpperCase());

      expect(a.lengthSync(), size);
      expect(written, again, reason: 'upper-case hex is the same seed');
      expect(a.readAsBytesSync(), b.readAsBytesSync());
      expect(written, sha256.convert(a.readAsBytesSync()).toString());
      // What the receiving side works out without ever writing the file.
      expect(await ciPeerSeededSha256(size, seed), written);
    });

    test('the seeded file is what its definition says, block by block', () {
      // The definition, written out here from the doc comment and nothing
      // else, so that a change to the generator cannot pass by agreeing with
      // itself: the machine that picks the seed and the one that sends must
      // never come apart.
      const seed =
          'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
      List<int> block(int i) {
        final counter = ByteData(8)..setUint64(0, i);
        return sha256.convert([
          ...utf8.encode('directdrop-ci-peer-file-v1'),
          ...List.generate(32, (k) => int.parse(seed.substring(k * 2, k * 2 + 2), radix: 16)),
          ...counter.buffer.asUint8List(),
        ]).bytes;
      }

      final made = [for (final b in ciPeerSeededBlocks(seed, 100, blockSize: 64)) ...b];
      expect(made, hasLength(100));
      expect(made, [...block(0), ...block(1), ...block(2), ...block(3)].sublist(0, 100));
      // The block size is only how it is cut up.
      final whole = [for (final b in ciPeerSeededBlocks(seed, 100)) ...b];
      expect(whole, made);
    });

    test('and matches what Python makes of the definition (a known answer)',
        () async {
      // Worked out outside Dart: hashlib.sha256(b'directdrop-ci-peer-file-v1'
      // + seed + struct.pack('>Q', i)) for i = 0, 1, ..., cut at the size.
      const seed =
          'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
      expect(await ciPeerSeededSha256(1000, seed),
          '587394676547d60b3c4c14d81028771dec64e1623461d077cff1fd7a79334bcf');
      expect(await ciPeerSeededSha256(3 * 1024 * 1024 + 77, seed),
          '9297509db7da65c04be1b220713d665d0bfd2aa8ef9908b17ecab451e6d69309');
    });

    test('different seeds, and different sizes of one seed, differ in kind', () async {
      final one = '00' * 32;
      final two = '01${'00' * 31}';
      final a = [for (final b in ciPeerSeededBlocks(one, 4096)) ...b];
      final b = [for (final b in ciPeerSeededBlocks(two, 4096)) ...b];
      expect(a, isNot(b));
      // The shorter file is the beginning of the longer one: size is a cut.
      final shorter = [for (final b in ciPeerSeededBlocks(one, 1000)) ...b];
      expect(a.sublist(0, 1000), shorter);
      // And it does not compress, or it would measure the compressor.
      expect(zlib.encode(a).length, greaterThan(a.length * 0.99));
    });

    test('a seed that is not 64 hex digits makes nothing', () {
      expect(() => ciPeerSeededBlocks('abc', 10).toList(), throwsArgumentError);
      expect(() => ciPeerSeededBlocks('zz' * 32, 10).toList(), throwsArgumentError);
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

    test('the receiver searches by count, unless it is told or has a seed', () {
      // The test run is given no CI_PEER_* defines: no time, no seed.
      expect(CiPeerDefines.findFor, isNull);
      expect(CiPeerDefines.defaultSeededFindMinutes, 40);
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

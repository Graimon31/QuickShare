// What `.github/workflows/ci_peer.yml` must stay: a workflow that runs on one
// kind of push and on nothing else, holds no secret, and takes or gives the
// file (as `direction` in `ci-peer/peer.json` says) only after checking what
// the file contains.
//
// The peer on the other end is a real device on the public internet; nothing
// here runs it. This keeps the workflow from drifting into something that would
// start on a pull request, or hand an unchecked value to a shell, and it RUNS
// the workflow's own checking script against a set of `peer.json` files, good
// and hostile, to see what it lets through.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

typedef Json = Map<String, Object?>;

Object? plain(Object? node) => jsonDecode(jsonEncode(node));

void main() {
  File repoFile(String relative) {
    // Tests run from `quickshare/`; the workflows live at the repo root above.
    for (final base in ['.', '..']) {
      final f = File('$base/$relative');
      if (f.existsSync()) return f;
    }
    fail('could not find $relative from ${Directory.current.path}');
  }

  final text = repoFile('.github/workflows/ci_peer.yml')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final workflow = plain(loadYaml(text)) as Json;
  final job = (workflow['jobs'] as Json)['remote_peer'] as Json;
  final steps = [for (final s in job['steps'] as List) s as Json];

  String nameOf(Json step) => '${step['name'] ?? step['uses'] ?? step['run']}';
  int indexOf(String name) =>
      steps.indexWhere((s) => nameOf(s).startsWith(name));
  String runOf(String name) => '${steps[indexOf(name)]['run']}';

  group('when it runs', () {
    test('on a push to ci-peer/** and on nothing else', () {
      final on = workflow['on'];
      expect(on, isA<Map>(), reason: 'a list or a string of events would '
          'allow more than the one');
      expect((on as Map).keys, ['push']);
      expect((on['push'] as Map).keys, ['branches'],
          reason: 'no tags, no path filters that widen it');
      expect((on['push'] as Map)['branches'], ['ci-peer/**']);
    });

    test('not by hand, by schedule or by pull request, under any heading', () {
      final events = RegExp(
          r'^\s*(workflow_dispatch|schedule|pull_request|pull_request_target|'
          r'workflow_run|repository_dispatch|release|issue_comment)\s*:',
          multiLine: true);
      expect(events.allMatches(text).map((m) => m.group(1)), isEmpty);
    });

    test('a single job, long enough for a build and forty minutes of waiting',
        () {
      expect((workflow['jobs'] as Json).keys, ['remote_peer']);
      // Build (ten to fifteen minutes), then the sender waits up to forty for
      // the Mac: less than that would cut a run that is still on time.
      expect(job['timeout-minutes'], 75);
      expect(job['runs-on'], 'macos-latest');
    });
  });

  group('what it may do', () {
    test('reads the repository and nothing else', () {
      expect(workflow['permissions'], {'contents': 'read'});
      expect(job.containsKey('permissions'), isFalse,
          reason: 'a job-level block could widen the workflow-level one');
    });

    test('uses no secret, and keeps no token in the checkout', () {
      expect(text.contains('secrets.'), isFalse);
      expect(text.contains('GITHUB_TOKEN'), isFalse);
      final checkout = steps.firstWhere(
          (s) => '${s['uses']}'.startsWith('actions/checkout@'));
      expect((checkout['with'] as Json)['persist-credentials'], isFalse);
    });

    test('is not told to pass the TURN secret that the app no longer has', () {
      for (final needle in ['QUICKSHARE_TURN_SECRET', 'turnClientSecret', 'X-DD-']) {
        expect(text.contains(needle), isFalse, reason: needle);
      }
    });
  });

  group('what it does, in order', () {
    test('sets Flutter up as the other macOS integration job does', () {
      final setup = steps.firstWhere(
          (s) => '${s['uses']}'.startsWith('subosito/flutter-action@'));
      expect(setup['with'], {
        'flutter-version': '3.44.x',
        'channel': 'stable',
        'cache': true,
      });
      final reference = plain(loadYaml(repoFile(
              '.github/workflows/integration.yml')
          .readAsStringSync())) as Json;
      final other = ((reference['jobs'] as Json)['serverless_webrtc'] as Json);
      final otherSetup = (other['steps'] as List).cast<Json>().firstWhere(
          (s) => '${s['uses']}'.startsWith('subosito/flutter-action@'));
      expect(setup['with'], otherSetup['with'],
          reason: 'the same Flutter as the "Serverless handshake on macOS" job');
      expect(runOf('Enable the macOS desktop target'),
          contains('flutter config --enable-macos-desktop'));
    });

    test('builds first, then receives or sends, then reports', () {
      final read = indexOf('Read ci-peer/peer.json');
      final build = indexOf('Build');
      final receive = indexOf('Receive');
      final send = indexOf('Send');
      final summary = indexOf('Step summary');
      final upload = indexOf('Upload the log');
      expect([read, build, receive, send, summary, upload],
          everyElement(isNonNegative));
      expect(read, lessThan(build));
      expect(build, lessThan(receive));
      expect(build, lessThan(send));
      expect(receive, lessThan(summary));
      expect(send, lessThan(summary));
      expect(summary, lessThan(upload));
      expect(runOf('Build'), contains('flutter build macos --debug'));
    });

    test('which of the two runs is the direction in peer.json, and one only',
        () {
      // Each is switched on by the checked value, and by nothing else: with
      // peer.json's default one runs, and with the other value the other.
      expect(steps[indexOf('Receive')]['if'],
          "env.CI_PEER_DIRECTION == 'to-runner'");
      expect(steps[indexOf('Send')]['if'], "env.CI_PEER_DIRECTION == 'to-mac'");
      expect(runOf('Receive'),
          contains('integration_test/ci_peer_receiver.dart -d macos'));
      expect(runOf('Send'),
          contains('integration_test/ci_peer_sender.dart -d macos'));
      expect(runOf('Receive'), isNot(contains('ci_peer_sender')));
      expect(runOf('Send'), isNot(contains('ci_peer_receiver')));
    });

    test('the summary and the log are kept even when the run failed', () {
      expect(steps[indexOf('Step summary')]['if'], 'always()');
      expect(steps[indexOf('Upload the log')]['if'], 'always()');
    });

    test('the receiver gets all four values from peer.json, and the relay '
        'choice', () {
      final run = runOf('Receive');
      for (final define in [
        'CI_PEER_CODE',
        'CI_PEER_NAME',
        'CI_PEER_BYTES',
        'CI_PEER_SHA256',
        'QUICKSHARE_FORCE_RELAY',
      ]) {
        expect(run, contains('--dart-define=$define='), reason: define);
      }
      expect(run, isNot(contains('CI_PEER_SEED')),
          reason: 'it works from the hash; a seed beside it is two opinions');
      expect(run, contains('--reporter=expanded'));
      expect(run, contains('set -o pipefail'),
          reason: 'or tee hides the receiver failing');
    });

    test('the sender gets the code, the seed, the size and the one name it '
        'accepts, and the relay choice', () {
      final run = runOf('Send');
      for (final define in [
        'CI_PEER_CODE',
        'CI_PEER_EXPECT_NAME',
        'CI_PEER_BYTES',
        'CI_PEER_SEED',
        'QUICKSHARE_FORCE_RELAY',
      ]) {
        expect(run, contains('--dart-define=$define='), reason: define);
      }
      // The name given to the sender is the one the receiver announces: both
      // come from peer.json's `name`.
      expect(run, contains('CI_PEER_EXPECT_NAME="\$CI_PEER_NAME"'));
      expect(run, isNot(contains('CI_PEER_SHA256')));
      expect(run, contains('--reporter=expanded'));
      expect(run, contains('set -o pipefail'),
          reason: 'or tee hides the sender failing');
    });

    test('the receiver sees values, never the text of peer.json', () {
      // Values reach the command line through the environment, already
      // checked, and never by expanding an expression into the script.
      for (final step in steps) {
        final run = '${step['run'] ?? ''}';
        expect(run.contains(r'${{'), isFalse,
            reason: 'an expression inside "${nameOf(step)}"\'s script');
      }
    });
  });

  group('what it checks before it believes peer.json', () {
    String read() => runOf('Read ci-peer/peer.json');

    test('every value is matched against what it may look like', () {
      final script = read();
      expect(script, contains(r'^(to-runner|to-mac)$'));
      expect(script, contains(r'^[0-9]{10}$'));
      expect(script, contains(r'^[A-Za-z0-9._-]{1,40}$'));
      expect(script, contains(r'^[1-9][0-9]{0,11}$'));
      expect(script, contains(r'^[0-9a-f]{64}$'));
      expect(script, contains(r'^(true|false)$'));
    });

    test('only what passed is exported', () {
      final script = read();
      // The gate is the line that stops the script when a value failed its
      // pattern; any other `exit 1` (a missing file) says nothing about it.
      final gate = script.indexOf(r'if [ "$bad" -ne 0 ]; then exit 1; fi');
      expect(gate, isNonNegative, reason: 'no stop after a failed check');
      final exportAt = script.indexOf(r'>> "$GITHUB_ENV"');
      expect(exportAt, greaterThan(gate), reason: 'exported before the gate');
      expect(RegExp(r'GITHUB_ENV').allMatches(script), hasLength(1));
    });

    test('runs from the repository root, where ci-peer/ is', () {
      expect(steps[indexOf('Read ci-peer/peer.json')]['working-directory'], '.');
      expect(read(), contains('ci-peer/peer.json'));
    });

    // The script itself, run on files. It needs bash and jq, which every
    // runner and developer machine has and a bare Windows one may not.
    final haveTools = () {
      try {
        return Process.runSync('bash', ['-c', 'jq --version']).exitCode == 0;
      } catch (_) {
        return false;
      }
    }();

    const sha = 'aa11bb22cc33dd44ee55ff6600778899aa11bb22cc33dd44ee55ff6600778899';
    const seed = '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0';

    /// Runs the checking script on [peerJson] (null: no file at all) and says
    /// whether it let it through, what it exported, and what it said.
    ({
      bool passed,
      Map<String, String> exported,
      String said,
      List<String> leftBehind,
    }) check(Object? peerJson) {
      final dir = Directory.systemTemp.createTempSync('dd_ci_peer_wf_');
      try {
        if (peerJson != null) {
          Directory('${dir.path}/ci-peer').createSync();
          File('${dir.path}/ci-peer/peer.json').writeAsStringSync(
              peerJson is String ? peerJson : jsonEncode(peerJson));
        }
        final env = File('${dir.path}/github_env')..createSync();
        final result = Process.runSync(
          'bash',
          ['-c', read()],
          workingDirectory: dir.path,
          environment: {'GITHUB_ENV': env.path},
        );
        final exported = <String, String>{
          for (final line in env.readAsLinesSync())
            if (line.contains('='))
              line.substring(0, line.indexOf('=')):
                  line.substring(line.indexOf('=') + 1),
        };
        return (
          passed: result.exitCode == 0,
          exported: exported,
          said: '${result.stdout}${result.stderr}',
          // Anything the script made beyond what the test put there: the trace
          // a command smuggled in through a value would leave.
          leftBehind: [
            for (final e in dir.listSync(recursive: true))
              if (e is File)
                e.path.substring(dir.path.length + 1),
          ]..removeWhere((f) => f == 'github_env' || f == 'ci-peer/peer.json'),
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    }

    Json toRunner([Json extra = const {}]) => {
          'code': '0123456789',
          'name': 'ci-peer-1a2b3c',
          'bytes': 52428800,
          'sha256': sha,
          ...extra,
        };

    Json toMac([Json extra = const {}]) => {
          'direction': 'to-mac',
          'code': '0123456789',
          'name': 'ci-peer-1a2b3c',
          'bytes': 52428800,
          'seed': seed,
          ...extra,
        };

    group('run on files', () {
      test('a peer.json from before directions existed is to-runner', () {
        final r = check(toRunner());
        expect(r.passed, isTrue, reason: r.said);
        expect(r.exported, {
          'CI_PEER_DIRECTION': 'to-runner',
          'CI_PEER_CODE': '0123456789',
          'CI_PEER_NAME': 'ci-peer-1a2b3c',
          'CI_PEER_BYTES': '52428800',
          'CI_PEER_SHA256': sha,
          'CI_PEER_SEED': '',
          'CI_PEER_FORCE_RELAY': 'false',
        });
      });

      test('to-runner said outright is the same', () {
        final r = check(toRunner({'direction': 'to-runner', 'forceRelay': true}));
        expect(r.passed, isTrue, reason: r.said);
        expect(r.exported['CI_PEER_DIRECTION'], 'to-runner');
        expect(r.exported['CI_PEER_FORCE_RELAY'], 'true');
      });

      test('to-mac exports the seed, and no hash', () {
        final r = check(toMac());
        expect(r.passed, isTrue, reason: r.said);
        expect(r.exported, {
          'CI_PEER_DIRECTION': 'to-mac',
          'CI_PEER_CODE': '0123456789',
          'CI_PEER_NAME': 'ci-peer-1a2b3c',
          'CI_PEER_BYTES': '52428800',
          'CI_PEER_SHA256': '',
          'CI_PEER_SEED': seed,
          'CI_PEER_FORCE_RELAY': 'false',
        });
      });

      test('to-mac does not read a hash it was not meant to use', () {
        // Not exported, not checked: only what the direction uses is read.
        final r = check(toMac({'sha256': 'not even hex'}));
        expect(r.passed, isTrue, reason: r.said);
        expect(r.exported['CI_PEER_SHA256'], '');
      });

      test('to-runner does not read a seed it was not meant to use', () {
        final r = check(toRunner({'seed': 'rm -rf /'}));
        expect(r.passed, isTrue, reason: r.said);
        expect(r.exported['CI_PEER_SEED'], '');
      });

      test('a direction that is neither is refused, whatever its type', () {
        for (final bad in <Object?>['to-nowhere', 'TO-MAC', ' to-mac', '',
            'to-mac\nto-runner', 7, true, null, ['to-mac'], {'a': 1}]) {
          final r = check(toMac({'direction': bad}));
          // null means "absent" to jq's default, which is to-runner and then
          // wants a hash this file does not have.
          expect(r.passed, isFalse, reason: 'direction: ${jsonEncode(bad)}');
          expect(r.exported, isEmpty, reason: 'something was exported');
        }
      });

      test('the fields the direction needs are needed', () {
        for (final missing in ['code', 'name', 'bytes', 'seed']) {
          final doc = toMac()..remove(missing);
          final r = check(doc);
          expect(r.passed, isFalse, reason: 'to-mac without $missing');
          expect(r.exported, isEmpty);
        }
        for (final missing in ['code', 'name', 'bytes', 'sha256']) {
          final doc = toRunner()..remove(missing);
          final r = check(doc);
          expect(r.passed, isFalse, reason: 'to-runner without $missing');
          expect(r.exported, isEmpty);
        }
      });

      test('a seed has to be 64 lower-case hex digits', () {
        for (final bad in <Object?>[
          seed.substring(1),
          '${seed}0',
          seed.toUpperCase(),
          'g${seed.substring(1)}',
          '$seed\n$seed',
          123,
          null,
          ['x'],
        ]) {
          final r = check(toMac({'seed': bad}));
          expect(r.passed, isFalse, reason: 'seed: ${jsonEncode(bad)}');
          expect(r.exported, isEmpty);
        }
      });

      test('the runner is not asked to write more than 2 GiB', () {
        expect(check(toMac({'bytes': 2147483648})).passed, isTrue);
        final over = check(toMac({'bytes': 2147483649}));
        expect(over.passed, isFalse);
        expect(over.said, contains('2 GiB'));
        expect(over.exported, isEmpty);
        // Receiving writes nothing the sender did not choose to send, so the
        // bound is about the sender only.
        expect(check(toRunner({'bytes': 5000000000})).passed, isTrue);
      });

      test('a code, a name and a size that is not what it should be', () {
        for (final doc in [
          toMac({'code': '012345678'}),
          toMac({'code': '01234567890'}),
          toMac({'code': 'abcdefghij'}),
          toMac({'code': 123456789012}),
          toMac({'name': ''}),
          toMac({'name': 'a' * 41}),
          toMac({'name': 'x y'}),
          toMac({'name': r'$(touch pwned)'}),
          toMac({'name': 'a;b'}),
          toMac({'name': '`id`'}),
          toMac({'name': 'a\nCI_PEER_SEED=1'}),
          toMac({'bytes': 0}),
          toMac({'bytes': -5}),
          toMac({'bytes': '100'}),
          toMac({'bytes': 1.5}),
          toMac({'forceRelay': 'true'}),
          toMac({'forceRelay': 1}),
        ]) {
          final r = check(doc);
          expect(r.passed, isFalse, reason: jsonEncode(doc));
          expect(r.exported, isEmpty, reason: jsonEncode(doc));
        }
      });

      test('nothing a value says reaches a shell', () {
        for (final hostile in [
          r'$(touch pwned)',
          '`touch pwned`',
          'x;touch pwned',
          'x&&touch pwned',
          'x\ntouch pwned',
        ]) {
          for (final field in ['name', 'code']) {
            final r = check(toMac({field: hostile}));
            expect(r.passed, isFalse, reason: '$field: $hostile');
            expect(r.leftBehind, isEmpty,
                reason: '$field: $hostile left a file behind');
          }
        }
        // And a good file leaves nothing but what it exports.
        expect(check(toMac()).leftBehind, isEmpty);
      });

      test('no file, a file that is not JSON, one that is not an object', () {
        expect(check(null).passed, isFalse);
        for (final text in ['', 'not json', '[1,2]', '"to-mac"', 'null', '7']) {
          final r = check(text);
          expect(r.passed, isFalse, reason: 'peer.json: $text');
          expect(r.exported, isEmpty);
        }
      });
    }, skip: haveTools ? false : 'needs bash and jq');
  });

  group('the Dart halves', () {
    test('exist and are not picked up by a directory-wide test run', () {
      for (final name in [
        'ci_peer_sender.dart',
        'ci_peer_receiver.dart',
        'ci_peer_support.dart',
      ]) {
        expect(repoFile('quickshare/integration_test/$name').existsSync(), isTrue,
            reason: name);
        expect(name.endsWith('_test.dart'), isFalse,
            reason: '$name would run with `flutter test integration_test/` '
                'and fail for lack of a sender');
      }
    });
  });
}

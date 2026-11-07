// What `.github/workflows/ci_peer.yml` must stay: a workflow that runs on one
// kind of push and on nothing else, holds no secret, and receives the file
// from what `ci-peer/peer.json` says only after checking it.
//
// The receiver is a real device on a real runner talking to somebody's Mac
// over the public internet; nothing here runs it. This only keeps the file
// from drifting into something that would start on a pull request, or hand an
// unchecked value to a shell.
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
  final job = (workflow['jobs'] as Json)['receive_by_code'] as Json;
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

    test('a single job, with a limit of about thirty-five minutes', () {
      expect((workflow['jobs'] as Json).keys, ['receive_by_code']);
      expect(job['timeout-minutes'], 35);
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

    test('builds first, then receives, then reports', () {
      final read = indexOf('Read ci-peer/peer.json');
      final build = indexOf('Build');
      final receive = indexOf('Receive');
      final summary = indexOf('Step summary');
      final upload = indexOf('Upload the log');
      expect([read, build, receive, summary, upload], everyElement(isNonNegative));
      expect(read, lessThan(build));
      expect(build, lessThan(receive));
      expect(receive, lessThan(summary));
      expect(summary, lessThan(upload));
      expect(runOf('Build'), contains('flutter build macos --debug'));
    });

    test('the summary and the log are kept even when the run failed', () {
      expect(steps[indexOf('Step summary')]['if'], 'always()');
      expect(steps[indexOf('Upload the log')]['if'], 'always()');
    });

    test('the receiver gets all four values from peer.json, and the relay '
        'choice', () {
      final run = runOf('Receive');
      expect(run, contains('integration_test/ci_peer_receiver.dart -d macos'));
      for (final define in [
        'CI_PEER_CODE',
        'CI_PEER_NAME',
        'CI_PEER_BYTES',
        'CI_PEER_SHA256',
        'QUICKSHARE_FORCE_RELAY',
      ]) {
        expect(run, contains('--dart-define=$define='), reason: define);
      }
      expect(run, contains('--reporter=expanded'));
      expect(run, contains('set -o pipefail'),
          reason: 'or tee hides the receiver failing');
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

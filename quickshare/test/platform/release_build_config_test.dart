// The build produces a signed release or no release, on every platform.
//
// DD-07 — a plain `flutter build apk --release` with no signing keys used to
// print a note and hand back an unsigned APK: valid-looking until Play rejects
// it, upgradable over nothing. The Gradle script fails that build now, unless
// ALLOW_UNSIGNED_RELEASE=1 marks it as unsigned on purpose — the fork-PR path
// in CI.
//
// DD-08 — the Linux desktop job built `--debug` and packaged nothing, while
// Windows and macOS built `--release` and were published. Five platforms as
// equals means Linux ships the same profile and the same way.
//
// DD-QA-01 — these used to be substring checks on the workflow text, and one
// of them pinned `needs: [ windows, macos, linux ]` verbatim: it failed the
// day Android was added to the release, for a reason that had nothing to do
// with Linux, and a rewrite that kept the string but dropped a job would have
// passed. The workflow assertions now read the parsed document (jobs, `needs`
// as a set, steps, `with:` inputs), each in a pure function that takes the
// parsed YAML and returns what is wrong with it. The mutation group at the
// bottom feeds those functions a workflow with Linux deliberately taken out,
// so a check that has gone vacuous fails there instead of passing silently.
//
// The same checks run for every platform the release publishes, not only
// Linux. A table says what each one builds, uploads and publishes; the checks
// read it. The mutation group feeds them a workflow with each platform taken
// apart in turn, so a platform whose checks have gone vacuous fails there.
//
// Gradle has no parser here, so its checks stay text — but text with the
// comments taken out, and read as blocks: a `throw` that has been commented
// out, or a signing config that has been deleted, leaves every phrase in the
// file in place. So does the shell inside a `run:` block, except for the one
// fact that lives in its shape: which branch of the keystore `if` sets the
// unsigned escape hatch.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

// ---------------------------------------------------------------------------
// The parsed workflow
// ---------------------------------------------------------------------------

typedef Json = Map<String, Object?>;

/// What is wrong, one sentence each. Empty means the check holds.
typedef Problems = List<String>;

/// YAML nodes copied into plain maps and lists, so a test can deep-copy a
/// workflow through JSON and change the copy.
Object? plain(Object? node) {
  if (node is YamlMap) {
    return <String, Object?>{
      for (final e in node.entries) '${e.key}': plain(e.value),
    };
  }
  if (node is YamlList) return <Object?>[for (final v in node) plain(v)];
  return node;
}

/// An unparseable or non-mapping document comes back empty, so every check on
/// it reports a missing job instead of throwing.
Json parseWorkflow(String source) {
  final doc = plain(loadYaml(source));
  return doc is Map<String, Object?> ? doc : <String, Object?>{};
}

Json deepCopy(Json workflow) =>
    jsonDecode(jsonEncode(workflow)) as Map<String, Object?>;

Json _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : <String, Object?>{};
List<Object?> _list(Object? v) => v is List ? v : const <Object?>[];

Json _jobs(Json wf) => _map(wf['jobs']);
bool _hasJob(Json wf, String id) => _jobs(wf)[id] is Map;
Json _job(Json wf, String id) => _map(_jobs(wf)[id]);

List<Json> _steps(Json job) => [
      for (final s in _list(job['steps']))
        if (s is Map) _map(s)
    ];

/// Every line of every `run:` script in the job, trimmed. A script is a block
/// scalar with several commands, so "does this job run X" is a question about
/// lines, not about the `run` value as a whole.
List<String> _runLines(Json job) => [
      for (final s in _steps(job))
        if (s['run'] is String)
          for (final line in (s['run'] as String).split('\n')) line.trim(),
    ];

/// The `uses:` steps whose action is [action] at any ref.
List<Json> _uses(Json job, String action) => [
      for (final s in _steps(job))
        if ('${s['uses']}'.startsWith('$action@')) s,
    ];

/// A `with:` input as a string, or '' when it is absent.
String _with(Json step, String input) => '${_map(step['with'])[input] ?? ''}';

/// `needs:` is a string for one dependency and a list for several; either way
/// the order means nothing.
Set<String> _needs(Json job) {
  final needs = job['needs'];
  if (needs is String) return {needs};
  return {for (final n in _list(needs)) '$n'};
}

/// Every key and scalar in the document with the path it was found at.
Iterable<MapEntry<String, String>> _allStrings(Object? node,
    [String path = '']) sync* {
  if (node is Map) {
    for (final e in node.entries) {
      yield MapEntry('$path/${e.key} (key)', '${e.key}');
      yield* _allStrings(e.value, '$path/${e.key}');
    }
  } else if (node is List) {
    for (var i = 0; i < node.length; i++) {
      yield* _allStrings(node[i], '$path[$i]');
    }
  } else if (node != null) {
    yield MapEntry(path, '$node');
  }
}

/// The branches of the first top-level `if … elif … else … fi` in a shell
/// script: each branch's header line and the lines under it. Enough shell to
/// answer "which branch does this line live in", and no more.
List<({String header, String body})> shellBranches(String script) {
  final branches = <({String header, String body})>[];
  var header = '';
  final body = StringBuffer();
  var depth = 0;
  void flush() {
    branches.add((header: header, body: body.toString()));
    body.clear();
  }

  for (final raw in script.split('\n')) {
    final line = raw.trim();
    if (depth == 0) {
      if (branches.isNotEmpty) break; // only the first `if`
      if (line.startsWith('if ')) {
        depth = 1;
        header = line;
      }
      continue;
    }
    if (depth == 1 && (line.startsWith('elif ') || line == 'else')) {
      flush();
      header = line;
      continue;
    }
    if (line.startsWith('if ')) depth++;
    if (line == 'fi') {
      depth--;
      if (depth == 0) {
        flush();
        continue;
      }
    }
    body.writeln(line);
  }
  return branches;
}

// ---------------------------------------------------------------------------
// DD-08 — what the desktop workflow has to say about Linux
// ---------------------------------------------------------------------------

const linuxJob = 'build_desktop_linux';
const linuxArtifact = 'DirectDrop-linux';
const linuxFile = 'DirectDrop-linux-x64.tar.gz';

/// Everything the release publishes from. Android joined the desktop three in
/// the same workflow; the release has to wait for all four.
const releaseInputs = [
  'build_desktop_windows',
  'build_desktop_macos',
  'build_desktop_linux',
  'build_android',
];

Problems checkJobsExist(Json wf) => [
      for (final id in [...releaseInputs, 'release'])
        if (!_hasJob(wf, id)) 'job $id does not exist',
    ];

Problems checkLinuxBuildsRelease(Json wf) {
  if (!_hasJob(wf, linuxJob)) return ['job $linuxJob does not exist'];
  final runs = _runLines(_job(wf, linuxJob));
  return [
    if (!runs.any((l) => l.contains('flutter build linux --release')))
      '$linuxJob never runs `flutter build linux --release`',
  ];
}

/// Debug builds are what ci.yml is for (compile checks that must not need
/// signing keys); nothing in the workflow that publishes may build one.
Problems checkNoDebugBuilds(Json wf) {
  final debugBuild = RegExp(r'\bflutter\s+build\b.*--debug\b');
  return [
    for (final e in _jobs(wf).entries)
      for (final line in _runLines(_map(e.value)))
        if (debugBuild.hasMatch(line)) 'job ${e.key} builds debug: `$line`',
  ];
}

Problems checkLinuxArtifactUploaded(Json wf) {
  if (!_hasJob(wf, linuxJob)) return ['job $linuxJob does not exist'];
  final job = _job(wf, linuxJob);
  final uploads = _uses(job, 'actions/upload-artifact').where((s) =>
      _with(s, 'name') == linuxArtifact &&
      _with(s, 'path').contains(linuxFile));
  return [
    if (!_runLines(job).any((l) => l.contains('tar ') && l.contains(linuxFile)))
      '$linuxJob never packs $linuxFile',
    if (uploads.isEmpty)
      '$linuxJob uploads no artifact named $linuxArtifact containing $linuxFile',
  ];
}

Problems checkReleaseNeedsEveryBuild(Json wf) {
  if (!_hasJob(wf, 'release')) return ['job release does not exist'];
  final needs = _needs(_job(wf, 'release'));
  return [
    for (final id in releaseInputs)
      if (!needs.contains(id)) 'release does not wait for $id (needs: $needs)',
  ];
}

Problems checkReleaseDownloadsLinux(Json wf) {
  if (!_hasJob(wf, 'release')) return ['job release does not exist'];
  final downloads = _uses(_job(wf, 'release'), 'actions/download-artifact')
      .where((s) => _with(s, 'name') == linuxArtifact);
  return [
    if (downloads.isEmpty)
      'release never downloads the $linuxArtifact artifact',
  ];
}

Problems checkReleasePublishesLinux(Json wf) {
  if (!_hasJob(wf, 'release')) return ['job release does not exist'];
  final publish = _uses(_job(wf, 'release'), 'softprops/action-gh-release');
  if (publish.isEmpty) return ['release has no action-gh-release step'];
  // `files:` is one block scalar holding a path per line.
  final listed = _with(publish.first, 'files')
      .split(RegExp(r'\s+'))
      .where((f) => f.split('/').last == linuxFile);
  return [
    if (listed.isEmpty) 'the published file list does not include $linuxFile',
  ];
}

/// The app no longer reads this define (the Worker takes no client secret), so
/// a workflow passing it is shipping a dead one — and implying a secret that
/// protects nothing.
Problems checkNoTurnSecret(Json wf) => [
      for (final s in _allStrings(wf))
        if (s.value.contains('QUICKSHARE_TURN_SECRET'))
          'QUICKSHARE_TURN_SECRET is passed at ${s.key}',
    ];

/// Every check that takes the desktop workflow, by name, so the mutation group
/// below can say which of them must notice what.
final Map<String, Problems Function(Json)> desktopChecks = {
  'jobs exist': checkJobsExist,
  'Linux builds release': checkLinuxBuildsRelease,
  'no debug builds': checkNoDebugBuilds,
  'Linux artifact uploaded': checkLinuxArtifactUploaded,
  'release needs every build': checkReleaseNeedsEveryBuild,
  'release downloads Linux': checkReleaseDownloadsLinux,
  'release publishes Linux': checkReleasePublishesLinux,
  'no TURN secret': checkNoTurnSecret,
  'every build is a release': checkEveryBuildIsRelease,
  for (final platform in platforms) ...{
    '${platform.name} builds release': (wf) => checkBuildsRelease(wf, platform),
    '${platform.name} artifacts uploaded': (wf) =>
        checkArtifactsUploaded(wf, platform),
    '${platform.name} downloaded by the release': (wf) =>
        checkReleaseDownloads(wf, platform),
    '${platform.name} published by the release': (wf) =>
        checkReleasePublishes(wf, platform),
  },
};

// ---------------------------------------------------------------------------
// Every other platform the release publishes
// ---------------------------------------------------------------------------

/// What one platform has to build, upload and publish.
typedef Platform = ({
  String name,

  /// The job that builds it.
  String job,

  /// Commands that must appear in that job, each one a release build.
  List<String> builds,

  /// Uploads: the artifact name, and a fragment of the `path:` it carries.
  List<({String artifact, String path})> artifacts,

  /// Basenames in the release's `files:` list.
  List<String> published,
});

const platforms = <Platform>[
  (
    name: 'Windows',
    job: 'build_desktop_windows',
    builds: ['flutter build windows --release'],
    artifacts: [
      (
        artifact: 'DirectDrop-windows-portable',
        path: 'DirectDrop-windows-portable.zip'
      ),
      (
        artifact: 'DirectDrop-windows-setup',
        path: 'DirectDrop-windows-setup.exe'
      ),
    ],
    published: [
      'DirectDrop-windows-setup.exe',
      'DirectDrop-windows-portable.zip',
    ],
  ),
  (
    name: 'macOS',
    job: 'build_desktop_macos',
    builds: ['flutter build macos --release'],
    artifacts: [(artifact: 'DirectDrop-macos', path: 'DirectDrop-macos.dmg')],
    published: ['DirectDrop-macos.dmg'],
  ),
  (
    name: 'Android',
    job: 'build_android',
    builds: [
      'flutter build apk --release',
      'flutter build appbundle --release',
    ],
    artifacts: [
      (artifact: 'android-release', path: '*-release.apk'),
      (artifact: 'android-release', path: '*.aab'),
    ],
    published: [
      'DirectDrop-android-arm64-v8a.apk',
      'DirectDrop-android-armeabi-v7a.apk',
      'DirectDrop-android-x86_64.apk',
    ],
  ),
];

Problems checkBuildsRelease(Json wf, Platform platform) {
  if (!_hasJob(wf, platform.job)) return ['job ${platform.job} does not exist'];
  final runs = _runLines(_job(wf, platform.job));
  return [
    for (final build in platform.builds)
      if (!runs.any((l) => l.contains(build)))
        '${platform.job} never runs `$build`',
  ];
}

Problems checkArtifactsUploaded(Json wf, Platform platform) {
  if (!_hasJob(wf, platform.job)) return ['job ${platform.job} does not exist'];
  final uploads = _uses(_job(wf, platform.job), 'actions/upload-artifact');
  return [
    for (final a in platform.artifacts)
      if (!uploads.any((s) =>
          _with(s, 'name') == a.artifact && _with(s, 'path').contains(a.path)))
        '${platform.job} uploads no artifact named ${a.artifact} '
            'containing ${a.path}',
  ];
}

Problems checkReleaseDownloads(Json wf, Platform platform) {
  if (!_hasJob(wf, 'release')) return ['job release does not exist'];
  final downloads = _uses(_job(wf, 'release'), 'actions/download-artifact');
  return [
    for (final name in {for (final a in platform.artifacts) a.artifact})
      if (!downloads.any((s) => _with(s, 'name') == name))
        'release never downloads the $name artifact',
  ];
}

Problems checkReleasePublishes(Json wf, Platform platform) {
  if (!_hasJob(wf, 'release')) return ['job release does not exist'];
  final publish = _uses(_job(wf, 'release'), 'softprops/action-gh-release');
  if (publish.isEmpty) return ['release has no action-gh-release step'];
  final listed = _with(publish.first, 'files')
      .split(RegExp(r'\s+'))
      .map((f) => f.split('/').last)
      .toSet();
  return [
    for (final file in platform.published)
      if (!listed.contains(file))
        'the published file list does not include $file',
  ];
}

/// Every `flutter build` in the workflow is a release build. Not "none is a
/// debug build": a `--profile` build is not one, and ships just as wrongly.
Problems checkEveryBuildIsRelease(Json wf) {
  final build = RegExp(r'^flutter\s+build\s+\S+');
  return [
    for (final e in _jobs(wf).entries)
      for (final line in _runLines(_map(e.value)))
        if (build.hasMatch(line) && !RegExp(r'--release\b').hasMatch(line))
          'job ${e.key} builds something that is not a release: `$line`',
  ];
}

// ---------------------------------------------------------------------------
// DD-07 — where the unsigned escape hatch may be set
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// DD-07 — the Gradle script, as code and not as prose
// ---------------------------------------------------------------------------

/// [gradle] with its comments gone: `//` to the end of a line and `/* … */`,
/// leaving string literals alone (a `//` inside a string is not a comment).
String withoutComments(String gradle) {
  final out = StringBuffer();
  String? quote;
  for (var i = 0; i < gradle.length; i++) {
    final c = gradle[i];
    final next = i + 1 < gradle.length ? gradle[i + 1] : '';
    if (quote != null) {
      out.write(c);
      if (c == r'\') {
        if (next.isNotEmpty) out.write(next);
        i++;
      } else if (c == quote) {
        quote = null;
      }
    } else if (c == '"' || c == "'") {
      quote = c;
      out.write(c);
    } else if (c == '/' && next == '/') {
      while (i < gradle.length && gradle[i] != '\n') {
        i++;
      }
      out.write('\n');
    } else if (c == '/' && next == '*') {
      i += 2;
      while (i + 1 < gradle.length &&
          !(gradle[i] == '*' && gradle[i + 1] == '/')) {
        i++;
      }
      i++;
    } else {
      out.write(c);
    }
  }
  return out.toString();
}

/// The lines inside the first block whose opening line matches [header], up
/// to its closing brace. Braces in string literals do not count. Empty when
/// there is no such block.
List<String> blockOf(List<String> lines, RegExp header) {
  final inside = <String>[];
  var depth = 0;
  var open = false;
  for (final line in lines) {
    if (!open) {
      if (header.hasMatch(line)) {
        open = true;
        depth = _braceDelta(line);
      }
      continue;
    }
    depth += _braceDelta(line);
    if (depth <= 0) return inside;
    inside.add(line);
  }
  return open ? inside : const [];
}

int _braceDelta(String line) {
  var delta = 0;
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
    } else if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '{') {
      delta++;
    } else if (c == '}') {
      delta--;
    }
  }
  return delta;
}

/// What is wrong with the release signing in `build.gradle`, read from the
/// code that runs rather than from the words in the file.
Problems checkGradleSigning(String gradle) {
  final lines = [
    for (final l in withoutComments(gradle).split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  final problems = <String>[];

  if (lines.any((l) => l.contains('signingConfigs.debug'))) {
    problems.add('the debug key is used somewhere');
  }

  final release = blockOf(
      blockOf(lines, RegExp(r'^buildTypes\s*\{')), RegExp(r'^release\s*\{'));
  if (release.isEmpty) problems.add('there is no release build type');
  final signed = blockOf(release, RegExp(r'^if \(hasReleaseSigning\)\s*\{'));
  if (!signed.contains('signingConfig signingConfigs.release')) {
    problems.add('the release build type is not given the release signing '
        'config when there is one');
  }
  final unsigned = blockOf(release, RegExp(r'^\}\s*else\s*\{'));
  if (unsigned.any((l) => l.startsWith('signingConfig ') && l != 'signingConfig null')) {
    problems.add('without keys the release build type gets a signing config');
  }

  final gate = blockOf(lines, RegExp(r'^gradle\.taskGraph\.whenReady\b'));
  if (gate.isEmpty) problems.add('the release gate does not run at task-graph time');
  if (!gate.any((l) => l.startsWith('def allowUnsigned') &&
      l.contains("System.getenv('ALLOW_UNSIGNED_RELEASE') == '1'"))) {
    problems.add('the escape hatch is not read from ALLOW_UNSIGNED_RELEASE=1');
  }
  final refusal = blockOf(
      gate,
      RegExp(r'^if \(wantsRelease && !hasReleaseSigning && !allowUnsigned\)'
          r'\s*\{'));
  if (!refusal.any((l) => l.startsWith('throw new GradleException('))) {
    problems.add('a release with no keys and no escape hatch does not throw');
  }
  if (!refusal.join(' ').contains('No release signing configured')) {
    problems.add('the refusal does not say why');
  }
  return problems;
}

const hatch = 'ALLOW_UNSIGNED_RELEASE';
const keystoreStep = 'Decode release keystore';

Json? _keystoreStep(Json wf, String jobId) {
  final steps = _steps(_job(wf, jobId)).where((s) => s['name'] == keystoreStep);
  return steps.length == 1 ? steps.single : null;
}

/// ci.yml's Android job: a push without the keystore fails, and only the final
/// `else` — a pull request, which cannot read secrets — builds unsigned on
/// purpose. The name appears nowhere else in the workflow.
Problems checkUnsignedOnlyOnForkPrPath(Json ci) {
  final step = _keystoreStep(ci, 'build_android');
  if (step == null) {
    return ['build_android has no single "$keystoreStep" step'];
  }
  final problems = <String>[];

  final rest = deepCopy(ci);
  _keystoreStep(rest, 'build_android')!.remove('run');
  for (final s in _allStrings(rest)) {
    if (s.value.contains(hatch)) {
      problems.add('$hatch appears outside the keystore script, at ${s.key}');
    }
  }

  if (!'${_map(step['env'])['EVENT_NAME']}'.contains('github.event_name')) {
    problems.add(
        'the keystore step does not read the event from github.event_name');
  }
  final branches = shellBranches('${step['run']}');
  if (branches.length < 3) {
    problems.add('the keystore script is not if / elif push / else '
        '(${branches.length} branches)');
    return problems;
  }
  final fallthrough = branches.last;
  if (!fallthrough.body.contains('$hatch=1')) {
    problems.add('the final else branch does not set $hatch=1');
  }
  for (final b in branches.take(branches.length - 1)) {
    if (b.body.contains(hatch)) {
      problems.add('$hatch is set under `${b.header}`, not only in the else');
    }
  }
  final push = branches.where((b) => b.header.contains('"push"'));
  if (push.isEmpty || identical(push.first, fallthrough)) {
    problems.add('no branch of the keystore script is specific to a push');
  } else if (!push.first.body.contains('exit 1')) {
    problems.add('a push without the keystore does not exit 1');
  }
  return problems;
}

/// The workflow a tag publishes from has no unsigned path at all: no escape
/// hatch anywhere, and a missing keystore ends in `exit 1`.
Problems checkTagBuildAlwaysSigned(Json desktop) {
  final step = _keystoreStep(desktop, 'build_android');
  if (step == null) {
    return ['build_android has no single "$keystoreStep" step'];
  }
  return [
    for (final s in _allStrings(desktop))
      if (s.value.contains(hatch)) '$hatch appears at ${s.key}',
    if (!shellBranches('${step['run']}')
        .any((b) => b.header == 'else' && b.body.contains('exit 1')))
      'a tag build without the keystore does not exit 1',
  ];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  File repoFile(String relative) {
    // Tests run from `quickshare/`; the workflows live at the repo root above.
    for (final base in ['.', '..']) {
      final f = File('$base/$relative');
      if (f.existsSync()) return f;
    }
    fail('could not find $relative from ${Directory.current.path}');
  }

  Json workflow(String name) =>
      parseWorkflow(repoFile('.github/workflows/$name').readAsStringSync());

  group('DD-07 — Android release signing', () {
    final gradle = File('android/app/build.gradle').readAsStringSync();

    test('an unsigned release fails the build', () {
      expect(gradle, contains('throw new GradleException'));
      expect(gradle, contains('No release signing configured'));
    });

    test('the failure is gated on a release task, not configuration time', () {
      // Throwing while the release buildType is configured would also break a
      // debug build, which configures the same block.
      expect(gradle, contains('gradle.taskGraph.whenReady'));
    });

    test('there is a documented way to build unsigned on purpose', () {
      expect(gradle, contains('ALLOW_UNSIGNED_RELEASE'));
    });

    test('the debug key is never a fallback', () {
      // The whole point: a debug-signed "release" installs and looks fine
      // until the store rejects it.
      expect(gradle, isNot(contains('signingConfigs.debug')));
    });

    test('and the code does what those words say', () {
      // Every phrase above can survive a `throw` that is commented out or a
      // signing config that is deleted. This reads what is left when the
      // comments are gone.
      expect(checkGradleSigning(gradle), isEmpty);
    });

    group('the check notices', () {
      String edit(String from, String to) {
        expect(gradle, contains(from), reason: 'the premise: ${from.trim()}');
        return gradle.replaceFirst(from, to);
      }

      final mutations = <String, String Function()>{
        'the throw commented out, every phrase kept': () => edit(
            '        throw new GradleException(\n',
            '        // throw new GradleException(\n        println(\n'),
        'the throw commented out in a block comment': () => edit(
            '        throw new GradleException(\n',
            '        /* throw new GradleException( */ println(\n'),
        'the release signing config deleted': () => edit(
            '                signingConfig signingConfigs.release\n', ''),
        'the release signing config commented out': () => edit(
            '                signingConfig signingConfigs.release\n',
            '                // signingConfig signingConfigs.release\n'),
        'the debug key as the release key': () => edit(
            '                signingConfig signingConfigs.release\n',
            '                signingConfig signingConfigs.debug\n'),
        'the debug key when there are no keys': () => edit(
            '                signingConfig null\n',
            '                signingConfig signingConfigs.debug\n'),
        'the refusal made conditional on nothing': () => edit(
            'if (wantsRelease && !hasReleaseSigning && !allowUnsigned) {',
            'if (false) {'),
        'the escape hatch always on': () => edit(
            "System.getenv('ALLOW_UNSIGNED_RELEASE') == '1'", 'true'),
        'the gate run at configuration time': () => edit(
            'gradle.taskGraph.whenReady { graph ->', 'def gate = { graph ->'),
      };
      for (final m in mutations.entries) {
        test(m.key, () {
          final mutated = m.value();
          expect(mutated, isNot(gradle));
          expect(checkGradleSigning(mutated), isNotEmpty);
        });
      }
    });

    test('comments are taken out and strings are not', () {
      expect(
          withoutComments('a // b\nc "//" d /* e\nf */ g\n\'/*\' h'),
          'a \nc "//" d  g\n\'/*\' h');
    });

    test('CI sets the escape hatch only on the fork-PR path', () {
      expect(checkUnsignedOnlyOnForkPrPath(workflow('ci.yml')), isEmpty);
    });

    test('a tag build has no unsigned path', () {
      expect(checkTagBuildAlwaysSigned(workflow('build_desktop.yml')), isEmpty);
    });
  });

  group('DD-08 — the desktop workflow', () {
    final desktop = workflow('build_desktop.yml');

    for (final check in desktopChecks.entries) {
      test(check.key, () {
        expect(check.value(desktop), isEmpty);
      });
    }

    test('no workflow passes QUICKSHARE_TURN_SECRET', () {
      // The define is gone from the app; the Worker needs no client secret.
      final workflows = repoFile('.github/workflows/build_desktop.yml')
          .parent
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
          .toList();
      expect(workflows, hasLength(greaterThan(1)),
          reason: 'expected every workflow in the directory, not just one');
      for (final f in workflows) {
        expect(checkNoTurnSecret(parseWorkflow(f.readAsStringSync())), isEmpty,
            reason: f.path);
      }
    });
  });

  group('mutation — taking Linux out of the release fails visibly', () {
    final base = workflow('build_desktop.yml');

    // Each mutation edits a copy of the real workflow and names the checks
    // that must report it. A mutation that changes nothing, or a check that
    // stays quiet, fails here.
    final mutations = <String,
        ({
      void Function(Json) apply,
      List<String> caughtBy,
    })>{
      'Linux removed from release.needs': (
        apply: (wf) {
          final needs = _job(wf, 'release')['needs'] as List;
          needs.remove('build_desktop_linux');
        },
        caughtBy: ['release needs every build'],
      ),
      'the Linux job removed': (
        apply: (wf) => _jobs(wf).remove(linuxJob),
        caughtBy: [
          'jobs exist',
          'Linux builds release',
          'Linux artifact uploaded',
        ],
      ),
      '--release replaced by --debug in the Linux job': (
        apply: (wf) {
          for (final step in _steps(_job(wf, linuxJob))) {
            final run = step['run'];
            if (run is String) {
              step['run'] = run.replaceAll('--release', '--debug');
            }
          }
        },
        caughtBy: ['Linux builds release', 'no debug builds'],
      ),
      '--debug in the macOS job': (
        apply: (wf) {
          for (final step in _steps(_job(wf, 'build_desktop_macos'))) {
            final run = step['run'];
            if (run is String) {
              step['run'] = run.replaceAll('--release', '--debug');
            }
          }
        },
        caughtBy: ['no debug builds'],
      ),
      'the Linux artifact renamed': (
        apply: (wf) {
          for (final step
              in _uses(_job(wf, linuxJob), 'actions/upload-artifact')) {
            _map(step['with'])['name'] = 'linux';
          }
        },
        caughtBy: ['Linux artifact uploaded'],
      ),
      'the Linux artifact dropped from the publish list': (
        apply: (wf) {
          for (final step
              in _uses(_job(wf, 'release'), 'softprops/action-gh-release')) {
            final files = _map(step['with']);
            files['files'] = '${files['files']}'
                .split('\n')
                .where((l) => !l.contains(linuxFile))
                .join('\n');
          }
        },
        caughtBy: ['release publishes Linux'],
      ),
      'the release no longer downloads the Linux artifact': (
        apply: (wf) {
          final steps = _list(_job(wf, 'release')['steps']);
          steps.removeWhere(
              (s) => s is Map && _map(s['with'])['name'] == linuxArtifact);
        },
        caughtBy: ['release downloads Linux'],
      ),
      'QUICKSHARE_TURN_SECRET passed to a build': (
        apply: (wf) {
          final step = _steps(_job(wf, linuxJob)).first;
          step['env'] = {'QUICKSHARE_TURN_SECRET': r'${{ secrets.TURN }}'};
        },
        caughtBy: ['no TURN secret'],
      ),
    };

    // The same treatment for every platform that is not Linux, one step at a
    // time: each platform's job, release input, build, artifact and publish
    // entry is taken apart and the checks have to say which.
    for (final platform in platforms) {
      final prefix = platform.name;
      mutations['$prefix removed from release.needs'] = (
        apply: (wf) => (_job(wf, 'release')['needs'] as List).remove(platform.job),
        caughtBy: ['release needs every build'],
      );
      mutations['the $prefix job removed'] = (
        apply: (wf) => _jobs(wf).remove(platform.job),
        caughtBy: [
          'jobs exist',
          '$prefix builds release',
          '$prefix artifacts uploaded',
        ],
      );
      mutations['--release replaced by --profile in the $prefix job'] = (
        apply: (wf) {
          for (final step in _steps(_job(wf, platform.job))) {
            final run = step['run'];
            if (run is String) {
              step['run'] = run.replaceAll('--release', '--profile');
            }
          }
        },
        caughtBy: ['$prefix builds release', 'every build is a release'],
      );
      mutations['a $prefix artifact renamed'] = (
        apply: (wf) {
          for (final step
              in _uses(_job(wf, platform.job), 'actions/upload-artifact')) {
            _map(step['with'])['name'] = 'renamed';
          }
        },
        caughtBy: ['$prefix artifacts uploaded'],
      );
      mutations['a $prefix file dropped from the publish list'] = (
        apply: (wf) {
          for (final step
              in _uses(_job(wf, 'release'), 'softprops/action-gh-release')) {
            final files = _map(step['with']);
            files['files'] = '${files['files']}'
                .split('\n')
                .where((l) => l.split('/').last != platform.published.first)
                .join('\n');
          }
        },
        caughtBy: ['$prefix published by the release'],
      );
      mutations['the release no longer downloads a $prefix artifact'] = (
        apply: (wf) {
          final steps = _list(_job(wf, 'release')['steps']);
          steps.removeWhere((s) =>
              s is Map &&
              _map(s['with'])['name'] == platform.artifacts.first.artifact);
        },
        caughtBy: ['$prefix downloaded by the release'],
      );
    }

    test('the unmodified workflow passes every check', () {
      for (final check in desktopChecks.entries) {
        expect(check.value(base), isEmpty, reason: check.key);
      }
    });

    for (final m in mutations.entries) {
      test(m.key, () {
        final copy = deepCopy(base);
        m.value.apply(copy);
        expect(jsonEncode(copy), isNot(jsonEncode(base)),
            reason: 'the mutation changed nothing');
        for (final name in m.value.caughtBy) {
          expect(desktopChecks[name]!(copy), isNotEmpty,
              reason: '"$name" stays quiet when: ${m.key}');
        }
      });
    }

    test('a missing anchor is a failure, not an exception', () {
      // The old checks sliced the text at indexOf(...), which is -1 — and a
      // RangeError — when the anchor is gone.
      for (final empty in [
        <String, Object?>{},
        parseWorkflow(''),
        parseWorkflow('jobs: nonsense'),
        parseWorkflow('- a\n- b'),
      ]) {
        for (final check in desktopChecks.entries) {
          // "No X" checks hold on a document with nothing in it.
          if (const {
            'no TURN secret',
            'no debug builds',
            'every build is a release',
          }.contains(check.key)) {
            continue;
          }
          expect(() => check.value(empty), returnsNormally, reason: check.key);
          expect(check.value(empty), isNotEmpty, reason: check.key);
        }
      }
      expect(checkUnsignedOnlyOnForkPrPath({}), isNotEmpty);
      expect(checkTagBuildAlwaysSigned({}), isNotEmpty);
    });
  });

  group('mutation — the unsigned escape hatch stays on the fork-PR path', () {
    final ci = workflow('ci.yml');
    final desktop = workflow('build_desktop.yml');

    test('set in a job-level env', () {
      final copy = deepCopy(ci);
      _job(copy, 'build_android')['env'] = {hatch: '1'};
      expect(checkUnsignedOnlyOnForkPrPath(copy), isNotEmpty);
    });

    test('set in the branch that handles a push', () {
      final copy = deepCopy(ci);
      final run = '${_keystoreStep(copy, 'build_android')!['run']}';
      _keystoreStep(copy, 'build_android')!['run'] =
          run.replaceFirst('exit 1', 'echo "$hatch=1" >> "\$GITHUB_ENV"');
      expect(checkUnsignedOnlyOnForkPrPath(copy), isNotEmpty);
    });

    test('a push without the keystore no longer exits 1', () {
      final copy = deepCopy(ci);
      final run = '${_keystoreStep(copy, 'build_android')!['run']}';
      _keystoreStep(copy, 'build_android')!['run'] =
          run.replaceFirst('exit 1', 'true');
      expect(checkUnsignedOnlyOnForkPrPath(copy), isNotEmpty);
    });

    test('the tag build is handed the hatch', () {
      final copy = deepCopy(desktop);
      _job(copy, 'build_android')['env'] = {hatch: '1'};
      expect(checkTagBuildAlwaysSigned(copy), isNotEmpty);
    });

    test('the tag build stops failing without a keystore', () {
      final copy = deepCopy(desktop);
      final run = '${_keystoreStep(copy, 'build_android')!['run']}';
      _keystoreStep(copy, 'build_android')!['run'] =
          run.replaceFirst('exit 1', 'true');
      expect(checkTagBuildAlwaysSigned(copy), isNotEmpty);
    });
  });
}

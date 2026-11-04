// The README says what the code does, and a test notices when it stops.
//
// DD-DOC-01 — the README told a reader that relayed transfers stop at 50 MB
// (the code said 2 GB), that the TURN server came with public credentials (the
// code ships none), that the local network is plain HTTP (it is HTTPS with a
// pinned certificate) and that no server of ours is in the path (a Worker is).
// Each was true once. Prose does not fail a build, so the claims that can be
// checked mechanically are checked here:
//
//  1. every `QUICKSHARE_*` define the code reads is in the Configuration
//     table, and every name in the table is one the code reads;
//  2. the defaults in that table are the defaults in `AppConstants`, and the
//     relay cap is said in prose as well, in the same unit;
//  3. strings that were true once and are not now do not come back.
//
// What this cannot check is whether the sentences around those facts are
// true. That is the reviewer's job; this only keeps the numbers honest.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/constants/app_constants.dart';

/// The rows of the first table under the `### Configuration` heading, as
/// `(first cell, second cell)`, cells trimmed.
List<(String, String)> configurationRows(String readme) {
  final lines = readme.split('\n');
  final heading = lines.indexWhere((l) => l.trim() == '### Configuration');
  if (heading < 0) fail('README has no "### Configuration" heading');

  final rows = <(String, String)>[];
  var inTable = false;
  for (final line in lines.skip(heading + 1)) {
    final isRow = line.trimLeft().startsWith('|');
    if (!isRow) {
      if (inTable) break;
      continue;
    }
    inTable = true;
    final cells = line.split('|').map((c) => c.trim()).toList();
    // `| a | b | c |` splits to ['', a, b, c, ''].
    if (cells.length < 4) continue;
    final first = cells[1];
    if (first == 'dart-define' || RegExp(r'^[-: ]+$').hasMatch(first)) continue;
    rows.add((first, cells[2]));
  }
  if (rows.isEmpty) fail('the Configuration table has no rows');
  return rows;
}

/// Every name passed to `String`/`bool`/`int.fromEnvironment` under `lib/`.
Set<String> environmentNamesInLib() {
  final call = RegExp(
      r'''(?:String|bool|int)\.fromEnvironment\(\s*['"]([A-Za-z0-9_]+)['"]''');
  final names = <String>{};
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    for (final m in call.allMatches(f.readAsStringSync())) {
      names.add(m.group(1)!);
    }
  }
  return names;
}

String readFileOrFail(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    fail('could not find $path from ${Directory.current.path}');
  }
  return f.readAsStringSync();
}

/// `2147483648` as `2 GB`, the unit the README uses; null if it is not a whole
/// number of gigabytes (or megabytes), so the test says so instead of guessing.
String? gigabytes(int bytes) {
  const gb = 1024 * 1024 * 1024;
  if (bytes > 0 && bytes % gb == 0) return '${bytes ~/ gb} GB';
  return null;
}

/// Catch common spellings of the old claims. This is not a prose verifier:
/// different wording still needs a human review.
List<String> staleClaimLines(String text) {
  final oldCap = RegExp(r'\b50\s*(?:mb|megabytes?)\b', caseSensitive: false);
  final unsafeHttp = RegExp(
    r'\b(?:unencrypted|insecure|plain)\s+http\b',
    caseSensitive: false,
  );
  return [
    for (final line in text.split('\n'))
      if (oldCap.hasMatch(line) ||
          (unsafeHttp.hasMatch(line) &&
              !line.toLowerCase().contains('invitation')))
        line.trim(),
  ];
}

void main() {
  final readme = readFileOrFail('README.md');
  final workerReadme = readFileOrFail('../cloudflare-worker/README.md');

  group('Configuration table', () {
    test('lists every QUICKSHARE_* define the code reads', () {
      final inCode = environmentNamesInLib()
          .where((n) => n.startsWith('QUICKSHARE_'))
          .toSet();
      expect(inCode, isNotEmpty,
          reason: 'found no defines in lib/ — the scan broke');

      final inTable = {
        for (final (name, _) in configurationRows(readme))
          ...RegExp(r'QUICKSHARE_[A-Z0-9_]+')
              .allMatches(name)
              .map((m) => m.group(0)!),
      };
      expect(inCode.difference(inTable), isEmpty,
          reason: 'read by lib/ but missing from the README table');
      expect(inTable.difference(inCode), isEmpty,
          reason: 'in the README table but not read by anything in lib/');
    });

    test('shows the defaults AppConstants has', () {
      // A new define fails the test above first; this one then asks for its
      // expected default here, so adding one is a conscious two-line change.
      final expected = <String, String>{
        'QUICKSHARE_WORKER_URL': AppConstants.workerBaseUrl,
        'QUICKSHARE_RENDEZVOUS_CHANNELS': AppConstants.rendezvousChannels,
        'QUICKSHARE_TURN_URL': AppConstants.turnServerUrl,
        'QUICKSHARE_TURN_HOSTS': AppConstants.turnServerHosts,
        'QUICKSHARE_TURN_USER': AppConstants.turnUsername,
        'QUICKSHARE_TURN_PASS': AppConstants.turnCredential,
        'QUICKSHARE_RELAY_LIMIT': '${AppConstants.maxRelayTransferBytes}',
        'QUICKSHARE_FORCE_RELAY': '${AppConstants.forceRelay}',
      };
      final seen = <String>{};
      for (final (name, defaultCell) in configurationRows(readme)) {
        final key = RegExp(r'QUICKSHARE_[A-Z0-9_]+').firstMatch(name)?.group(0);
        expect(key, isNotNull,
            reason: 'row "$name" names no QUICKSHARE_ define');
        expect(expected, contains(key),
            reason: 'no expected default for $key in this test');
        seen.add(key!);
        // An empty default is written as an em dash.
        final shown = defaultCell.replaceAll('`', '').trim();
        expect(shown == '—' ? '' : shown, expected[key],
            reason: 'the README default for $key');
      }
      expect(seen, expected.keys.toSet());
    });
  });

  group('the relay cap', () {
    test('is stated in prose in the unit the code default converts to', () {
      final cap = gigabytes(AppConstants.maxRelayTransferBytes);
      expect(cap, isNotNull,
          reason:
              'the relay cap is no longer a whole number of GB: say how the '
              'README should state it, then update this test');
      expect(readme, contains('capped at $cap'));
    });
  });

  group('claims that were true once', () {
    test('common variants of stale cap and HTTP claims are flagged', () {
      expect(staleClaimLines('Relay cap is 50MB'), isNotEmpty);
      expect(staleClaimLines('Relay limit is 50 megabytes'), isNotEmpty);
      expect(staleClaimLines('Files use unencrypted HTTP'), isNotEmpty);
      expect(staleClaimLines('The invitation uses plain HTTP'), isEmpty);
      expect(staleClaimLines(readme), isEmpty);
    });
    // Case-sensitive on purpose: these are the exact phrasings that shipped.
    const banned = <String, String>{
      'openrelaymodule': 'public TURN credentials; the code ships none',
      '52428800': 'the old 50 MB relay cap in bytes',
      '50 MB': 'the old relay cap; the default is 2 GB',
      'QUICKSHARE_TURN_SECRET': 'the Worker takes no client secret any more',
      'standard.relay.metered.ca': 'a TURN default; the code has none',
      'no server of ours': 'a Worker of ours is in the path',
      'Nothing of ours is involved': 'a Worker of ours is in the path',
      'LAN traffic is plain HTTP': 'the local network is HTTPS, pinned',
      'not encrypted on the local network':
          'the local network is HTTPS, pinned',
      'starts an HTTP server': 'the server is HTTPS',
      '182 bytes': 'Bluetooth carries no file bytes in this build',
      'Tens of KB/s': 'Bluetooth carries no file bytes in this build',
      'unsigned rather': 'a release build without keys fails',
      'nearby-devices': 'there is no list of devices; a code is the only way',
      'Nearby devices': 'there is no list of devices; a code is the only way',
      'still listed over Bluetooth':
          'a receiver no longer advertises itself and no sender lists it',
      'lists such receivers': 'a Bluetooth sender lists nothing',
      'tap-to-send': 'the plaintext invitation is gone',
      'POST /invite': 'the plaintext invitation is gone',
      'invitation': 'nothing is pushed to another device any more',
    };

    for (final e in banned.entries) {
      test('README does not say "${e.key}"', () {
        expect(readme, isNot(contains(e.key)), reason: e.value);
      });
    }

    test('"plain HTTP" appears only where it is true: the invitation', () {
      final offenders = [
        for (final line in readme.split('\n'))
          if (line.toLowerCase().contains('plain http') &&
              !line.toLowerCase().contains('invitation'))
            line.trim(),
      ];
      expect(offenders, isEmpty,
          reason: 'the local network is HTTPS; only the tap-to-send invitation '
              'is plain HTTP');
    });

    const staleInWorkerReadme = <String, String>{
      'ignores the Worker entirely': 'the Worker address is compiled in',
      'primary rendezvous': 'Nostr and the Worker race as equals',
      'currently Cloudflare-only': 'nothing here can know what production runs',
      'is not implemented': 'the credential refresher exists',
    };
    for (final e in staleInWorkerReadme.entries) {
      test('the Worker README does not say "${e.key}"', () {
        expect(workerReadme, isNot(contains(e.key)), reason: e.value);
      });
    }

    test('the Worker README names the address the app compiles in', () {
      expect(workerReadme, contains(AppConstants.workerBaseUrl));
    });
  });

  group('codes that change', () {
    test('the README gives the interval the code uses', () {
      final minutes = AppConstants.sessionCodeLifetime.inMinutes;
      expect(AppConstants.sessionCodeLifetime,
          Duration(minutes: minutes),
          reason: 'a whole number of minutes, or say how the README should '
              'state it and update this test');
      expect(readme, contains('every $minutes minutes'));
      expect(readme, contains('Codes change every $minutes minutes'));
    });

    test('the README states the Bonjour limit and who can receive over '
        'Bluetooth honestly', () {
      expect(readme, contains('A Bonjour browser can still see that an offer'));
      // Bluetooth is joined by the QR code alone, which a computer cannot
      // scan; the README has to say so rather than imply a list or a code.
      expect(readme, contains('A computer cannot receive over Bluetooth'));
      expect(readme, contains('joined by the QR code and by nothing else'));
    });
  });

  group('sections the README has to keep', () {
    // Each of these answers a question a reader cannot get from the code
    // without reading all of it.
    const headings = [
      '## What works with no configuration',
      '## What needs public infrastructure',
      '## Encryption, per transport',
      '## Limits and abuse protection',
      '## On the receiving disk',
      '## Compatibility',
      '### Known limitations',
    ];
    for (final h in headings) {
      test(h, () {
        expect(readme.split('\n').any((l) => l.startsWith(h)), isTrue,
            reason: 'the README lost its "$h" section');
      });
    }

    test('what the README says about the Worker is scoped to the code', () {
      // Production is deployed separately and may lag this tree; the README
      // must not read as a statement about it.
      expect(readme, contains('applies once that code is deployed'));
    });
  });
}

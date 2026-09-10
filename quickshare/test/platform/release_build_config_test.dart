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
// Pinned as file-content checks, not by running the build: these are the two
// lines that flipped, and the failure mode is that one of them flips back.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String repoFile(String relative) {
    // Tests run from `quickshare/`; the workflows live at the repo root above.
    for (final base in ['.', '..']) {
      final f = File('$base/$relative');
      if (f.existsSync()) return f.readAsStringSync();
    }
    fail('could not find $relative from ${Directory.current.path}');
  }

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

    test('CI sets the escape hatch only on the fork-PR path', () {
      final ci = repoFile('.github/workflows/ci.yml');
      // The line is inside the `else` branch that handles a missing secret.
      final elseBranch = ci.substring(ci.indexOf('expected on a fork PR'));
      expect(elseBranch, contains('ALLOW_UNSIGNED_RELEASE=1'));
      // And a push without the secret still fails outright.
      expect(ci, contains('a release build must be signed'));
      expect(ci, contains('exit 1'));
    });
  });

  group('DD-08 — Linux desktop build', () {
    final desktop = repoFile('.github/workflows/build_desktop.yml');

    test('Linux builds release, like Windows and macOS', () {
      expect(desktop, contains('flutter build linux --release'));
      expect(desktop, isNot(contains('flutter build linux --debug')));
    });

    test('Linux is packaged and uploaded', () {
      expect(desktop, contains('DirectDrop-linux-x64.tar.gz'));
      expect(desktop, contains('name: DirectDrop-linux'));
    });

    test('Linux is attached to the published release', () {
      final release = desktop.substring(desktop.indexOf('softprops/action-gh-release'));
      expect(release, contains('DirectDrop-linux-x64.tar.gz'));
      expect(desktop,
          contains('needs: [ build_desktop_windows, build_desktop_macos, build_desktop_linux ]'));
    });
  });
}

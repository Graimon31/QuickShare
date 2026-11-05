// Making a symbolic link in a test, on a machine that may not allow it.
//
// POSIX lets anybody create one. Windows lets only an administrator, or a user
// with Developer Mode on, and refuses everybody else with "a required privilege
// is not held by the client". A test that needs a link and gets that answer has
// not found a bug; it has found a machine it cannot run on. It says so — in the
// output, with the reason the system gave — and is skipped, rather than failing
// for something the code under test did not do or passing without having
// tested anything.
//
// Junctions need no privilege, and `test/platform/windows_native_test.dart`
// covers those on the one platform that has them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Creates a link at [link] pointing at [target] and returns true. If the
/// platform refuses, marks the running test skipped, with the platform's own
/// words as the reason, and returns false — the test should return at once.
///
/// ```dart
/// if (!linkOrSkip(p.join(base.path, 'sub'), outside.path)) return;
/// ```
bool linkOrSkip(String link, String target) {
  try {
    Link(link).createSync(target);
    return true;
  } on FileSystemException catch (e) {
    final reason = 'this machine cannot create symbolic links '
        '(${e.osError?.message ?? e.message}); on Windows that needs '
        'Developer Mode or an administrator';
    // ignore: avoid_print
    print('SYMLINK_SKIPPED=$reason');
    markTestSkipped(reason);
    return false;
  }
}

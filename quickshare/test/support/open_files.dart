import 'dart:io';

/// Whether this process has [path] open right now — in any isolate — or null
/// where the question cannot be asked.
///
/// Windows will not rename or delete a file that is open, so on Windows a test
/// that renames or deletes the file after the code under test is done *is* the
/// check, and this has nothing to add. Everywhere else a rename or delete
/// succeeds on an open file, so a leaked handle goes unnoticed — until this
/// asks the operating system: `/proc/self/fd` on Linux, `lsof` on macOS.
///
/// [path] must exist when this is called (it is resolved through any links in
/// its folders, as the operating system reports it, e.g. `/private/var` for
/// `/var` on macOS).
bool? holdsOpen(String path) {
  final String resolved;
  try {
    resolved = File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
  try {
    if (Platform.isLinux) {
      for (final fd in Directory('/proc/self/fd').listSync()) {
        try {
          if (Link(fd.path).targetSync() == resolved) return true;
        } on FileSystemException {
          // The descriptor that listing the directory used, already gone.
        }
      }
      return false;
    }
    if (Platform.isMacOS) {
      final result = Process.runSync('lsof', ['-p', '$pid', '-Fn']);
      if (result.exitCode != 0) return null;
      return (result.stdout as String)
          .split('\n')
          .any((line) => line == 'n$resolved');
    }
  } on ProcessException {
    return null;
  }
  return null;
}

/// Whether [raf] has been closed. A closed handle refuses every call with
/// "File closed"; an open one answers — or, with an operation still pending,
/// refuses with a different message, which is told apart here: a handle that
/// is merely busy is not closed.
bool handleIsClosed(RandomAccessFile raf) {
  try {
    raf.lengthSync();
    return false;
  } on FileSystemException catch (e) {
    return e.message.contains('closed');
  }
}

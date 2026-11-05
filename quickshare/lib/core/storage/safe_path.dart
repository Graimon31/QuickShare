import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'package:quickshare/core/security/path_sanitizer.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// A write was about to go somewhere other than where the destination folder
/// says it goes: a symbolic link (or a plain file where a folder must be) sits
/// in the chain between the folder the user chose and the file being written.
///
/// Nothing was written. The message is for the log and for whoever reads the
/// failure; the screen shows [FailureCode.unsafeDestination] in the user's
/// language.
class UnsafePathException implements Exception {
  const UnsafePathException(this.path, this.reason);

  final String path;
  final String reason;

  String get message => 'Refusing to write "$path": $reason';

  @override
  String toString() => 'UnsafePathException: $message';
}

/// The name a file or folder was about to be given is taken — by a file, a
/// folder, or a link, even a dangling one — and replacing it was refused.
class PathTakenException implements Exception {
  const PathTakenException(this.path);

  final String path;

  String get message => '"$path" already exists';

  @override
  String toString() => 'PathTakenException: $message';
}

/// The path is longer than Windows will open without special handling.
class PathTooLongException implements Exception {
  const PathTooLongException(this.path, this.limit);

  final String path;
  final int limit;

  String get message => 'The path is too long for Windows (${path.length} '
      'characters; the limit is $limit): "$path". Choose a save folder closer '
      'to the root of the drive.';

  @override
  String toString() => 'PathTooLongException: $message';
}

/// Every filesystem decision on the receiving side that has to survive a hostile
/// or merely surprising destination folder.
///
/// The names a sender supplies are cleaned lexically by [PathSanitizer]: no
/// `..`, no separators, no reserved names. That says nothing about what is
/// *already on disk* at the place those clean names resolve to — and a
/// symbolic link there walks straight past every lexical check, because the
/// kernel follows it when the file is opened. So, inside the destination:
///
///  * **No write ever follows a link**, including one that points back inside
///    the destination. A link in any component of the path, or a plain file
///    where a folder has to be, ends the transfer with a clear error. (The
///    folder the user *chose* may itself be, or sit under, a link — `/tmp` and
///    `/var` are links on macOS — and is resolved once.)
///  * **A name that is taken in any way is taken.** A dangling link counts:
///    creating a file "through" it would create its target.
///  * **The last step never replaces.** `rename` silently replaces a file that
///    appeared under the chosen name while the download ran; [renameNoClobber]
///    does not, and a conflict becomes a new `name (n).ext`.
///
/// The honest limit: Dart has no `openat`, no `O_NOFOLLOW`, no way to ask "is
/// this open handle the file at that path?". Every check here is a check of a
/// *path*, made just before it is used, so someone who can write into the
/// destination *and* wins a race measured in microseconds between a check and
/// the very next call could still redirect one operation. What narrows it:
/// partials are created with `O_EXCL` (never through a link, dangling or not),
/// opened *without* truncation and re-validated before a byte is written or
/// anything is truncated, and the whole chain is checked again immediately
/// before the final rename. What the check cannot do is out-run an attacker
/// who already controls the user's folder; it makes a stale or accidental
/// link, and every ordinary sender-side trick, harmless.
class SafePath {
  const SafePath._();

  /// Windows opens a path of up to 259 characters (MAX_PATH is 260 including
  /// the terminating NUL) without the `\\?\` prefix and per-process opt-in
  /// that long paths need. A longer one is refused with a clear error rather
  /// than written somewhere Explorer, an installer or a backup tool cannot
  /// open again.
  static const int windowsMaxPath = 260;

  /// Test hook: pretend the filesystem cannot make hard links (exFAT, SMB,
  /// some Android volumes), so the fallback path is exercised on a machine
  /// whose disk can.
  @visibleForTesting
  static bool debugDisableHardLinks = false;

  /// Test hook for the moments where, outside a test, someone else on the
  /// machine could act between one call and the next: [stage] says which
  /// moment, [path] what is about to be touched.
  ///
  ///  * `mkdir` — [ensureParents] has seen that a folder is missing and is
  ///    about to create it;
  ///  * `create` — [openPartial] has seen that the partial is not there and is
  ///    about to create it;
  ///  * `open` — it exists and is about to be opened;
  ///  * `place` — the media saver chose a free name and is about to move onto
  ///    it;
  ///  * `commit` — the repository's copy is done and is about to take its name;
  ///  * `seal` — a received file is whole and closed, and [commitFile] is about
  ///    to look at the folders above it and move it into place. The one moment
  ///    a folder holding the file can be swapped on every system: Windows
  ///    refuses to move a folder that has an open file in it.
  ///
  /// A race cannot be timed from outside, so a test does here what the racing
  /// process would have done. Nothing else ever sets this.
  @visibleForTesting
  static void Function(String stage, String path)? debugRace;

  /// The place a caller marks as one of those moments: runs [debugRace], if a
  /// test set one, and is otherwise nothing.
  static void raceWindow(String stage, String path) =>
      debugRace?.call(stage, path);

  /// Whether the libc calls the atomic path needs were found. A test that
  /// passes whether or not they were would prove nothing about them.
  @visibleForTesting
  static bool get debugAtomicRenameAvailable =>
      !Platform.isWindows && _Posix.instance != null;

  static bool _loggedFallback = false;

  /// Said once per run: on this volume the no-replace rename is the
  /// look-then-rename fallback, not the atomic one. Worth knowing when a
  /// bug report says "my file was replaced".
  static void _noteFallback(String path) {
    if (_loggedFallback) return;
    _loggedFallback = true;
    AppLogger.info(
        'No atomic no-replace rename at $path (no hard links on this volume, '
        'or Windows); falling back to checking the name first',
        tag: 'DISK');
  }

  // --- what is there -------------------------------------------------------

  /// Whether anything occupies [path]: a file, a folder, or a link, even one
  /// pointing nowhere. `File.existsSync` follows links, so a dangling link
  /// reads as "free" there — and is not.
  static bool exists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  /// [path] if it is free, otherwise `stem (1).ext`, `stem (2).ext`, … — the
  /// `name (n).ext` convention every receiver here uses.
  static String uniquePath(String path) {
    var candidate = path;
    var counter = 1;
    while (exists(candidate)) {
      final ext = p.extension(path);
      final stem = p.basenameWithoutExtension(path);
      candidate = p.join(p.dirname(path), '$stem ($counter)$ext');
      counter++;
    }
    return candidate;
  }

  // --- the destination -----------------------------------------------------

  /// [base] with every link in it resolved, for a base that may not exist yet:
  /// the deepest existing ancestor is resolved and the rest appended.
  static String canonicalBase(String base) {
    final absolute = p.normalize(p.absolute(base));
    var existing = absolute;
    final missing = <String>[];
    while (FileSystemEntity.typeSync(existing) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(existing);
      if (parent == existing) break;
      missing.insert(0, p.basename(existing));
      existing = parent;
    }
    final String resolved;
    try {
      resolved = Directory(existing).resolveSymbolicLinksSync();
    } on FileSystemException {
      return absolute;
    }
    return missing.isEmpty ? resolved : p.joinAll([resolved, ...missing]);
  }

  /// The components of [target] below [base], or an [UnsafePathException] if
  /// it is not below it.
  static List<String> _below(String base, String target) {
    final from = p.normalize(p.absolute(base));
    final to = p.normalize(p.absolute(target));
    final relative = p.relative(to, from: from);
    if (relative == '.') return const [];
    if (p.isAbsolute(relative) ||
        relative == '..' ||
        relative.startsWith('..${p.separator}')) {
      throw UnsafePathException(target, 'it is outside the destination');
    }
    return p.split(relative);
  }

  /// Checks that nothing between [base] and [target] is a link.
  ///
  /// Every existing component from [base] down to the folder that holds
  /// [target] is looked at *without* following links: a link, or anything that
  /// is not a folder, throws [UnsafePathException]. Components that do not
  /// exist yet are fine — they will be created as real folders. [target]
  /// itself is looked at only with [includeTarget].
  ///
  /// [base] is the user's own choice and is resolved, not checked.
  static void assertNoLinksBelow(
    String base,
    String target, {
    bool includeTarget = false,
  }) {
    final parts = _below(base, target);
    final canonical = canonicalBase(base);
    final checked = includeTarget ? parts.length : parts.length - 1;

    var current = canonical;
    for (var i = 0; i < checked; i++) {
      final next = p.join(current, parts[i]);
      switch (FileSystemEntity.typeSync(next, followLinks: false)) {
        case FileSystemEntityType.notFound:
          return; // nothing deeper exists, so nothing deeper can be a link
        case FileSystemEntityType.link:
          throw UnsafePathException(
              target, '"${p.relative(next, from: canonical)}" is a symbolic link');
        case FileSystemEntityType.directory:
          current = next;
        default:
          if (includeTarget && i == parts.length - 1) {
            current = next;
            break;
          }
          throw UnsafePathException(target,
              '"${p.relative(next, from: canonical)}" is not a folder');
      }
    }

    // Belt and braces: whatever the deepest real folder resolves to must
    // still be where the walk says it is.
    if (current != canonical) {
      final String resolved;
      try {
        resolved = Directory(current).resolveSymbolicLinksSync();
      } on FileSystemException {
        return;
      }
      if (resolved != current && !p.isWithin(canonical, resolved)) {
        throw UnsafePathException(target, 'it resolves outside the destination');
      }
    }
  }

  /// [relativePath], as a sender names it, resolved under [baseDir].
  ///
  /// The lexical cleaning of [PathSanitizer.resolveSafePath] plus the part it
  /// cannot do: the result must not go through a link that is already there.
  /// Rejects an empty or relative [baseDir] — a relative one would resolve
  /// against the process's working directory, which is not the destination.
  static String resolve(
    String relativePath,
    String baseDir, {
    String defaultName = 'item',
  }) {
    if (baseDir.isEmpty || !p.isAbsolute(baseDir)) {
      throw Exception('Receive directory is not set (got "$baseDir")');
    }
    final resolved = PathSanitizer.resolveSafePath(relativePath, baseDir,
        defaultName: defaultName);
    assertNoLinksBelow(baseDir, resolved);
    return resolved;
  }

  /// Windows paths: refuses one that classic Win32 would not open.
  ///
  /// [os] is for tests; it defaults to the platform this runs on, and every
  /// platform but Windows has no such limit worth enforcing here.
  static void assertPathLength(String path, {String? os}) {
    if ((os ?? _operatingSystem) != 'windows') return;
    if (path.length >= windowsMaxPath) {
      throw PathTooLongException(path, windowsMaxPath);
    }
  }

  /// Whether [assertPathLength] has anything to enforce on this platform.
  static bool get enforcesPathLength => _operatingSystem == 'windows';

  /// Test hook: the system the path-length rule goes by, so what a receiver
  /// does with a path Windows would not open can be tested on a machine that
  /// is not one. Null in production.
  @visibleForTesting
  static String? debugOperatingSystem;

  static String get _operatingSystem =>
      debugOperatingSystem ?? Platform.operatingSystem;

  // --- creating --------------------------------------------------------------

  /// Creates the folders above [target] that do not exist, one real folder
  /// at a time, never through a link.
  ///
  /// `Directory.create(recursive: true)` follows whatever it meets. Here every
  /// component is looked at without following links, created if missing, and
  /// looked at again afterwards — so a link swapped in between is caught.
  static void ensureParents(String base, String target) {
    assertNoLinksBelow(base, target);
    final canonical = canonicalBase(base);
    if (FileSystemEntity.typeSync(canonical, followLinks: false) ==
        FileSystemEntityType.notFound) {
      Directory(canonical).createSync(recursive: true);
    }
    var current = canonical;
    for (final part in _below(base, p.dirname(target))) {
      current = p.join(current, part);
      var type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        raceWindow('mkdir', current);
        try {
          Directory(current).createSync();
        } on FileSystemException {
          // Raced another creator; what matters is what is there now.
        }
        type = FileSystemEntity.typeSync(current, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw UnsafePathException(
            target, '"${p.relative(current, from: canonical)}" is not a folder');
      }
    }
  }

  /// Test hook: make new files the way Windows needs them made (see
  /// [createExclusive]) on any system, so the logic that only Windows runs is
  /// run by a machine that is not one.
  @visibleForTesting
  static bool debugCreateViaScratch = false;

  /// Makes a new, empty file at [path], and refuses — never follows — whatever
  /// is already at that name: a file, a folder, or a link, even one pointing at
  /// nothing. Throws [PathTakenException] for those.
  ///
  /// On POSIX that is one call: `open(O_CREAT | O_EXCL)` fails with EEXIST for
  /// a link at the name, a dangling one included. Windows' `CreateFile` with
  /// `CREATE_NEW` does not: it follows a link standing at the name and, when
  /// the link leads nowhere, creates what it leads to — an empty file outside
  /// the destination — and reports success. Dart cannot ask for the link
  /// itself to be opened (there is no `FILE_FLAG_OPEN_REPARSE_POINT`), and
  /// looking first leaves the gap this exists to close.
  ///
  /// So there the file is made under a name nobody can have prepared (ten
  /// random hex digits, in the folder that was just checked) and then moved to
  /// [path] by [renameNoClobber], which looks at the name without following
  /// links and refuses anything there. A link that turns up in the instant
  /// between that look and the move is replaced by the move, not written
  /// through: a rename acts on the name, not on what the name leads to.
  static void createExclusive(String path) {
    if (!(Platform.isWindows || debugCreateViaScratch)) {
      try {
        File(path).createSync(exclusive: true);
      } on FileSystemException {
        if (exists(path)) throw PathTakenException(path);
        rethrow;
      }
      return;
    }

    final scratch = p.join(p.dirname(path), '${_randomHex(10)}.qs.partial');
    assertPathLength(scratch);
    final made = File(scratch)..createSync(exclusive: true);
    try {
      for (var attempt = 1;; attempt++) {
        try {
          renameNoClobber(scratch, path);
          return;
        } on PathTakenException {
          rethrow;
        } on FileSystemException {
          // A scanner or indexer looking at a file the instant it appeared
          // refuses the move for a moment; anything still refusing after a
          // few tries is a refusal.
          if (attempt == 4) rethrow;
          sleep(Duration(milliseconds: 25 * attempt));
        }
      }
    } catch (_) {
      try {
        made.deleteSync();
      } on FileSystemException {
        // The next sweep clears it: it carries the partial suffix.
      }
      rethrow;
    }
  }

  static String _randomHex(int digits) {
    final random = Random.secure();
    return List.generate(digits, (_) => random.nextInt(16).toRadixString(16))
        .join();
  }

  /// A scratch file proving [dir] can be written to, made the way a received
  /// file is: exclusively, so a link named like it is not written through.
  static void probeWritable(String dir) {
    final name = '.qs_write_probe_${Random.secure().nextInt(1 << 31)}';
    final probe = File(p.join(dir, name))..createSync(exclusive: true);
    try {
      probe.writeAsBytesSync(const [0]);
    } finally {
      probe.deleteSync();
    }
  }

  // --- the partial file ------------------------------------------------------

  /// How many bytes of a partial are on disk, validated.
  ///
  /// A link where the partial goes is not a partial: its target's length is
  /// not ours to count, so the link itself (never its target) is removed and
  /// the answer is 0. A folder there is refused, not deleted.
  static int partialLength(String base, String partialPath) {
    assertNoLinksBelow(base, partialPath);
    switch (FileSystemEntity.typeSync(partialPath, followLinks: false)) {
      case FileSystemEntityType.notFound:
        return 0;
      case FileSystemEntityType.link:
        Link(partialPath).deleteSync();
        AppLogger.warning(
            'Removed a symbolic link standing where a partial file goes: '
            '$partialPath',
            tag: 'DISK');
        return 0;
      case FileSystemEntityType.file:
        return File(partialPath).lengthSync();
      default:
        throw UnsafePathException(
            partialPath, 'something other than a file is in the way');
    }
  }

  /// Opens [partialPath] for writing and never through a link.
  ///
  /// The file is created exclusively (`O_EXCL`: refused if *anything* is
  /// there, a dangling link included), opened for append — which does not
  /// truncate — and only then, after the path has been looked at once more,
  /// emptied if [truncate]. A resume passes `truncate: false` and writes from
  /// the end.
  static RandomAccessFile openPartial(
    String base,
    String partialPath, {
    required bool truncate,
  }) {
    assertPathLength(partialPath);
    ensureParents(base, partialPath);

    var type = FileSystemEntity.typeSync(partialPath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      Link(partialPath).deleteSync();
      AppLogger.warning(
          'Replaced a symbolic link standing where a partial file goes: '
          '$partialPath',
          tag: 'DISK');
      type = FileSystemEntityType.notFound;
    }
    if (type == FileSystemEntityType.notFound) {
      raceWindow('create', partialPath);
      try {
        createExclusive(partialPath);
      } on PathTakenException {
        throw UnsafePathException(
            partialPath, 'it appeared while it was being created');
      } on FileSystemException {
        throw UnsafePathException(
            partialPath, 'it appeared while it was being created');
      }
    } else if (type != FileSystemEntityType.file) {
      throw UnsafePathException(
          partialPath, 'something other than a file is in the way');
    }

    raceWindow('open', partialPath);
    final raf = File(partialPath).openSync(mode: FileMode.append);
    try {
      // The open happened; make sure it was the file we looked at.
      assertNoLinksBelow(base, partialPath);
      if (FileSystemEntity.typeSync(partialPath, followLinks: false) !=
          FileSystemEntityType.file) {
        throw UnsafePathException(partialPath, 'it changed while opening');
      }
      final resolved = File(partialPath).resolveSymbolicLinksSync();
      if (!p.isWithin(canonicalBase(base), resolved)) {
        throw UnsafePathException(
            partialPath, 'it resolves outside the destination');
      }
      if (truncate) {
        raf.truncateSync(0);
        // An append handle is positioned at the old end; without this the
        // next write leaves a hole of zeros in front of itself.
        raf.setPositionSync(0);
      }
      return raf;
    } catch (_) {
      raf.closeSync();
      rethrow;
    }
  }

  // --- cleaning up -----------------------------------------------------------

  /// Removes what a failed attempt left at [path] — and, whatever it finds,
  /// nothing outside [base].
  ///
  /// `FileSystemEntity.typeSync(path, followLinks: false)` looks at the *last*
  /// component without following a link. The folders above it are followed like
  /// any others, and so is the delete that comes after: a folder swapped for a
  /// link while the partial was being written makes `File(path).delete()`
  /// remove the file of that name from wherever the link points. All it takes
  /// is the same file name — a `.qs.partial` of another transfer, say, which is
  /// exactly what a sender-chosen name can aim at.
  ///
  /// So every folder between [base] and [path] is looked at first, without
  /// following links, the way the rest of this class looks before it writes or
  /// renames. When one of them is a link, or [path] is not under [base] at all,
  /// nothing is deleted: the file stays where it is, a line in the log says
  /// which and why, and [false] comes back. A leftover partial is debris — the
  /// startup sweep (`sweepPartials`) clears it on a later receive, if nothing
  /// is in the way of it getting there — but deleting a stranger's file to get
  /// rid of it would be a much worse thing to have done.
  ///
  /// What is at [path] itself may be a file or a link — a link is removed as a
  /// link, never its target. A folder is left alone (this is for files).
  ///
  /// **Never throws.** This runs after something has already gone wrong, and the
  /// error that reaches the person has to be that one, not a complaint about
  /// the tidying. A delete the system refuses (Windows holding a file an
  /// indexer is reading) is logged and the file stays, like the case above.
  ///
  /// The check and the delete are two calls, made one after the other with
  /// nothing between them; like every check in this class they cannot out-run
  /// somebody who already controls the folder and wins a race of microseconds
  /// (see the class comment).
  ///
  /// [base] null stands for the folder that holds [path], as in `DurableFile`:
  /// the file itself is protected, the folders above it are not looked at.
  ///
  /// Returns whether the name is free afterwards.
  static bool discard(String? base, String path) {
    try {
      final root = (base == null || base.isEmpty) ? p.dirname(path) : base;
      assertNoLinksBelow(root, path);
      switch (FileSystemEntity.typeSync(path, followLinks: false)) {
        case FileSystemEntityType.notFound:
          return true;
        case FileSystemEntityType.file:
          File(path).deleteSync();
          return true;
        case FileSystemEntityType.link:
          Link(path).deleteSync();
          return true;
        default:
          AppLogger.warning(
              'Left "$path" in place: it is not a file, so it is not a '
              'partial of ours',
              tag: 'DISK');
          return false;
      }
    } on UnsafePathException catch (e) {
      AppLogger.warning(
          'Left "$path" in place instead of deleting it: ${e.reason}. '
          'Nothing outside the destination was touched; the file stays on '
          'disk until it is removed by hand',
          tag: 'DISK');
      return false;
    } catch (e) {
      AppLogger.warning('Could not remove "$path": $e — it stays where it is',
          tag: 'DISK');
      return false;
    }
  }

  // --- the last step ---------------------------------------------------------

  static const int _maxCommitAttempts = 64;

  /// Gives a finished partial its real name, replacing nothing.
  ///
  /// The chain is checked again first (a folder may have been swapped for a
  /// link since the partial was opened), the partial must still be a regular
  /// file, and the rename refuses to replace. If the name was taken in the
  /// meantime the next free `name (n).ext` is used. Returns the path the file
  /// actually has, which the caller must record.
  ///
  /// [base] null is for callers with no destination to check against (a test,
  /// an old call site); the link and no-replace guarantees on the file itself
  /// still hold.
  static String commitFile(String? base, String partialPath, String finalPath) {
    raceWindow('seal', partialPath);
    assertPathLength(finalPath);
    if (base != null) {
      assertNoLinksBelow(base, finalPath);
      assertNoLinksBelow(base, partialPath);
    }
    if (FileSystemEntity.typeSync(partialPath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw UnsafePathException(
          partialPath, 'the partial file is no longer a regular file');
    }

    var target = finalPath;
    for (var attempt = 0; attempt < _maxCommitAttempts; attempt++) {
      try {
        renameNoClobber(partialPath, target);
        return target;
      } on PathTakenException {
        target = uniquePath(finalPath);
        AppLogger.info(
            '$finalPath was taken while it was being received; '
            'using $target',
            tag: 'DISK');
      }
    }
    throw PathTakenException(target);
  }

  /// Gives a staged folder its real name, replacing nothing — not even an
  /// empty folder, which a plain `rename` would. Same contract as
  /// [commitFile]: returns the path the folder actually has.
  static String commitDirectory(
      String? base, String stagedPath, String finalPath) {
    assertPathLength(finalPath);
    if (base != null) {
      assertNoLinksBelow(base, finalPath);
      assertNoLinksBelow(base, stagedPath);
    }
    if (FileSystemEntity.typeSync(stagedPath, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw UnsafePathException(
          stagedPath, 'the staging folder is no longer a real folder');
    }

    var target = finalPath;
    for (var attempt = 0; attempt < _maxCommitAttempts; attempt++) {
      try {
        renameDirectoryNoClobber(stagedPath, target);
        return target;
      } on PathTakenException {
        target = uniquePath(finalPath);
        AppLogger.info(
            '$finalPath was taken while it was being received; '
            'using $target',
            tag: 'DISK');
      }
    }
    throw PathTakenException(target);
  }

  /// Moves [from] to [to] and throws [PathTakenException] instead of
  /// replacing whatever is already there.
  ///
  /// On POSIX this is `link(2)` then `unlink(2)`: `link` is atomic and fails
  /// with EEXIST for anything at [to], a dangling link included, so there is
  /// no window between "is it free?" and "take it". Where the filesystem has
  /// no hard links (exFAT, SMB shares, some Android volumes) `link` fails for
  /// another reason and this falls back to "look without following links,
  /// then rename" — which leaves a gap of microseconds in which a file could
  /// appear at [to]. On Windows there is only that fallback: `File.rename`
  /// replaces by design, and the guard is the look just before it.
  static void renameNoClobber(String from, String to) {
    if (!Platform.isWindows && !debugDisableHardLinks) {
      final posix = _Posix.instance;
      if (posix != null) {
        final source = from.toNativeUtf8();
        final destination = to.toNativeUtf8();
        try {
          if (posix.link(source, destination) == 0) {
            if (posix.unlink(source) != 0) {
              // Both names now hold the whole file, which is safe; the
              // leftover partial name is debris the next sweep clears.
              try {
                File(from).deleteSync();
              } on FileSystemException catch (e) {
                AppLogger.warning(
                    'Could not remove $from after linking it to $to: $e',
                    tag: 'DISK');
              }
            }
            return;
          }
        } finally {
          malloc.free(source);
          malloc.free(destination);
        }
        // `link` failed. EEXIST is the case that matters; the others mean
        // this volume cannot hard-link, and the fallback below copes.
        if (exists(to)) throw PathTakenException(to);
      }
    }
    if (exists(to)) throw PathTakenException(to);
    _noteFallback(to);
    File(from).renameSync(to);
  }

  /// Folder version of [renameNoClobber]. POSIX `rename` replaces an *empty*
  /// folder, so the name is claimed first with `mkdir(2)` — atomic, EEXIST for
  /// anything there — and the staged folder is renamed onto the empty one just
  /// made. Windows cannot rename a folder onto an existing one at all, so
  /// there the look-then-rename gap is the whole guard.
  static void renameDirectoryNoClobber(String from, String to) {
    if (!Platform.isWindows && !debugDisableHardLinks) {
      final posix = _Posix.instance;
      if (posix != null) {
        final destination = to.toNativeUtf8();
        final int made;
        try {
          made = posix.mkdir(destination, 511); // 0777, less the umask
        } finally {
          malloc.free(destination);
        }
        if (made == 0) {
          try {
            Directory(from).renameSync(to);
          } catch (_) {
            // Remove only the empty folder just made; never a full one.
            try {
              Directory(to).deleteSync();
            } on FileSystemException {
              // Somebody put something in it; leave it.
            }
            rethrow;
          }
          return;
        }
        if (exists(to)) throw PathTakenException(to);
      }
    }
    if (exists(to)) throw PathTakenException(to);
    _noteFallback(to);
    Directory(from).renameSync(to);
  }
}

// --- libc ----------------------------------------------------------------

typedef _LinkNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _LinkDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _UnlinkNative = Int32 Function(Pointer<Utf8>);
typedef _UnlinkDart = int Function(Pointer<Utf8>);
typedef _MkdirNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _MkdirDart = int Function(Pointer<Utf8>, int);

/// libc `link`/`unlink`/`mkdir`, looked up once, the way durable_file looks up
/// `fsync`. Null where the lookup fails.
class _Posix {
  _Posix._(this.link, this.unlink, this.mkdir);

  final _LinkDart link;
  final _UnlinkDart unlink;
  final _MkdirDart mkdir;

  static bool _resolved = false;
  static _Posix? _cached;

  static _Posix? get instance {
    if (_resolved) return _cached;
    _resolved = true;
    if (Platform.isWindows) return null;
    try {
      final lib = DynamicLibrary.process();
      _cached = _Posix._(
        lib.lookupFunction<_LinkNative, _LinkDart>('link'),
        lib.lookupFunction<_UnlinkNative, _UnlinkDart>('unlink'),
        lib.lookupFunction<_MkdirNative, _MkdirDart>('mkdir'),
      );
    } catch (e) {
      AppLogger.warning('libc link/mkdir bindings unavailable: $e', tag: 'DISK');
      _cached = null;
    }
    return _cached;
  }
}

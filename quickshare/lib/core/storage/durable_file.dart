import 'dart:collection';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/safe_path.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// The suffix every in-flight received file carries until it is whole.
///
/// One marker on every channel — WebRTC, BLE, QHTP — so a single sweep can
/// recognise and clear the debris a crashed transfer leaves behind. Not
/// `.tmp`: the OS, antivirus tools and other programs all treat `.tmp` as
/// theirs to clean, and a shared convention is one we could not tell our own
/// leftovers apart from — a sweep might then delete someone else's file.
const String kPartialSuffix = '.qs.partial';

/// Whether [path] is one of our in-flight partials.
bool isPartialPath(String path) => path.endsWith(kPartialSuffix);

/// The file that marks a `.qs.partial` folder as worth keeping.
///
/// A staged folder is normally debris if it outlives its transfer. The one
/// that is not is a folder received in full whose rename onto its real name
/// failed: it is the only copy, and the person was told where it is. The
/// startup sweep leaves a folder with this file in it alone.
const String kKeptMarker = '.qs.kept';

/// A crash-safe write of a single file.
///
/// In the default (staged) mode bytes stream into `<finalPath>.qs.partial`;
/// [commit] fsyncs that data, renames it onto [finalPath] in one atomic step,
/// then fsyncs the containing directory so the rename itself survives a power
/// cut. A reader therefore only ever sees the whole file under its real name,
/// or nothing — never a half-written file wearing the final name.
///
/// `DurableFile(path, staged: false)` writes straight to [finalPath] with no
/// rename — for a file that lives inside a folder being staged as a whole
/// (`Trip.qs.partial/`), where the enclosing directory's rename is the atomic
/// gate and a per-file one would be redundant. [commit] there is just an
/// fsync-and-close.
///
/// Neither mode ever writes through a symbolic link or replaces a file: see
/// [SafePath]. [base] is the destination folder the user chose; every folder
/// between it and the file is checked, at open and again at commit. Without
/// one, the file's own folder stands in for it, which still protects the file
/// itself but not the folders above it.
class DurableFile {
  DurableFile(this.finalPath, {this.staged = true, this.base});

  /// Where the caller wants the file. If that name is taken by commit time,
  /// [commit] uses the next free `name (n).ext` and returns it.
  final String finalPath;
  final bool staged;
  final String? base;

  /// Where bytes actually land before [commit].
  String get partialPath => staged ? '$finalPath$kPartialSuffix' : finalPath;

  RandomAccessFile? _raf;
  String? _committedPath;

  /// The write most recently handed to the handle, as a future that never
  /// fails (a failed write is its caller's to deal with). [abort] waits for it:
  /// a handle with an operation pending refuses to close — the call returns an
  /// error and the handle stays open — so closing under a running write, which
  /// is what an abort from a timer or a dropped connection does, left the
  /// file open and, on Windows, undeletable.
  Future<void> _writing = Future<void>.value();

  String get _root => base ?? p.dirname(finalPath);

  /// Creates the parent directory if missing and opens the write target,
  /// truncating anything an earlier failed attempt left there — WebRTC and BLE
  /// have no resume, so a stale partial is dead weight.
  Future<void> open() async {
    _raf = SafePath.openPartial(_root, partialPath, truncate: true);
  }

  /// Bytes written to the target so far.
  int get length => _raf?.lengthSync() ?? 0;

  /// The open handle, for a test that has to ask it afterwards whether it was
  /// closed.
  @visibleForTesting
  RandomAccessFile? get handleForTesting => _raf;

  Future<void> add(List<int> bytes) {
    final raf = _raf;
    if (raf == null) {
      throw StateError(
          'DurableFile.add on $finalPath before open() / after commit()');
    }
    final write = raf.writeFrom(bytes);
    _writing = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  /// Puts everything written so far on the device and says how many bytes the
  /// file holds. A transfer that has to be picked up again reports that number
  /// to the sender, so it is the number of bytes that are really there, not the
  /// number that were handed to a write.
  Future<int> sync() async {
    final raf = _raf;
    if (raf == null) {
      throw StateError('DurableFile.sync on $finalPath before open() / after commit()');
    }
    await _writing;
    await raf.flush();
    return raf.lengthSync();
  }

  /// fsync payload → close → (staged) atomic rename → fsync directory.
  /// Idempotent once it has succeeded. Returns the path the file now has,
  /// which is [finalPath] unless that name was taken meanwhile.
  Future<String> commit() async {
    final done = _committedPath;
    if (done != null) return done;
    final raf = _raf;
    if (raf == null) {
      throw StateError('DurableFile.commit on $finalPath without open()');
    }
    await raf.flush(); // flushes Dart buffer to the OS
    await raf.close();
    _raf = null;
    await syncFile(partialPath); // fsync payload bytes onto the physical device
    var path = finalPath;
    if (staged) {
      path = SafePath.commitFile(_root, partialPath, finalPath);
      await syncDirectory(p.dirname(path));
    }
    _committedPath = path;
    return path;
  }

  /// Closes the handle and removes what was written. Safe to call repeatedly,
  /// and a no-op once [commit] has succeeded.
  ///
  /// A write still running is waited for first, and the handle is released from
  /// this object before the wait: a second [abort] then finds nothing to close
  /// (not a handle already shutting), and an [add] that comes in meanwhile
  /// fails fast instead of writing into a file that is being thrown away.
  Future<void> abort() async {
    final raf = _raf;
    _raf = null;
    await _writing;
    try {
      await raf?.close();
    } catch (_) {}
    if (_committedPath != null) return;
    // Whatever is at this path now — a file, or a link someone put there —
    // goes: a link is unlinked, its target is never reached. But only if no
    // folder above it has become a link in the meantime: the delete would
    // follow it and remove a file of that name from wherever it points. When
    // one has, the file stays, the log says so, and this still returns
    // normally — the caller is reporting an error of its own, and a failed
    // cleanup must not replace it. See [SafePath.discard].
    SafePath.discard(_root, partialPath);
  }
}

/// Atomically commits a directory that was staged under a `.qs.partial` name.
///
/// A folder travels as a folder, and a half-populated `Trip/` the user opens
/// mid-transfer — half the photos there, the other half not — is worse than
/// one that appears complete or not at all. So the whole tree is written to
/// `Trip.qs.partial/` and renamed in one step when the last byte lands.
///
/// A name that is already taken — by a folder, even an empty one, a file or a
/// link — is never replaced: the folder lands as `Trip (1)` instead, and the
/// path it actually has is returned. [base], when given, is the destination
/// folder the chain is re-checked against just before the rename.
Future<String> commitDirectory(String stagedPath, String finalPath,
    {String? base}) async {
  final path = SafePath.commitDirectory(base, stagedPath, finalPath);
  await syncDirectory(p.dirname(path));
  return path;
}

// --- directory fsync (POSIX only) ------------------------------------------

typedef _OpenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenDart = int Function(Pointer<Utf8>, int);
typedef _FdNative = Int32 Function(Int32);
typedef _FdDart = int Function(int);

/// libc `open`/`fsync`/`close`, looked up once. Null when the lookup fails or
/// on a platform we do not sync directories on.
class _LibC {
  _LibC._(this.open, this.fsync, this.close);

  final _OpenDart open;
  final _FdDart fsync;
  final _FdDart close;

  static bool _resolved = false;
  static _LibC? _cached;

  static _LibC? get instance {
    if (_resolved) return _cached;
    _resolved = true;
    if (Platform.isWindows) return null;
    try {
      final lib = DynamicLibrary.process();
      _cached = _LibC._(
        lib.lookupFunction<_OpenNative, _OpenDart>('open'),
        lib.lookupFunction<_FdNative, _FdDart>('fsync'),
        lib.lookupFunction<_FdNative, _FdDart>('close'),
      );
    } catch (e) {
      AppLogger.warning('libc fsync bindings unavailable: $e', tag: 'DISK');
      _cached = null;
    }
    return _cached;
  }
}

// O_RDONLY is 0 on both Linux and macOS.
const int _oRdonly = 0;

/// fsyncs the directory at [dirPath] so a rename into it survives power loss.
///
/// Best-effort: if it fails, the only exposure is a committed file sitting
/// under its `.qs.partial` name after a hard crash, which the next launch
/// sweeps or (for QHTP) resumes. A no-op on Windows — flushing a directory
/// handle is not generally supported there, and `FlushFileBuffers` on one
/// fails.
Future<void> syncDirectory(String dirPath) async {
  final libc = _LibC.instance;
  if (libc == null) return;
  final ptr = dirPath.toNativeUtf8();
  try {
    final fd = libc.open(ptr, _oRdonly);
    if (fd < 0) return;
    try {
      libc.fsync(fd);
    } finally {
      libc.close(fd);
    }
  } catch (e) {
    AppLogger.warning('syncDirectory($dirPath) failed: $e', tag: 'DISK');
  } finally {
    malloc.free(ptr);
  }
}

/// fsyncs the file at [filePath] so bytes reach physical storage before rename.
Future<void> syncFile(String filePath) async {
  final libc = _LibC.instance;
  if (libc == null) return;
  final ptr = filePath.toNativeUtf8();
  try {
    final fd = libc.open(ptr, _oRdonly);
    if (fd < 0) return;
    try {
      libc.fsync(fd);
    } finally {
      libc.close(fd);
    }
  } catch (e) {
    AppLogger.warning('syncFile($filePath) failed: $e', tag: 'DISK');
  } finally {
    malloc.free(ptr);
  }
}

// --- startup sweep --------------------------------------------------------

/// Removes stale `*.qs.partial` debris under [root], at any depth up to
/// [maxDepth] folders down.
///
/// "Stale" means last modified before [before]. At startup every partial on
/// disk belongs to an earlier run, so the caller passes a cutoff of roughly
/// "now" — on desktop with a small margin, since another copy of the app may
/// be mid-transfer into the same folder. Returns the bytes reclaimed.
///
/// Two kinds of partial are not debris and are left alone however old:
///
///  * those in [pinned] — absolute paths a transfer may still resume. QHTP
///    keeps a partial across runs on purpose, and tells the user so;
///  * a folder holding a [kKeptMarker] file: a folder received in full whose
///    rename onto its real name failed, which is the only copy there is.
///
/// ## Going down
///
/// A folder received over QHTP lands as `Trip/clip.bin`, and while it arrives
/// as `Trip/clip.bin.qs.partial`, so what an abandoned folder session leaves is
/// one or more folders down; looking at the top level alone left it for ever.
/// So the folders under [root] are walked, breadth first, with limits that keep
/// a Downloads folder of tens of thousands of files from costing a transfer its
/// start:
///
///  * [maxDepth] folders below [root], and
///  * [maxEntries] entries looked at below the top level, after which the walk
///    stops and says so in the log. The top level itself is always done in
///    full, as it always was.
///
/// What going down must not do, and does not:
///
///  * **Follow a link.** A link is never entered, whatever it points at and
///    whatever it is named, and a partial is deleted only after every folder
///    between [root] and it has been looked at again (the walk and the delete
///    are two moments, and a folder can be swapped between them). One that is
///    now a link leaves the file where it is, with a line in the log.
///  * **Take what is wanted.** [pinned], [kKeptMarker] and the cutoff apply at
///    every depth exactly as at the top. A partial inside a staged
///    `*.qs.partial` folder is not looked at on its own: the folder is the
///    unit, kept or removed whole.
///  * **Take what is not ours.** Only a name that ends in `.qs.partial` is
///    considered. Everything else, files and folders, is walked past.
///
/// Whatever is left unswept because of a limit stays until the next sweep or
/// until somebody removes it; it is debris, not a hazard.
Future<int> sweepPartials(
  String root, {
  required DateTime before,
  Set<String> pinned = const {},
  int maxDepth = 12,
  int maxEntries = 20000,
}) async {
  final top = Directory(root);
  if (!await top.exists()) return 0;

  final keep = {for (final path in pinned) _sweepKey(path)};
  var freed = 0;
  var looked = 0;
  var stoppedEarly = false;

  // Folders still to read, with how far down each is. A queue, not recursion:
  // a deep tree must not be a deep call stack, and breadth first means the
  // shallow folders — where a received folder's files are — are done before a
  // budget can run out in the deep ones.
  final queue = Queue<(String, int)>()..add((root, 0));
  while (queue.isNotEmpty) {
    final (current, depth) = queue.removeFirst();

    List<FileSystemEntity> entries;
    try {
      entries = await Directory(current).list(followLinks: false).toList();
    } on FileSystemException {
      continue; // not readable, or gone since it was seen: nothing to sweep
    }

    for (final entry in entries) {
      if (depth > 0 && ++looked > maxEntries) {
        stoppedEarly = true;
        break;
      }
      // A link that happens to be named like one of ours is somebody else's
      // business; it is never followed and never counted. Nor is a link to a
      // folder walked into.
      if (entry is Link) continue;

      if (isPartialPath(entry.path)) {
        freed += await _sweepOne(root, entry, before, keep);
        continue; // a staged folder is one unit; its insides are not walked
      }
      if (entry is Directory && depth < maxDepth) {
        queue.add((entry.path, depth + 1));
      }
    }
    if (stoppedEarly) break;
  }

  if (stoppedEarly) {
    AppLogger.info(
        'Partial sweep of $root stopped after $maxEntries entries below the '
        'top level; what is further on is left for a later sweep',
        tag: 'DISK');
  }
  if (freed > 0) {
    AppLogger.info(
        'Swept $freed bytes of interrupted-transfer debris from $root',
        tag: 'DISK');
  }
  return freed;
}

/// Removes one entry named like a partial, if it is stale and not wanted.
/// Returns the bytes freed.
Future<int> _sweepOne(String root, FileSystemEntity entry, DateTime before,
    Set<String> keep) async {
  if (keep.contains(_sweepKey(entry.path))) return 0;
  try {
    final stat = await entry.stat();
    if (stat.modified.isAfter(before)) return 0;
    // Looked at again, now, from the root down: the walk saw these folders a
    // moment ago and they may not be what they were.
    SafePath.assertNoLinksBelow(root, entry.path);
    if (stat.type == FileSystemEntityType.directory) {
      if (FileSystemEntity.typeSync(p.join(entry.path, kKeptMarker),
              followLinks: false) ==
          FileSystemEntityType.file) {
        return 0;
      }
      final size = await _treeSize(Directory(entry.path));
      await Directory(entry.path).delete(recursive: true);
      return size;
    }
    await File(entry.path).delete();
    return stat.size;
  } on UnsafePathException catch (e) {
    AppLogger.warning(
        'Left "${entry.path}" in place instead of sweeping it: ${e.reason}. '
        'Nothing outside the destination was touched',
        tag: 'DISK');
  } on FileSystemException {
    // Raced another sweep, or the OS reclaimed it first; nothing to free.
  }
  return 0;
}

/// A path as the sweep compares it: absolute and normalised, and without case
/// on Windows, where `Video.bin` and `video.bin` are one file.
String _sweepKey(String path) {
  final absolute = p.normalize(p.absolute(path));
  return Platform.isWindows ? absolute.toLowerCase() : absolute;
}

Future<int> _treeSize(Directory dir) async {
  var total = 0;
  try {
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } on FileSystemException {
          // Vanished between listing and measuring.
        }
      }
    }
  } on FileSystemException {
    // Partial measurement is fine — this only feeds a log line.
  }
  return total;
}

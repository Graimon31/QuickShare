import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

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
class DurableFile {
  DurableFile(this.finalPath, {this.staged = true});

  final String finalPath;
  final bool staged;

  /// Where bytes actually land before [commit].
  String get partialPath => staged ? '$finalPath$kPartialSuffix' : finalPath;

  RandomAccessFile? _raf;
  bool _committed = false;

  /// Creates the parent directory if missing and opens the write target,
  /// truncating anything an earlier failed attempt left there — WebRTC and BLE
  /// have no resume, so a stale partial is dead weight.
  Future<void> open() async {
    final parent = Directory(p.dirname(finalPath));
    if (!parent.existsSync()) parent.createSync(recursive: true);
    _raf = await File(partialPath).open(mode: FileMode.writeOnly);
  }

  /// Bytes written to the target so far.
  int get length => _raf?.lengthSync() ?? 0;

  Future<void> add(List<int> bytes) {
    final raf = _raf;
    if (raf == null) {
      throw StateError(
          'DurableFile.add on $finalPath before open() / after commit()');
    }
    return raf.writeFrom(bytes);
  }

  /// fsync payload → close → (staged) atomic rename → fsync directory.
  /// Idempotent once it has succeeded. Returns [finalPath].
  Future<String> commit() async {
    if (_committed) return finalPath;
    final raf = _raf;
    if (raf == null) {
      throw StateError('DurableFile.commit on $finalPath without open()');
    }
    await raf.flush(); // fsync the bytes onto the device
    await raf.close();
    _raf = null;
    if (staged) {
      await File(partialPath).rename(finalPath);
      await syncDirectory(p.dirname(finalPath));
    }
    _committed = true;
    return finalPath;
  }

  /// Closes the handle and removes what was written. Safe to call repeatedly,
  /// and a no-op once [commit] has succeeded.
  Future<void> abort() async {
    try {
      await _raf?.close();
    } catch (_) {}
    _raf = null;
    if (_committed) return;
    try {
      final f = File(partialPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// Atomically commits a directory that was staged under a `.qs.partial` name.
///
/// A folder travels as a folder, and a half-populated `Trip/` the user opens
/// mid-transfer — half the photos there, the other half not — is worse than
/// one that appears complete or not at all. So the whole tree is written to
/// `Trip.qs.partial/` and renamed in one step when the last byte lands.
///
/// The rename is atomic only when the destination does not yet exist; if it
/// does, the caller has already fallen back to writing files into it
/// individually and should not be here.
Future<void> commitDirectory(String stagedPath, String finalPath) async {
  await Directory(stagedPath).rename(finalPath);
  await syncDirectory(p.dirname(finalPath));
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

// --- startup sweep --------------------------------------------------------

/// Removes stale `*.qs.partial` debris sitting directly under [root].
///
/// "Stale" means last modified before [before]. At startup every partial on
/// disk belongs to an earlier run, so the caller passes a cutoff of roughly
/// "now" — on desktop with a small margin, since another copy of the app may
/// be mid-transfer into the same folder. Returns the bytes reclaimed.
///
/// Top level only: a fast scan that catches the ordinary cases (a loose
/// `video.mp4.qs.partial`, a staged `Trip.qs.partial/`) without walking a
/// Downloads folder that may hold tens of thousands of files.
Future<int> sweepPartials(String root, {required DateTime before}) async {
  final dir = Directory(root);
  if (!await dir.exists()) return 0;

  List<FileSystemEntity> entries;
  try {
    entries = await dir.list(followLinks: false).toList();
  } on FileSystemException {
    return 0;
  }

  var freed = 0;
  for (final entry in entries) {
    if (!isPartialPath(entry.path)) continue;
    try {
      final stat = await entry.stat();
      if (stat.modified.isAfter(before)) continue;
      if (stat.type == FileSystemEntityType.directory) {
        freed += await _treeSize(Directory(entry.path));
        await Directory(entry.path).delete(recursive: true);
      } else {
        freed += stat.size;
        await File(entry.path).delete();
      }
    } on FileSystemException {
      // Raced another sweep, or the OS reclaimed it first; nothing to free.
    }
  }

  if (freed > 0) {
    AppLogger.info(
        'Swept $freed bytes of interrupted-transfer debris from $root',
        tag: 'DISK');
  }
  return freed;
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

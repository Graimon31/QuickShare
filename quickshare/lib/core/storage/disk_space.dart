import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/byte_format.dart';

/// How much room a transfer leaves itself beyond the bytes it is bringing:
/// the sidecar files, the state records, and the difference between what the
/// OS reports free and what is actually usable.
const int kSpaceMargin = 64 * 1024 * 1024;

/// How much free space a volume has — or an honest "I do not know".
///
/// Two answers on purpose. A probe that returns 0 for "could not tell" would
/// turn every unsupported platform into a refusal, and one that returns
/// "plenty" would let a transfer start that cannot finish. Unknown carries its
/// reason so the log can say why the check did not happen, and a caller never
/// reports a check that did not.
class DiskSpace {
  const DiskSpace.known(int bytes)
      : availableBytes = bytes,
        unknownReason = null;

  const DiskSpace.unknown(String reason)
      : availableBytes = null,
        unknownReason = reason;

  final int? availableBytes;
  final String? unknownReason;

  bool get isKnown => availableBytes != null;
}

/// Asks the platform how much of a volume is free.
///
/// Injectable so a test can say "the disk has 10 MB" without a disk that
/// does, and so the receive paths — which run in different isolates and on
/// different platforms — each get the probe that can answer where they are.
/// An implementation never throws: any failure is [DiskSpace.unknown].
abstract class DiskSpaceProbe {
  const DiskSpaceProbe();

  /// Free bytes on the volume holding [path] (the path need not exist).
  Future<DiskSpace> available(String path);

  /// The probe for the platform this is running on.
  ///
  /// macOS, iOS and Android answer through a native channel (the removed
  /// `disk_space_2` plugin crashed on iOS 18.4.1, so none is back); Linux
  /// runs `df`; Windows calls `GetDiskFreeSpaceExW`. Anywhere else, or where
  /// the channel is absent — in a background isolate, say — the answer is
  /// unknown.
  factory DiskSpaceProbe.forCurrentPlatform() {
    if (Platform.isMacOS || Platform.isIOS || Platform.isAndroid) {
      return ChannelDiskSpaceProbe();
    }
    if (Platform.isLinux) return DfDiskSpaceProbe();
    if (Platform.isWindows) return WindowsDiskSpaceProbe();
    return const UnknownDiskSpaceProbe('no disk-space probe for this platform');
  }
}

/// A probe that never knows. The default where nothing better exists, and a
/// stand-in for a test of the "could not tell" path.
class UnknownDiskSpaceProbe extends DiskSpaceProbe {
  const UnknownDiskSpaceProbe(this.reason);
  final String reason;

  @override
  Future<DiskSpace> available(String path) async => DiskSpace.unknown(reason);
}

/// macOS, iOS and Android: the native side reads the volume's free space
/// (`volumeAvailableCapacityForImportantUsageKey` on Apple platforms,
/// `StatFs` on Android) and answers with a byte count.
class ChannelDiskSpaceProbe extends DiskSpaceProbe {
  ChannelDiskSpaceProbe({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('quickshare/disk_space');

  final MethodChannel _channel;

  @override
  Future<DiskSpace> available(String path) async {
    try {
      final answer = await _channel.invokeMethod<Object?>(
          'availableBytes', {'path': path}).timeout(const Duration(seconds: 5));
      if (answer is int && answer >= 0) return DiskSpace.known(answer);
      return DiskSpace.unknown('the platform answered "$answer"');
    } on MissingPluginException {
      return const DiskSpace.unknown('no native disk-space channel here');
    } on PlatformException catch (e) {
      return DiskSpace.unknown('the platform could not tell: ${e.code}');
    } on TimeoutException {
      return const DiskSpace.unknown('the platform did not answer in time');
    } catch (e) {
      // A worker isolate has no binding at all; that surfaces as a StateError
      // with a paragraph of advice attached. The first line says enough.
      return DiskSpace.unknown(
          'the channel is unavailable (${'$e'.split('\n').first})');
    }
  }
}

/// Linux: `df -Pk -- <path>`, POSIX output in kilobyte blocks.
class DfDiskSpaceProbe extends DiskSpaceProbe {
  DfDiskSpaceProbe({
    Future<ProcessResult> Function(String executable, List<String> arguments)?
        run,
    this.timeout = const Duration(seconds: 5),
  }) : _run = run ??
            ((exe, args) =>
                Process.run(exe, args, environment: const {'LC_ALL': 'C'}));

  final Future<ProcessResult> Function(String, List<String>) _run;
  final Duration timeout;

  @override
  Future<DiskSpace> available(String path) async {
    try {
      final result = await _run('df', ['-Pk', '--', path]).timeout(timeout);
      if (result.exitCode != 0) {
        final why = '${result.stderr}'.trim().split('\n').first;
        return DiskSpace.unknown('df exited ${result.exitCode}: $why');
      }
      return parse('${result.stdout}');
    } on TimeoutException {
      return const DiskSpace.unknown('df did not answer in time');
    } on ProcessException catch (e) {
      return DiskSpace.unknown('df could not be run: ${e.message}');
    } catch (e) {
      return DiskSpace.unknown('df failed: $e');
    }
  }

  /// `Filesystem 1024-blocks Used Available Capacity Mounted on`, then one
  /// line per filesystem asked about.
  ///
  /// Read from the left past the filesystem name and from the right past the
  /// mount point, because both may contain spaces (`/Volumes/Macintosh HD -
  /// Data`, `//nas/My Share`, `map auto_home`). The anchor between them is
  /// the run of three byte counts and a capacity, which no name is likely to
  /// imitate. The last such line wins: `df` was given one path.
  static DiskSpace parse(String output) {
    final line = RegExp(
        r'^(.+?)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+%|-)\s+(.*)$');
    DiskSpace? found;
    for (final raw in output.split('\n')) {
      final match = line.firstMatch(raw.trimRight());
      if (match == null) continue;
      final blocks = int.tryParse(match.group(4)!);
      if (blocks == null) continue;
      found = DiskSpace.known(blocks * 1024);
    }
    return found ??
        const DiskSpace.unknown('df printed nothing this could read');
  }
}

typedef _GetDiskFreeSpaceExNative = Int32 Function(Pointer<Utf16>,
    Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);
typedef _GetDiskFreeSpaceExDart = int Function(
    Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);

/// Windows: kernel32 `GetDiskFreeSpaceExW`, whose "available to the caller"
/// figure honours quotas.
class WindowsDiskSpaceProbe extends DiskSpaceProbe {
  WindowsDiskSpaceProbe();

  @override
  Future<DiskSpace> available(String path) async {
    if (!Platform.isWindows) {
      return const DiskSpace.unknown('not a Windows machine');
    }
    Pointer<Utf16>? directory;
    Pointer<Uint64>? free;
    Pointer<Uint64>? total;
    Pointer<Uint64>? totalFree;
    try {
      final call = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_GetDiskFreeSpaceExNative, _GetDiskFreeSpaceExDart>(
              'GetDiskFreeSpaceExW');
      // The function wants a directory that exists; the destination may not
      // yet, so ask about the nearest ancestor that does.
      var existing = p.absolute(path);
      while (!Directory(existing).existsSync()) {
        final parent = p.dirname(existing);
        if (parent == existing) break;
        existing = parent;
      }
      directory = existing.toNativeUtf16();
      free = calloc<Uint64>();
      total = calloc<Uint64>();
      totalFree = calloc<Uint64>();
      if (call(directory, free, total, totalFree) == 0) {
        return const DiskSpace.unknown('GetDiskFreeSpaceExW failed');
      }
      return DiskSpace.known(free.value);
    } catch (e) {
      return DiskSpace.unknown('GetDiskFreeSpaceExW is unavailable: $e');
    } finally {
      if (directory != null) calloc.free(directory);
      if (free != null) calloc.free(free);
      if (total != null) calloc.free(total);
      if (totalFree != null) calloc.free(totalFree);
    }
  }
}

// --- before a transfer -----------------------------------------------------

/// What is needed against what there is.
class SpaceCheck {
  const SpaceCheck({required this.required, required this.space});

  final int required;
  final DiskSpace space;

  /// Known to be too little. Unknown is neither short nor sufficient.
  bool get isShort => space.isKnown && space.availableBytes! < required;

  bool get isUnknown => !space.isKnown;
}

/// Asks [probe] about [path] and sets the answer against [remainingBytes]
/// (what is still to come, not the session total) plus [margin].
Future<SpaceCheck> checkFreeSpace(
  DiskSpaceProbe probe,
  String path, {
  required int remainingBytes,
  int margin = kSpaceMargin,
}) async {
  DiskSpace space;
  try {
    space = await probe.available(path);
  } catch (e) {
    space = DiskSpace.unknown('the probe failed: $e');
  }
  return SpaceCheck(required: remainingBytes + margin, space: space);
}

/// The transfer would not fit.
class NotEnoughSpaceException implements Exception {
  const NotEnoughSpaceException({required this.needed, required this.available});

  final int needed;
  final int available;

  /// The [FailureCode] carrying both sizes to the screen.
  String get failureCode => FailureCode.notEnoughSpaceFor(needed, available);

  String get message => 'Not enough free space: ${ByteFormat.size(needed)} '
      'needed, ${ByteFormat.size(available)} available';

  @override
  String toString() => 'NotEnoughSpaceException: $message';
}

/// Throws [NotEnoughSpaceException] when [path]'s volume is known to be too
/// small, logs when it cannot tell, and says nothing about a pass: a check
/// that could not run is not one that succeeded.
Future<void> requireFreeSpace(
  DiskSpaceProbe probe,
  String path, {
  required int remainingBytes,
  int margin = kSpaceMargin,
  String tag = 'DISK',
}) async {
  final check = await checkFreeSpace(probe, path,
      remainingBytes: remainingBytes, margin: margin);
  if (check.isShort) {
    throw NotEnoughSpaceException(
        needed: check.required, available: check.space.availableBytes!);
  }
  if (check.isUnknown) {
    AppLogger.info(
        'Receive: free space unknown for $path (${check.space.unknownReason}); '
        'going ahead without a space check',
        tag: tag);
  }
}

// --- when it runs out anyway -----------------------------------------------

/// Whether [e] is the OS saying the disk (or the user's quota on it) is full.
///
/// The numbers differ by platform and one of them collides: 39 is
/// `ERROR_HANDLE_DISK_FULL` on Windows and `ENOTEMPTY` everywhere else, so a
/// failed folder rename would otherwise read as a full disk. [os] is for
/// tests; it defaults to the platform this runs on.
bool isDiskFull(FileSystemException e, {String? os}) {
  final system = os ?? Platform.operatingSystem;
  final code = e.osError?.errorCode;
  if (code != null) {
    switch (system) {
      case 'windows':
        if (code == 112 /* ERROR_DISK_FULL */ ||
            code == 39 /* ERROR_HANDLE_DISK_FULL */) {
          return true;
        }
      case 'macos':
      case 'ios':
        if (code == 28 /* ENOSPC */ || code == 69 /* EDQUOT */) return true;
      case 'linux':
      case 'android':
        if (code == 28 /* ENOSPC */ || code == 122 /* EDQUOT */) return true;
      default:
        if (code == 28) return true;
    }
  }
  final text = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
  return text.contains('no space left') ||
      text.contains('not enough space on the disk') ||
      text.contains('disk full');
}

// Does the storage layer behave on a real Android filesystem?
//
// The receive path rests on three things that `flutter test` on a desktop can
// only imitate: a native channel (`DiskSpacePlugin.kt`, registered in
// `MainActivity.kt`) that answers how much room a volume has, libc calls
// (`link`, `mkdir`, `open`, `fsync`) reached through dart:ffi, and a
// filesystem whose rules are Android's — an SELinux-confined app data
// directory that is itself reached through a symbolic link. This runs the
// production classes against all three:
//
//     flutter test integration_test/android_native_storage_test.dart -d emulator-5554
//
// Nothing here is a copy of production code. The probe is the real
// `ChannelDiskSpaceProbe` talking to the real Kotlin handler; `SafePath` and
// `DurableFile` do their real work on the app's own cache directory; the QHTP
// test is the real `LocalHttpServer` talking to the real `QhtpReceiverClient`
// over loopback inside the app. Everything is created under the app cache
// directory and removed again.
//
// Lines worth reading in the output, because they are measurements rather
// than assertions:
//
//     DISK_PROBE_BYTES=<n>   what the channel said is free (compare with
//                            `adb shell df -k /data` — same volume)
//     LINK_MODE=real|fallback  whether link(2) is permitted here, or the
//                            look-then-rename fallback ran instead
//     DEV_FULL=...           whether the app may write to /dev/full to get a
//                            genuine ENOSPC
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/storage/disk_space.dart';
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/storage/safe_path.dart';
import 'package:quickshare/core/storage/storage_failure.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

// --- the kernel, asked directly --------------------------------------------

typedef _LinkNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _LinkDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PathNative = Int32 Function(Pointer<Utf8>);
typedef _PathDart = int Function(Pointer<Utf8>);
typedef _OpenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenDart = int Function(Pointer<Utf8>, int);
typedef _FdNative = Int32 Function(Int32);
typedef _FdDart = int Function(int);
typedef _ErrnoNative = Pointer<Int32> Function();

/// What the kernel says to `link(2)` for this app, independent of SafePath.
/// The errno is best-effort (Dart may touch it between the two calls), and is
/// there for the log line, not for an assertion.
({int rc, int errno}) _kernelLink(String from, String to) {
  final lib = DynamicLibrary.process();
  final link = lib.lookupFunction<_LinkNative, _LinkDart>('link');
  final errnoLocation =
      lib.lookupFunction<_ErrnoNative, Pointer<Int32> Function()>('__errno');
  final a = from.toNativeUtf8();
  final b = to.toNativeUtf8();
  try {
    final rc = link(a, b);
    return (rc: rc, errno: rc == 0 ? 0 : errnoLocation().value);
  } finally {
    malloc.free(a);
    malloc.free(b);
  }
}

// --- the probe, recording what it was asked and what it answered ----------

class _RecordingProbe extends DiskSpaceProbe {
  _RecordingProbe(this._real);

  final DiskSpaceProbe _real;
  final answers = <({String path, DiskSpace space})>[];

  @override
  Future<DiskSpace> available(String path) async {
    final space = await _real.available(path);
    answers.add((path: path, space: space));
    return space;
  }
}

Uint8List _bytes(int n, int seed) {
  final rand = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => rand.nextInt(256)));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Every line the app logs, so a test can ask "did that warn?" and "which
  // path did the rename take?" without reading logcat.
  final logLines = <String>[];
  late StreamSubscription<String> logSub;
  setUpAll(() => logSub = AppLogger.logStream.listen(logLines.add));
  tearDownAll(() => logSub.cancel());

  /// The log is a broadcast stream and delivers on a later turn of the event
  /// loop; wait for it before reading.
  Future<void> flushLogs() => Future<void>.delayed(const Duration(milliseconds: 20));

  late Directory scratch;

  setUp(() async {
    final cache = await getTemporaryDirectory();
    scratch = Directory(p.join(
        cache.path, 'dd_native_${Random.secure().nextInt(1 << 31)}'))
      ..createSync(recursive: true);
    SafePath.debugDisableHardLinks = false;
  });

  tearDown(() {
    SafePath.debugDisableHardLinks = false;
    try {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      print('could not remove scratch ${scratch.path}: $e');
    }
  });

  String at(String relative) => p.join(scratch.path, relative);

  File put(String path, String content) {
    File(path).parent.createSync(recursive: true);
    return File(path)..writeAsStringSync(content);
  }

  // ===========================================================================
  // DiskSpacePlugin.kt, through MainActivity.kt's MethodChannel
  // ===========================================================================
  group('the disk-space channel (DiskSpacePlugin.kt)', () {
    // How far the channel and `df` may disagree once the volume has settled.
    // They read the same volume a few milliseconds apart.
    const tolerance = 8 * 1024 * 1024;

    Future<int?> dfAvailableBytes(String path) async {
      for (final exe in const ['df', '/system/bin/df']) {
        try {
          final out =
              await Process.run(exe, ['-Pk', path]).timeout(const Duration(seconds: 10));
          if (out.exitCode != 0) {
            print('DF_COMPARISON exit ${out.exitCode} from $exe: ${out.stderr}');
            continue;
          }
          final parsed = DfDiskSpaceProbe.parse('${out.stdout}');
          if (parsed.isKnown) return parsed.availableBytes;
          print('DF_COMPARISON unreadable output from $exe: ${out.stdout}');
        } on ProcessException catch (e) {
          print('DF_COMPARISON cannot run $exe in the app sandbox: $e');
        }
      }
      return null;
    }

    testWidgets('the platform probe is the channel probe, and it answers',
        (tester) async {
      final probe = DiskSpaceProbe.forCurrentPlatform();
      expect(probe, isA<ChannelDiskSpaceProbe>(),
          reason: 'Android must answer through the native channel');

      final cache = await getTemporaryDirectory();
      final space =
          await probe.available(cache.path).timeout(const Duration(seconds: 10));

      expect(space.isKnown, isTrue,
          reason: 'the channel did not answer: ${space.unknownReason}. If this '
              'says "no native disk-space channel here", the handler is not '
              'registered in MainActivity.configureFlutterEngine');
      expect(space.availableBytes, greaterThan(0));

      // The first answer after install: the system is still tidying up after
      // the package, so this is not the number to compare with `df`. The
      // settled one is printed by the next test.
      print('DISK_PROBE_PATH=${cache.path}');
      print('DISK_PROBE_FIRST_CALL_BYTES=${space.availableBytes}');
    });

    testWidgets('the channel agrees with df on the same volume', (tester) async {
      final probe = ChannelDiskSpaceProbe();
      final cache = await getTemporaryDirectory();

      var previous = await dfAvailableBytes(cache.path);
      if (previous == null) {
        print('DF_COMPARISON skipped: `df` could not be run or read inside '
            'the app sandbox (reason above); compare DISK_PROBE_BYTES with '
            '`adb shell df -k /data` from outside');
        final alone = await probe.available(cache.path);
        print('DISK_PROBE_BYTES=${alone.availableBytes}');
        markTestSkipped('df is not usable from the app sandbox');
        return;
      }

      // A freshly installed app is still being settled by the system (the
      // staged APK is removed, code is optimised), and free space moves by
      // the size of the package while that happens. Wait for it to hold still
      // so the comparison is about the probe and not about the install.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final now = (await dfAvailableBytes(cache.path))!;
        final settled = (now - previous!).abs() < 1024 * 1024;
        previous = now;
        if (settled) break;
      }

      // Probe, then df, bracketed: each probe must sit between the df reads
      // on either side of it, give or take the tolerance.
      for (var round = 0; round < 4; round++) {
        final answered = await probe.available(cache.path);
        expect(answered.isKnown, isTrue, reason: answered.unknownReason);
        final after = (await dfAvailableBytes(cache.path))!;
        final low = min(previous!, after) - tolerance;
        final high = max(previous, after) + tolerance;
        print('DF_COMPARISON round=$round df_before=$previous '
            'probe=${answered.availableBytes} df_after=$after');
        expect(answered.availableBytes!, inInclusiveRange(low, high),
            reason: 'StatFs and df read the same volume; the probe '
                '(${answered.availableBytes}) is outside df\'s '
                '$previous..$after by more than $tolerance bytes');
        previous = after;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      // The line the person running this compares with `adb shell df -k
      // /data` (same volume), once the volume has settled.
      final settled = await probe.available(cache.path);
      print('DISK_PROBE_BYTES=${settled.availableBytes}');
    });

    testWidgets('a folder that does not exist yet is answered for the nearest '
        'one that does', (tester) async {
      final probe = ChannelDiskSpaceProbe();
      final existing = await probe.available(scratch.path);
      final deep = await probe
          .available(at('not/yet/created/at/all'))
          .timeout(const Duration(seconds: 10));

      expect(existing.isKnown, isTrue, reason: existing.unknownReason);
      expect(deep.isKnown, isTrue,
          reason: 'the receiver creates folders as files arrive, so the '
              'destination often does not exist: ${deep.unknownReason}');
      expect((deep.availableBytes! - existing.availableBytes!).abs(),
          lessThan(32 * 1024 * 1024));
      expect(Directory(at('not')).existsSync(), isFalse,
          reason: 'asking must not create anything');
    });

    testWidgets('a regular file path is answered for its volume',
        (tester) async {
      final file = put(at('a_file.bin'), 'x');
      final space = await ChannelDiskSpaceProbe()
          .available(file.path)
          .timeout(const Duration(seconds: 10));
      expect(space.isKnown, isTrue, reason: space.unknownReason);
      expect(space.availableBytes, greaterThan(0));
    });

    testWidgets('strings that are not filesystem paths get an explicit '
        '"unknown" from the native side — no crash, no hang', (tester) async {
      final probe = ChannelDiskSpaceProbe();
      for (final nonPath in const [
        'content://com.android.externalstorage.documents/tree/primary%3ADocuments',
        '',
      ]) {
        final watch = Stopwatch()..start();
        final space =
            await probe.available(nonPath).timeout(const Duration(seconds: 10));
        watch.stop();

        expect(space.isKnown, isFalse,
            reason: '"$nonPath" is not on any volume the probe can measure; '
                'a number here would be a made-up one');
        // The reason has to come from the Kotlin handler refusing, not from
        // the channel being absent — otherwise this passes with the plugin
        // unregistered.
        expect(space.unknownReason, contains('UNAVAILABLE'),
            reason: 'expected DiskSpacePlugin to answer with an error, got '
                '"${space.unknownReason}"');
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
        print('NON_PATH "${nonPath.isEmpty ? '(empty)' : nonPath}" -> '
            '${space.unknownReason} in ${watch.elapsedMilliseconds} ms');
      }
    });

    testWidgets('the handler rejects a call with no path and an unknown method '
        'instead of leaving the channel waiting', (tester) async {
      const channel = MethodChannel('quickshare/disk_space');

      await expectLater(
        channel.invokeMethod<Object?>('availableBytes', <String, Object?>{})
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'BAD_ARGS')),
      );
      await expectLater(
        channel.invokeMethod<Object?>('somethingElse')
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<MissingPluginException>()),
      );

      // And a channel nobody registered answers "unknown", quickly, rather
      // than hanging until the probe's own five-second limit.
      final watch = Stopwatch()..start();
      final nobody = await ChannelDiskSpaceProbe(
              channel: const MethodChannel('quickshare/not_registered'))
          .available(scratch.path);
      expect(nobody.isKnown, isFalse);
      expect(nobody.unknownReason, contains('no native disk-space channel'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    testWidgets('50 calls on the main isolate complete without stalling it',
        (tester) async {
      final probe = ChannelDiskSpaceProbe();

      // A heartbeat on the same isolate: if the calls blocked it, the gaps
      // between ticks would show it.
      var last = DateTime.now();
      var worstGap = Duration.zero;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 5), (_) {
        final now = DateTime.now();
        final gap = now.difference(last);
        if (gap > worstGap) worstGap = gap;
        last = now;
      });

      final watch = Stopwatch()..start();
      var worstCall = Duration.zero;
      for (var i = 0; i < 50; i++) {
        final call = Stopwatch()..start();
        final space = await probe
            .available(scratch.path)
            .timeout(const Duration(seconds: 5));
        call.stop();
        if (call.elapsed > worstCall) worstCall = call.elapsed;
        expect(space.isKnown, isTrue, reason: 'call $i: ${space.unknownReason}');
      }
      final sequential = watch.elapsed;

      // And all at once, which is how a burst of sessions would ask.
      watch.reset();
      final burst = await Future.wait([
        for (var i = 0; i < 50; i++) probe.available(at('burst/$i/x')),
      ]).timeout(const Duration(seconds: 15));
      final concurrent = watch.elapsed;
      heartbeat.cancel();

      expect(burst.every((s) => s.isKnown), isTrue,
          reason: burst.where((s) => !s.isKnown).map((s) => s.unknownReason).join('; '));
      print('PROBE_50 sequential=${sequential.inMilliseconds}ms '
          'worst_call=${worstCall.inMilliseconds}ms '
          'concurrent=${concurrent.inMilliseconds}ms '
          'worst_isolate_gap=${worstGap.inMilliseconds}ms');
      expect(sequential, lessThan(const Duration(seconds: 10)));
      expect(worstCall, lessThan(const Duration(seconds: 1)));
      expect(worstGap, lessThan(const Duration(milliseconds: 750)),
          reason: 'the main isolate stalled while the channel was being used');
    });
  });

  // ===========================================================================
  // SafePath on the real Android filesystem
  // ===========================================================================
  group('SafePath on the app\'s own storage', () {
    // The first test in this group must be the first thing in the process to
    // call renameNoClobber: the "no atomic rename" note is logged once per run.
    testWidgets('LINK_MODE: renameNoClobber moves a file, and which mechanism '
        'it used is measured', (tester) async {
      expect(SafePath.debugAtomicRenameAvailable, isTrue,
          reason: 'link/unlink/mkdir were not found in libc on Android');

      // What the kernel says, asked without SafePath.
      final kSrc = put(at('kernel_src'), 'k');
      final kernel = _kernelLink(kSrc.path, at('kernel_dst'));
      print('KERNEL_LINK rc=${kernel.rc} errno=${kernel.errno}');

      final from = put(at('probe_src.bin'), 'payload-A');
      final to = at('probe_dst.bin');
      final before = logLines.length;
      SafePath.renameNoClobber(from.path, to);
      await flushLogs();

      final fellBack = logLines
          .skip(before)
          .any((l) => l.contains('No atomic no-replace rename'));
      final mode = fellBack ? 'fallback' : 'real';
      print('LINK_MODE=$mode (path ${p.dirname(to)}, resolved '
          '${SafePath.canonicalBase(p.dirname(to))})');

      expect(File(from.path).existsSync(), isFalse, reason: 'it is a move');
      expect(File(to).readAsStringSync(), 'payload-A');
      expect(mode == 'real', kernel.rc == 0,
          reason: 'SafePath should use link(2) exactly when the kernel allows '
              'it (kernel rc=${kernel.rc}, errno=${kernel.errno})');
    });

    testWidgets('renameNoClobber refuses an existing file and changes nothing',
        (tester) async {
      final from = put(at('b_src.bin'), 'incoming bytes');
      final to = put(at('b_dst.bin'), 'the user\'s own file');

      expect(() => SafePath.renameNoClobber(from.path, to.path),
          throwsA(isA<PathTakenException>()));

      expect(to.readAsStringSync(), 'the user\'s own file');
      expect(from.readAsStringSync(), 'incoming bytes',
          reason: 'a refused move leaves the partial where it was');
    });

    testWidgets('renameNoClobber refuses a dangling symlink and does not '
        'create its target', (tester) async {
      final from = put(at('c_src.bin'), 'incoming bytes');
      final target = at('c_victim_target.bin');
      final to = at('c_dst.bin');
      Link(to).createSync(target);

      expect(() => SafePath.renameNoClobber(from.path, to),
          throwsA(isA<PathTakenException>()));

      expect(FileSystemEntity.typeSync(to, followLinks: false),
          FileSystemEntityType.link);
      expect(Link(to).targetSync(), target);
      expect(File(target).existsSync(), isFalse,
          reason: 'writing "through" the link would have created this');
      expect(from.readAsStringSync(), 'incoming bytes');
    });

    testWidgets('the look-then-rename fallback gives the same three answers '
        'on this filesystem', (tester) async {
      SafePath.debugDisableHardLinks = true;

      final a = put(at('f_src_a.bin'), 'A');
      SafePath.renameNoClobber(a.path, at('f_dst_a.bin'));
      expect(File(at('f_dst_a.bin')).readAsStringSync(), 'A');
      expect(a.existsSync(), isFalse);

      final b = put(at('f_src_b.bin'), 'B');
      final taken = put(at('f_dst_b.bin'), 'mine');
      expect(() => SafePath.renameNoClobber(b.path, taken.path),
          throwsA(isA<PathTakenException>()));
      expect(taken.readAsStringSync(), 'mine');

      final c = put(at('f_src_c.bin'), 'C');
      Link(at('f_dst_c.bin')).createSync(at('f_nowhere.bin'));
      expect(() => SafePath.renameNoClobber(c.path, at('f_dst_c.bin')),
          throwsA(isA<PathTakenException>()));
      expect(File(at('f_nowhere.bin')).existsSync(), isFalse);
    });

    testWidgets('a folder is moved only onto a name nobody holds — an empty '
        'folder, a full one, a file and a dangling link all refuse',
        (tester) async {
      File stagedFile(String name) {
        final dir = Directory(at('staged_$name'))..createSync();
        return put(p.join(dir.path, 'f.txt'), 'content of $name');
      }

      // Free name: moved whole.
      final okFile = stagedFile('ok');
      SafePath.renameDirectoryNoClobber(at('staged_ok'), at('Trip'));
      expect(File(at('Trip/f.txt')).readAsStringSync(), 'content of ok');
      expect(okFile.existsSync(), isFalse);
      expect(Directory(at('staged_ok')).existsSync(), isFalse);

      // Each of these is "taken". A plain rename(2) would replace the empty
      // folder — that is the case mkdir(2) exists to refuse.
      final cases = <String, void Function(String path)>{
        'empty': (path) => Directory(path).createSync(),
        'full': (path) {
          Directory(path).createSync();
          put(p.join(path, 'mine.txt'), 'mine');
        },
        'file': (path) => put(path, 'a file'),
        'dangling': (path) => Link(path).createSync(at('dir_nowhere')),
      };
      for (final entry in cases.entries) {
        final staged = stagedFile(entry.key);
        final to = at('Taken_${entry.key}');
        entry.value(to);
        final before = FileSystemEntity.typeSync(to, followLinks: false);

        expect(() => SafePath.renameDirectoryNoClobber(staged.parent.path, to),
            throwsA(isA<PathTakenException>()),
            reason: 'taken by: ${entry.key}');

        expect(FileSystemEntity.typeSync(to, followLinks: false), before,
            reason: 'what was there is still what is there (${entry.key})');
        expect(staged.existsSync(), isTrue,
            reason: 'the staged folder is not consumed by a refusal');
      }
      expect(Directory(at('Taken_empty')).listSync(), isEmpty,
          reason: 'the empty folder was not filled');
      expect(File(at('Taken_full/mine.txt')).readAsStringSync(), 'mine');
      expect(Directory(at('dir_nowhere')).existsSync(), isFalse);
    });

    testWidgets('the same refusal holds for folders without hard links',
        (tester) async {
      SafePath.debugDisableHardLinks = true;
      final staged = Directory(at('fb_staged'))..createSync();
      put(p.join(staged.path, 'f.txt'), 'x');
      Directory(at('fb_taken')).createSync();

      expect(() => SafePath.renameDirectoryNoClobber(staged.path, at('fb_taken')),
          throwsA(isA<PathTakenException>()));
      SafePath.renameDirectoryNoClobber(staged.path, at('fb_free'));
      expect(File(at('fb_free/f.txt')).readAsStringSync(), 'x');
    });

    testWidgets('committing onto a taken name lands as "name (1)" and touches '
        'neither the original nor a link', (tester) async {
      final base = Directory(at('commit'))..createSync();

      final taken = put(p.join(base.path, 'photo.jpg'), 'the user\'s');
      final partial = put(p.join(base.path, 'photo.jpg.qs.partial'), 'received');
      final landed = SafePath.commitFile(
          base.path, partial.path, p.join(base.path, 'photo.jpg'));
      expect(landed, p.join(base.path, 'photo (1).jpg'));
      expect(taken.readAsStringSync(), 'the user\'s');
      expect(File(landed).readAsStringSync(), 'received');

      // A dangling link on the name counts as taken, too.
      Link(p.join(base.path, 'clip.mp4')).createSync(at('clip_victim'));
      final partial2 = put(p.join(base.path, 'clip.mp4.qs.partial'), 'clip');
      final landed2 = SafePath.commitFile(
          base.path, partial2.path, p.join(base.path, 'clip.mp4'));
      expect(landed2, p.join(base.path, 'clip (1).mp4'));
      expect(File(at('clip_victim')).existsSync(), isFalse);

      // And a folder.
      Directory(p.join(base.path, 'Trip')).createSync();
      final staged = Directory(p.join(base.path, 'Trip.qs.partial'))..createSync();
      put(p.join(staged.path, 'a.txt'), 'a');
      final landedDir = SafePath.commitDirectory(
          base.path, staged.path, p.join(base.path, 'Trip'));
      expect(landedDir, p.join(base.path, 'Trip (1)'));
      expect(File(p.join(landedDir, 'a.txt')).readAsStringSync(), 'a');
      expect(Directory(p.join(base.path, 'Trip')).listSync(), isEmpty);
    });

    testWidgets('a chain of symlinks anywhere between the destination and the '
        'file is refused, and nothing is created through it', (tester) async {
      final base = Directory(at('chain/dest'))..createSync(recursive: true);
      final outside = Directory(at('chain/outside'))..createSync();
      final inner = Directory(p.join(base.path, 'inner'))..createSync();

      // l1 -> l2 -> outside
      Link(p.join(base.path, 'l2')).createSync(outside.path);
      Link(p.join(base.path, 'l1')).createSync(p.join(base.path, 'l2'));
      // alias -> a real folder INSIDE the destination: still a link.
      Link(p.join(base.path, 'alias')).createSync(inner.path);
      // a loop
      Link(p.join(base.path, 'loop_a')).createSync(p.join(base.path, 'loop_b'));
      Link(p.join(base.path, 'loop_b')).createSync(p.join(base.path, 'loop_a'));
      // a file where a folder must be
      put(p.join(base.path, 'plain'), 'not a folder');

      for (final route in const ['l1', 'l2', 'alias', 'loop_a', 'plain']) {
        expect(() => SafePath.resolve('$route/deep/file.bin', base.path),
            throwsA(isA<UnsafePathException>()),
            reason: 'resolve through $route');
        expect(
            () => SafePath.ensureParents(
                base.path, p.join(base.path, route, 'deep', 'file.bin')),
            throwsA(isA<UnsafePathException>()),
            reason: 'ensureParents through $route');
        expect(
            () => SafePath.openPartial(base.path,
                p.join(base.path, route, 'file.bin.qs.partial'),
                truncate: true),
            throwsA(isA<UnsafePathException>()),
            reason: 'openPartial through $route');
      }

      expect(outside.listSync(), isEmpty,
          reason: 'nothing may be created on the far side of a link');
      expect(inner.listSync(), isEmpty);
    });

    testWidgets('a folder swapped for a link between open and commit is caught '
        'at commit', (tester) async {
      final base = Directory(at('swap/dest'))..createSync(recursive: true);
      final elsewhere = Directory(at('swap/elsewhere'))..createSync();
      final folder = Directory(p.join(base.path, 'Album'))..createSync();
      final partial = put(p.join(folder.path, 'a.jpg.qs.partial'), 'bytes');

      // The user (or something else) replaces the folder while the transfer
      // is in flight: the real one moves aside, a link takes its name.
      folder.renameSync(p.join(base.path, 'Album_moved'));
      Link(folder.path).createSync(elsewhere.path);

      expect(
          () => SafePath.commitFile(base.path, partial.path,
              p.join(folder.path, 'a.jpg')),
          throwsA(isA<UnsafePathException>()));
      expect(elsewhere.listSync(), isEmpty);
      expect(File(p.join(base.path, 'Album_moved', 'a.jpg.qs.partial'))
          .existsSync(), isTrue);
    });

    testWidgets('a destination reached through a symlink is accepted — the '
        'folder the user chose is resolved, not refused', (tester) async {
      // Android reaches an app's data through /data/user/0, which is a link
      // to /data/data (or the other way round). The base has to be allowed
      // to sit under one.
      final cache = await getTemporaryDirectory();
      final resolvedCache = Directory(cache.path).resolveSymbolicLinksSync();
      final package = p.basename(p.dirname(resolvedCache));
      final viaAlias = <String>[
        for (final root in const ['/data/data', '/data/user/0'])
          p.join(root, package, 'cache', p.basename(scratch.path)),
      ];
      print('CACHE_PATH=${cache.path} CACHE_RESOLVED=$resolvedCache');

      var exercised = 0;
      for (final alias in viaAlias) {
        if (!Directory(alias).existsSync()) {
          print('ALIAS_SKIPPED $alias is not reachable from the app');
          continue;
        }
        exercised++;
        final base = Directory(p.join(alias, 'dest'))..createSync();
        final target = SafePath.resolve('Trip/day 1/a.bin', base.path);
        SafePath.ensureParents(base.path, target);
        final raf = SafePath.openPartial(base.path, '$target.qs.partial',
            truncate: true);
        raf.writeStringSync('through an alias');
        raf.closeSync();
        final landed = SafePath.commitFile(base.path, '$target.qs.partial', target);
        expect(File(landed).readAsStringSync(), 'through an alias',
            reason: 'base $alias');
      }
      expect(exercised, greaterThan(0));
    });

    testWidgets('a guarded partial open never truncates what a symlink points '
        'at', (tester) async {
      final base = Directory(at('partial/dest'))..createSync(recursive: true);
      final victim = put(at('partial/outside/victim.bin'),
          'precious bytes that must survive');
      final insider = put(p.join(base.path, 'real.bin'), 'a real file inside');

      // Control: truncate really does truncate a regular partial here, so the
      // assertions below are not vacuous.
      final regular = p.join(base.path, 'regular.bin.qs.partial');
      put(regular, 'old partial');
      SafePath.openPartial(base.path, regular, truncate: true).closeSync();
      expect(File(regular).lengthSync(), 0);

      for (final entry in <String, String>{
        'to_outside': victim.path,
        'to_inside': insider.path,
        'dangling': at('partial/outside/created_by_attack.bin'),
      }.entries) {
        final partial = p.join(base.path, '${entry.key}.bin.qs.partial');
        Link(partial).createSync(entry.value);

        final raf = SafePath.openPartial(base.path, partial, truncate: true);
        raf.writeStringSync('fresh bytes');
        raf.closeSync();

        expect(FileSystemEntity.typeSync(partial, followLinks: false),
            FileSystemEntityType.file,
            reason: '${entry.key}: the link is replaced by a real partial');
        expect(File(partial).readAsStringSync(), 'fresh bytes');
      }

      expect(victim.readAsStringSync(), 'precious bytes that must survive',
          reason: 'the file outside the destination was neither truncated nor '
              'written to');
      expect(insider.readAsStringSync(), 'a real file inside');
      expect(File(at('partial/outside/created_by_attack.bin')).existsSync(),
          isFalse);
    });

    testWidgets('resume opens the existing partial without truncating, and '
        'partialLength refuses to count a link\'s target', (tester) async {
      final base = Directory(at('resume'))..createSync();
      final partial = p.join(base.path, 'big.bin.qs.partial');

      var raf = SafePath.openPartial(base.path, partial, truncate: true);
      raf.writeStringSync('abc');
      raf.closeSync();
      expect(SafePath.partialLength(base.path, partial), 3);

      raf = SafePath.openPartial(base.path, partial, truncate: false);
      expect(raf.lengthSync(), 3, reason: 'a resume keeps what is there');
      raf.writeStringSync('def');
      raf.closeSync();
      expect(File(partial).readAsStringSync(), 'abcdef',
          reason: 'and writes from the end, leaving no hole');

      final victim = put(at('resume_victim.bin'), 'x' * 4096);
      final linked = p.join(base.path, 'linked.bin.qs.partial');
      Link(linked).createSync(victim.path);
      expect(SafePath.partialLength(base.path, linked), 0,
          reason: 'the target\'s length is not ours to count');
      expect(FileSystemEntity.typeSync(linked, followLinks: false),
          FileSystemEntityType.notFound,
          reason: 'only the link is removed');
      expect(victim.lengthSync(), 4096);
    });

    testWidgets('DurableFile writes, syncs and commits on this filesystem '
        'without a single warning from the libc bindings', (tester) async {
      final base = Directory(at('durable'))..createSync();
      final before = logLines.length;

      final file = DurableFile(p.join(base.path, 'doc.bin'), base: base.path);
      await file.open();
      await file.add(Uint8List.fromList(List.filled(100000, 7)));
      final landed = await file.commit();
      await flushLogs();

      expect(landed, p.join(base.path, 'doc.bin'));
      expect(File(landed).lengthSync(), 100000);
      expect(File('$landed$kPartialSuffix').existsSync(), isFalse,
          reason: 'the partial was renamed, not copied');
      final warnings = logLines.skip(before).where((l) =>
          l.contains('libc') && l.contains('unavailable') ||
          l.contains('syncFile(') ||
          l.contains('syncDirectory('));
      expect(warnings, isEmpty);

      // And a second one aimed at a link is refused rather than written to.
      final victim = put(at('durable_victim.bin'), 'precious');
      final other = DurableFile(p.join(base.path, 'doc2.bin'), base: base.path);
      Link('${other.finalPath}$kPartialSuffix').createSync(victim.path);
      await other.open();
      await other.add(Uint8List.fromList([1, 2, 3]));
      await other.commit();
      expect(victim.readAsStringSync(), 'precious');
      expect(File(other.finalPath).lengthSync(), 3);
    });
  });

  // ===========================================================================
  // libc through dart:ffi
  // ===========================================================================
  group('libc on Android', () {
    testWidgets('every symbol the storage layer binds resolves, and the calls '
        'succeed on a directory and a file', (tester) async {
      final lib = DynamicLibrary.process();
      for (final symbol in const [
        'open', 'fsync', 'close', 'link', 'unlink', 'mkdir', '__errno',
      ]) {
        expect(lib.providesSymbol(symbol), isTrue, reason: symbol);
      }

      final open = lib.lookupFunction<_OpenNative, _OpenDart>('open');
      final fsync = lib.lookupFunction<_FdNative, _FdDart>('fsync');
      final close = lib.lookupFunction<_FdNative, _FdDart>('close');
      final mkdir = lib.lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, int)>('mkdir');
      final unlink = lib.lookupFunction<_PathNative, _PathDart>('unlink');

      // Exactly what syncDirectory does: open(O_RDONLY) the folder, fsync it.
      final dir = scratch.path.toNativeUtf8();
      try {
        final fd = open(dir, 0);
        expect(fd, greaterThanOrEqualTo(0),
            reason: 'open(directory, O_RDONLY) was refused (SELinux?)');
        try {
          expect(fsync(fd), 0, reason: 'fsync on a directory descriptor');
        } finally {
          close(fd);
        }
      } finally {
        malloc.free(dir);
      }

      final made = at('mkdir_probe').toNativeUtf8();
      try {
        expect(mkdir(made, 511), 0);
        expect(Directory(at('mkdir_probe')).existsSync(), isTrue);
        expect(mkdir(made, 511), -1, reason: 'EEXIST the second time');
      } finally {
        malloc.free(made);
      }

      final file = put(at('unlink_probe'), 'x');
      final path = file.path.toNativeUtf8();
      try {
        expect(unlink(path), 0);
        expect(file.existsSync(), isFalse);
      } finally {
        malloc.free(path);
      }
    });

    testWidgets('syncDirectory and syncFile complete on real storage and do '
        'not log a failure', (tester) async {
      final file = put(at('sync_me.bin'), 'x' * 8192);
      final before = logLines.length;

      await syncFile(file.path);
      await syncDirectory(scratch.path);
      // A path that cannot be opened must be absorbed, not thrown.
      await syncDirectory(at('no/such/dir'));
      await flushLogs();

      expect(
          logLines.skip(before).where((l) =>
              l.contains('libc fsync bindings unavailable') ||
              l.contains('syncDirectory(') ||
              l.contains('syncFile(')),
          isEmpty);
    });
  });

  // ===========================================================================
  // A genuine ENOSPC
  // ===========================================================================
  group('a disk that really is full', () {
    testWidgets('isDiskFull does not mistake a real ENOTEMPTY (39, which is '
        '"disk full" on Windows) for a full disk', (tester) async {
      final notEmpty = Directory(at('not_empty'))..createSync();
      put(p.join(notEmpty.path, 'x'), 'x');
      FileSystemException? enotempty;
      try {
        notEmpty.deleteSync();
      } on FileSystemException catch (e) {
        enotempty = e;
      }
      expect(enotempty, isNotNull);
      expect(enotempty!.osError?.errorCode, 39);
      expect(isDiskFull(enotempty), isFalse);
      expect(classifyStorageError(enotempty), isNull);
    });

    testWidgets('isDiskFull recognises the ENOSPC the kernel returns from '
        '/dev/full', (tester) async {
      RandomAccessFile? sink;
      try {
        sink = File('/dev/full').openSync(mode: FileMode.writeOnlyAppend);
      } on FileSystemException catch (e) {
        print('DEV_FULL=denied (${e.osError}); a real ENOSPC could not be '
            'produced from inside the app sandbox, so the check against a '
            'genuine kernel ENOSPC did NOT run');
        markTestSkipped('/dev/full cannot be opened by the app: ${e.osError}');
        return;
      }

      try {
        FileSystemException? full;
        try {
          sink.writeFromSync(Uint8List.fromList([1, 2, 3, 4]));
        } on FileSystemException catch (e) {
          full = e;
        }
        if (full == null) {
          print('DEV_FULL=writable-but-never-full (the write succeeded)');
          fail('writing to /dev/full succeeded; expected ENOSPC');
        }
        print('DEV_FULL=ENOSPC errno=${full.osError?.errorCode} '
            'message="${full.osError?.message}"');

        expect(full.osError?.errorCode, 28);
        expect(isDiskFull(full), isTrue);
        final problem = classifyStorageError(full);
        expect(problem?.code, FailureCode.diskFull,
            reason: 'the receive paths turn a full disk into this code');
      } finally {
        sink.closeSync();
      }
    });
  });

  // ===========================================================================
  // QHTP, loopback, inside the app
  // ===========================================================================
  group('QHTP over loopback in the app', () {
    late Directory source;
    late Directory target;
    late Directory state;
    LocalHttpServer? server;
    late QRPayload payload;
    late QhtpIndexerResult indexed;
    final requests = <({String path, String? range, int? status})>[];
    final statuses = <String, int>{};

    String received(String relative) =>
        p.join(target.path, p.basename(source.path), relative);

    String idOf(String relative) => indexed.manifest.items
        .firstWhere((i) => i.path == '${p.basename(source.path)}/$relative')
        .id;

    int fileRequestsFor(String relative) => requests
        .where((r) =>
            r.path.contains('/v2/files/') &&
            !r.path.endsWith('/digest') &&
            p.url.basename(r.path) == idOf(relative))
        .length;

    Future<void> serve(Map<String, Uint8List> files) async {
      for (final entry in files.entries) {
        File(p.join(source.path, entry.key))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(entry.value);
      }
      indexed = await FileIndexer().buildResult(
        sessionId: 'android-e2e-${Random().nextInt(1 << 30)}',
        paths: [source.path],
      );
      server = LocalHttpServer();
      const token = 'android-e2e-token';
      final port = await server!.startQhtpSession(
        manifest: indexed.manifest,
        itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
        authToken: token,
      );
      payload = QRPayload(
        version: 2,
        ip: '127.0.0.1',
        port: port,
        token: token,
        sessionId: indexed.manifest.sessionId,
        mode: 'http-lan',
        tlsFingerprint: server!.tlsFingerprint!,
      );
    }

    /// A real receiver. [onRequest] runs before each request leaves, so a test
    /// can cut the transfer at an exact moment.
    QhtpReceiverClient client({
      void Function(String path)? onRequest,
      DiskSpaceProbe? diskSpace,
    }) {
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add((
              path: options.uri.path,
              range: options.headers['Range'] as String?,
              status: null,
            ));
            onRequest?.call(options.uri.path);
            handler.next(options);
          },
          onResponse: (response, handler) {
            statuses[response.requestOptions.uri.path] =
                response.statusCode ?? -1;
            handler.next(response);
          },
        ));
      return QhtpReceiverClient(
        dioClient: dio,
        store: SessionStateStore(storeDirectory: state.path),
        diskSpace: diskSpace,
      );
    }

    setUp(() async {
      requests.clear();
      statuses.clear();
      source = Directory(at('qhtp_src'))..createSync();
      target = Directory(at('qhtp_dst'))..createSync();
      state = Directory(at('qhtp_state'))..createSync();
    });

    tearDown(() async {
      await server?.stop();
      server = null;
    });

    String shaOf(List<int> bytes) => sha256.convert(bytes).toString();

    testWidgets('an interrupted download resumes through a Range request and '
        'the file is identical', (tester) async {
      final bytes = _bytes(1024 * 1024, 12345);
      await serve({'video_resume.bin': bytes});

      // The first 300 KB are already on disk as a partial, as after a cut.
      const have = 300 * 1024;
      final partial = File(received('video_resume.bin.qs.partial'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes.sublist(0, have));

      final probe = _RecordingProbe(ChannelDiskSpaceProbe());
      final result = await client(diskSpace: probe).downloadSession(
        payload: payload,
        targetBaseDir: target.path,
      );

      result.fold(
        (failure) => fail('receive failed: ${failure.message} (${failure.code})'),
        (_) {},
      );
      final fileRequest = requests.firstWhere(
          (r) => r.path.contains('/v2/files/') && !r.path.endsWith('/digest'));
      expect(fileRequest.range, 'bytes=$have-',
          reason: 'it asked for the rest, not the whole file again');
      expect(statuses[fileRequest.path], 206);

      final landed = File(received('video_resume.bin'));
      expect(landed.existsSync(), isTrue);
      expect(shaOf(landed.readAsBytesSync()), shaOf(bytes));
      expect(partial.existsSync(), isFalse);

      // The real channel probe was in the receive path and gave a number.
      expect(probe.answers, isNotEmpty,
          reason: 'the receiver never asked how much room there was');
      expect(probe.answers.every((a) => a.space.isKnown), isTrue,
          reason: probe.answers.map((a) => a.space.unknownReason).join('; '));
      print('QHTP_RESUME range=${fileRequest.range} '
          'status=${statuses[fileRequest.path]} '
          'sha256=${shaOf(bytes).substring(0, 16)}… '
          'disk_checks=${probe.answers.length}');
    });

    testWidgets('first file delivered, transfer cut, file deleted, resumed: '
        'the file is fetched again and its sha256 matches', (tester) async {
      final a = _bytes(300 * 1024, 1);
      final b = _bytes(120 * 1024, 2);
      await serve({'a.bin': a, 'b.bin': b});

      // First run: a.bin arrives; the transfer is cut when b.bin is asked for.
      late QhtpReceiverClient first;
      first = client(onRequest: (path) {
        if (path.contains('/v2/files/') &&
            !path.endsWith('/digest') &&
            p.url.basename(path) == idOf('b.bin')) {
          first.cancel();
        }
      });
      final cut = await first.downloadSession(
          payload: payload, targetBaseDir: target.path);
      expect(cut.isRight, isFalse, reason: 'the cut must end the first run');
      expect(shaOf(File(received('a.bin')).readAsBytesSync()), shaOf(a),
          reason: 'the first file was delivered whole before the cut');
      expect(File(received('b.bin')).existsSync(), isFalse);
      final firstRunAs = fileRequestsFor('a.bin');
      expect(firstRunAs, 1);

      // The user deletes what arrived.
      File(received('a.bin')).deleteSync();

      // Resume with a new receiver and the same saved state.
      requests.clear();
      final probe = _RecordingProbe(ChannelDiskSpaceProbe());
      final resumed = await client(diskSpace: probe).downloadSession(
          payload: payload, targetBaseDir: target.path);
      resumed.fold(
        (failure) =>
            fail('resume failed: ${failure.message} (${failure.code})'),
        (_) {},
      );

      expect(fileRequestsFor('a.bin'), 1,
          reason: 'the deleted file is fetched again, not claimed as received');
      expect(fileRequestsFor('b.bin'), 1);
      expect(shaOf(File(received('a.bin')).readAsBytesSync()), shaOf(a));
      expect(shaOf(File(received('b.bin')).readAsBytesSync()), shaOf(b));
      expect(File(received('a (1).bin')).existsSync(), isFalse,
          reason: 'the name was free again, so it is reused');
      expect(probe.answers.every((x) => x.space.isKnown), isTrue);
      print('QHTP_CUT_DELETE_RESUME a_requests_first=$firstRunAs '
          'a_requests_resume=${fileRequestsFor('a.bin')} '
          'sha256_a=${shaOf(a).substring(0, 16)}… '
          'sha256_b=${shaOf(b).substring(0, 16)}…');
    });
  });
}

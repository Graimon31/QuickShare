// OPS-01 at the bottom: how much room there is, and what "the disk is full"
// looks like on each platform.
//
// The native halves (macOS/iOS URL resource values, Android StatFs, Windows
// GetDiskFreeSpaceExW) cannot run in a Dart unit test. What can is everything
// around them: the Dart side of the channel, the `df` parser, the errno
// tables, the arithmetic — and the rule that none of it may ever throw.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/storage/disk_space.dart';
import 'package:quickshare/core/storage/storage_failure.dart';

FileSystemException _failure(int code, [String message = 'write failed']) =>
    FileSystemException(message, '/x', OSError('os says', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isDiskFull', () {
    test('a Dio error wrapping ENOSPC is classified as disk full', () {
      final wrapped = DioException(
        requestOptions: RequestOptions(path: '/file'),
        error: _failure(28),
      );
      expect(classifyStorageError(wrapped, os: 'linux')?.code,
          FailureCode.diskFull);
      expect(
          classifyStorageError(
              DioException(requestOptions: RequestOptions(path: '/file')),
              os: 'linux'),
          isNull);
    });
    test('POSIX ENOSPC is disk full', () {
      for (final os in ['macos', 'linux', 'android', 'ios']) {
        expect(isDiskFull(_failure(28), os: os), isTrue, reason: os);
      }
    });

    test('Windows ERROR_DISK_FULL (112) and ERROR_HANDLE_DISK_FULL (39)', () {
      expect(isDiskFull(_failure(112), os: 'windows'), isTrue);
      expect(isDiskFull(_failure(39), os: 'windows'), isTrue);
    });

    test('the same numbers mean something else off Windows', () {
      // 39 is ENOTEMPTY on Linux and macOS: a failed folder rename, not a
      // full disk. 112 is EHOSTDOWN on macOS.
      expect(isDiskFull(_failure(39), os: 'macos'), isFalse);
      expect(isDiskFull(_failure(39), os: 'linux'), isFalse);
      expect(isDiskFull(_failure(112), os: 'macos'), isFalse);
    });

    test('a quota that is used up is a full disk to the person holding it', () {
      expect(isDiskFull(_failure(69), os: 'macos'), isTrue); // EDQUOT, BSD
      expect(isDiskFull(_failure(122), os: 'linux'), isTrue); // EDQUOT, Linux
      expect(isDiskFull(_failure(122), os: 'windows'), isFalse);
    });

    test('the OS\'s own words count when no code came through', () {
      expect(
          isDiskFull(const FileSystemException('No space left on device'),
              os: 'linux'),
          isTrue);
      expect(
          isDiskFull(
              const FileSystemException('write failed', '/x',
                  OSError('There is not enough space on the disk.', 0)),
              os: 'windows'),
          isTrue);
    });

    test('other failures are not disk full', () {
      expect(
          isDiskFull(_failure(13, 'Permission denied'), os: 'macos'), isFalse);
      expect(isDiskFull(_failure(2, 'No such file'), os: 'linux'), isFalse);
      expect(
          isDiskFull(const FileSystemException('boom'), os: 'macos'), isFalse);
    });
  });

  group('df output', () {
    test('a plain Linux line', () {
      const out =
          'Filesystem     1024-blocks      Used Available Capacity Mounted on\n'
          '/dev/nvme0n1p2   491270144 301000000 165000000      65% /home\n';
      expect(DfDiskSpaceProbe.parse(out).availableBytes, 165000000 * 1024);
    });

    test('macOS names with spaces in the mount point', () {
      const out =
          'Filesystem   1024-blocks      Used Available Capacity  Mounted on\n'
          '/dev/disk3s5   494384795 400000000  80000000    84%    '
          '/Volumes/Macintosh HD - Data\n';
      expect(DfDiskSpaceProbe.parse(out).availableBytes, 80000000 * 1024);
    });

    test('a filesystem name with spaces, and a mount that looks like a column',
        () {
      const out = 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          'map auto_home 0 0 0 100% /System/Volumes/Data/home\n'
          '//nas/My Share 1000 400 600 40% /mnt/100% full 5 6 7 8%\n';
      expect(DfDiskSpaceProbe.parse(out).availableBytes, 600 * 1024,
          reason: 'the last entry is the one asked about');
      expect(
          DfDiskSpaceProbe.parse(
                  'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
                  'map auto_home 0 0 0 100% /home\n')
              .availableBytes,
          0);
    });

    test('a capacity shown as a dash (a pseudo filesystem)', () {
      const out = 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          'fuse 100 40 60 - /mnt/fuse\n';
      expect(DfDiskSpaceProbe.parse(out).availableBytes, 60 * 1024);
    });

    test('garbage is unknown, with a reason, never a number', () {
      for (final out in ['', 'df: command not found', 'a b c\n', '\n\n']) {
        final parsed = DfDiskSpaceProbe.parse(out);
        expect(parsed.isKnown, isFalse, reason: out);
        expect(parsed.unknownReason, isNotEmpty);
      }
    });

    test('a failing df is unknown', () async {
      final probe = DfDiskSpaceProbe(
          run: (exe, args) async =>
              ProcessResult(1, 1, '', 'df: no such file'));
      final space = await probe.available('/nonexistent');
      expect(space.isKnown, isFalse);
      expect(space.unknownReason, contains('df'));
    });

    test('a missing df is unknown', () async {
      final probe = DfDiskSpaceProbe(
          run: (exe, args) async => throw const ProcessException('df', []));
      expect((await probe.available('/x')).isKnown, isFalse);
    });

    test('a df that hangs is given up on', () async {
      final probe = DfDiskSpaceProbe(
        timeout: const Duration(milliseconds: 50),
        run: (exe, args) => Future<ProcessResult>.delayed(
            const Duration(seconds: 5), () => ProcessResult(1, 0, '', '')),
      );
      expect((await probe.available('/x')).isKnown, isFalse);
    });

    test('the real df on this machine parses to a believable number', () async {
      // The parser is only as good as the output it meets. This is the one
      // test that feeds it what df actually prints here.
      final space =
          await DfDiskSpaceProbe().available(Directory.systemTemp.path);
      expect(space.isKnown, isTrue, reason: '${space.unknownReason}');
      expect(space.availableBytes, greaterThan(0));
      expect(space.availableBytes! % 1024, 0);
    }, skip: Platform.isWindows ? 'no df on Windows' : false);

    test('asks df for POSIX output in kilobytes about exactly that path',
        () async {
      late List<String> seen;
      final probe = DfDiskSpaceProbe(run: (exe, args) async {
        seen = [exe, ...args];
        return ProcessResult(1, 0, '', '');
      });
      await probe.available('/home/me/My Files');
      expect(seen, ['df', '-Pk', '--', '/home/me/My Files']);
    });
  });

  group('the native channel', () {
    const channel = MethodChannel('quickshare/disk_space_test');

    Future<DiskSpace> ask(Future<Object?>? Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      return ChannelDiskSpaceProbe(channel: channel).available('/x');
    }

    test('an integer answer is the free space', () async {
      final space = await ask((call) async {
        expect(call.method, 'availableBytes');
        expect(call.arguments, {'path': '/x'});
        return 123456789;
      });
      expect(space.availableBytes, 123456789);
    });

    test('zero is a real answer: the disk is full', () async {
      expect((await ask((call) async => 0)).availableBytes, 0);
    });

    test('no handler on this platform (or in a worker isolate) is unknown',
        () async {
      final space = await ChannelDiskSpaceProbe(
              channel: const MethodChannel('quickshare/not_registered'))
          .available('/x');
      expect(space.isKnown, isFalse);
      expect(space.unknownReason, isNotEmpty);
    });

    test('an error from the native side is unknown, not a crash', () async {
      final space = await ask(
          (call) async => throw PlatformException(code: 'UNAVAILABLE'));
      expect(space.isKnown, isFalse);
    });

    test('nonsense is unknown: null, negative, a string', () async {
      for (final answer in <Object?>[null, -5, 'lots', 1.5]) {
        final space = await ask((call) async => answer);
        expect(space.isKnown, isFalse, reason: '$answer');
      }
    });
  });

  group('the probe for this platform', () {
    test('never throws, whatever the path', () async {
      final probe = DiskSpaceProbe.forCurrentPlatform();
      for (final path in [
        '',
        '/nonexistent/for/sure',
        Directory.systemTemp.path
      ]) {
        final space = await probe.available(path);
        expect(space.isKnown || (space.unknownReason ?? '').isNotEmpty, isTrue);
      }
    });
  });

  group('the check before a transfer', () {
    DiskSpaceProbe fixed(DiskSpace s) => _Fixed(s);

    test('needs the remaining bytes plus the margin', () async {
      final check = await checkFreeSpace(
          fixed(const DiskSpace.known(1000)), '/x',
          remainingBytes: 400, margin: 100);
      expect(check.required, 500);
      expect(check.isShort, isFalse);
      expect(check.isUnknown, isFalse);
    });

    test('exactly enough passes; one byte less does not', () async {
      final exact = await checkFreeSpace(
          fixed(const DiskSpace.known(500)), '/x',
          remainingBytes: 400, margin: 100);
      expect(exact.isShort, isFalse);
      final short = await checkFreeSpace(
          fixed(const DiskSpace.known(499)), '/x',
          remainingBytes: 400, margin: 100);
      expect(short.isShort, isTrue);
      expect(short.space.availableBytes, 499);
    });

    test('the default margin is 64 MiB', () async {
      final check = await checkFreeSpace(fixed(const DiskSpace.known(0)), '/x',
          remainingBytes: 0);
      expect(check.required, 64 * 1024 * 1024);
    });

    test('unknown is neither short nor a pass', () async {
      final check = await checkFreeSpace(
          fixed(const DiskSpace.unknown('no channel')), '/x',
          remainingBytes: 1 << 40);
      expect(check.isShort, isFalse);
      expect(check.isUnknown, isTrue);
    });

    test('a probe that throws is unknown too', () async {
      final check = await checkFreeSpace(_Throws(), '/x', remainingBytes: 1);
      expect(check.isUnknown, isTrue);
    });

    test('requireFreeSpace throws the typed error with both numbers', () async {
      try {
        await requireFreeSpace(fixed(const DiskSpace.known(10)), '/x',
            remainingBytes: 1000, margin: 0);
        fail('should have refused');
      } on NotEnoughSpaceException catch (e) {
        expect(e.needed, 1000);
        expect(e.available, 10);
        expect(e.failureCode, FailureCode.notEnoughSpaceFor(1000, 10));
      }
    });

    test('requireFreeSpace lets an unknown through', () async {
      await requireFreeSpace(fixed(const DiskSpace.unknown('x')), '/x',
          remainingBytes: 1 << 40);
    });
  });

  group('failure codes that carry sizes', () {
    test('round trip', () {
      final code = FailureCode.notEnoughSpaceFor(5000, 120);
      expect(FailureCode.parseNotEnoughSpace(code),
          (needed: 5000, available: 120));
    });

    test('the bare code and unrelated ones carry none', () {
      expect(
          FailureCode.parseNotEnoughSpace(FailureCode.notEnoughSpace), isNull);
      expect(FailureCode.parseNotEnoughSpace(null), isNull);
      expect(FailureCode.parseNotEnoughSpace('senderUnreachable'), isNull);
      expect(FailureCode.parseNotEnoughSpace('notEnoughSpace:x:y'), isNull);
    });
  });
}

class _Fixed extends DiskSpaceProbe {
  _Fixed(this.answer);
  final DiskSpace answer;
  @override
  Future<DiskSpace> available(String path) async => answer;
}

class _Throws extends DiskSpaceProbe {
  @override
  Future<DiskSpace> available(String path) async => throw StateError('boom');
}

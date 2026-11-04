import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/security/path_sanitizer.dart';

void main() {
  group('PathSanitizer', () {
    group('Windows reserved device names', () {
      test('identifies reserved names regardless of case or extension', () {
        expect(PathSanitizer.isWindowsReserved('CON'), isTrue);
        expect(PathSanitizer.isWindowsReserved('con.txt'), isTrue);
        expect(PathSanitizer.isWindowsReserved('prn'), isTrue);
        expect(PathSanitizer.isWindowsReserved('PRN.pdf'), isTrue);
        expect(PathSanitizer.isWindowsReserved('aux'), isTrue);
        expect(PathSanitizer.isWindowsReserved('nul'), isTrue);
        expect(PathSanitizer.isWindowsReserved('com1'), isTrue);
        expect(PathSanitizer.isWindowsReserved('COM9.tar.gz'), isTrue);
        expect(PathSanitizer.isWindowsReserved('lpt1'), isTrue);
        expect(PathSanitizer.isWindowsReserved('LPT9'), isTrue);
      });

      test('identifies non-reserved names with similar prefixes', () {
        expect(PathSanitizer.isWindowsReserved('contact.txt'), isFalse);
        expect(PathSanitizer.isWindowsReserved('pronto.doc'), isFalse);
        expect(PathSanitizer.isWindowsReserved('auxiliary'), isFalse);
        expect(PathSanitizer.isWindowsReserved('null.txt'), isFalse);
        expect(PathSanitizer.isWindowsReserved('common.log'), isFalse);
        expect(PathSanitizer.isWindowsReserved('com10.dat'), isFalse);
        expect(PathSanitizer.isWindowsReserved('lpt0'), isFalse);
      });

      test('sanitizes Windows reserved names by prepending underscore', () {
        expect(PathSanitizer.sanitizeSegment('con.txt'), equals('_con.txt'));
        expect(PathSanitizer.sanitizeSegment('NUL'), equals('_NUL'));
        expect(PathSanitizer.sanitizeSegment('COM1.png'), equals('_COM1.png'));
        expect(PathSanitizer.sanitizeSegment('aux.dat'), equals('_aux.dat'));
      });
    });

    group('Windows quirks that a plain blocklist misses', () {
      test('the console devices are reserved', () {
        expect(PathSanitizer.isWindowsReserved(r'CONIN$'), isTrue);
        expect(PathSanitizer.isWindowsReserved(r'conout$'), isTrue);
        expect(PathSanitizer.isWindowsReserved(r'CONIN$.txt'), isTrue);
        expect(PathSanitizer.sanitizeSegment(r'CONOUT$'), r'_CONOUT$');
      });

      test('a device name is still a device with spaces or a dot after it', () {
        expect(PathSanitizer.isWindowsReserved('con .txt'), isTrue);
        expect(PathSanitizer.isWindowsReserved('nul.'), isTrue);
        expect(PathSanitizer.isWindowsReserved('COM\u00B9'), isTrue);
        expect(PathSanitizer.isWindowsReserved('LPT\u00B2.log'), isTrue);
        expect(PathSanitizer.isWindowsReserved('CONIN'), isFalse);
      });

      test('trailing dots and spaces are dropped, as Windows would anyway', () {
        // Windows silently removes them, so "report.pdf." and "report.pdf"
        // are one name there and two here — two files fighting over one.
        expect(PathSanitizer.sanitizeSegment('report.pdf.'), 'report.pdf');
        expect(PathSanitizer.sanitizeSegment('report.pdf. . '), 'report.pdf');
        expect(PathSanitizer.sanitizeSegment('notes   '), 'notes');
        expect(PathSanitizer.sanitizeSegment('con.'), '_con');
        expect(PathSanitizer.sanitizeSegment('. . .'), 'item');
      });

      test('a leading dot is a hidden file, not something to strip', () {
        expect(PathSanitizer.sanitizeSegment('.gitignore'), '.gitignore');
      });

      group('cutting a long name down', () {
        // The cut can land anywhere, and "anywhere" includes right after a
        // space or a dot. Tidying only before the cut left a name that
        // Windows would then shorten behind the program's back.
        const limit = PathSanitizer.maxSegmentBytes;

        test('does not leave a trailing space', () {
          final name = PathSanitizer.sanitizeSegment(
              '${'a' * (limit - 1)} ${'b' * 50}');

          expect(name, 'a' * (limit - 1));
        });

        test('does not leave a trailing dot', () {
          // The cut falls right after the dot inside the name. What follows the
          // last dot is far too long to be an extension, so it is cut too.
          final name = PathSanitizer.sanitizeSegment(
              '${'a' * (limit - 1)}.${'b' * 10}.${'c' * 80}');

          expect(name, 'a' * (limit - 1));
        });

        test('does not leave a run of dots and spaces', () {
          final name = PathSanitizer.sanitizeSegment(
              '${'a' * (limit - 3)}. . ${'b' * 10}.${'c' * 80}');

          expect(name, 'a' * (limit - 3));
        });

        test('a name cut down to a device name is still not one', () {
          // `com1` followed by more spaces than fit: once cut, nothing but
          // spaces follows the device name, and Windows opens the device.
          final name = PathSanitizer.sanitizeSegment(
              'com1${' ' * (limit + 20)}x');

          expect(PathSanitizer.isWindowsReserved(name), isFalse,
              reason: '"$name"');
          expect(name, startsWith('_'));
        });

        test('keeps the extension and is exactly as long as allowed', () {
          final name = PathSanitizer.sanitizeSegment('${'ü' * 300}.jpg');

          expect(name, endsWith('.jpg'));
          expect(utf8.encode(name).length, lessThanOrEqualTo(limit));
          expect(utf8.encode(name).length, greaterThan(limit - 2),
              reason: 'no more than one two-byte letter is given up');
        });

        test('whatever it is given, a cleaned name is a name', () {
          final random = Random(20261103);
          const alphabet = ['a', 'b', ' ', '.', '.', ' ', 'ü', '漢', 'c', 'o', 'n', '1', '_'];
          for (var i = 0; i < 4000; i++) {
            final raw = StringBuffer();
            for (var n = random.nextInt(400); n > 0; n--) {
              raw.write(alphabet[random.nextInt(alphabet.length)]);
            }
            final maxBytes = [255, 237, 40, 12, 6][random.nextInt(5)];

            final name =
                PathSanitizer.sanitizeSegment('$raw', maxBytes: maxBytes);

            final why = 'from "$raw" at $maxBytes bytes: "$name"';
            expect(name, isNotEmpty, reason: why);
            expect(utf8.encode(name).length, lessThanOrEqualTo(maxBytes),
                reason: why);
            expect(name, isNot(matches(r'[. ]$')), reason: why);
            expect(name, isNot(matches(r'^\s')), reason: why);
            expect(PathSanitizer.isWindowsReserved(name), isFalse, reason: why);
          }
        });
      });
    });

    group('sanitizeSegment', () {
      test('strips illegal characters and control codes', () {
        expect(PathSanitizer.sanitizeSegment('hello:world?.txt'),
            equals('hello_world_.txt'));
        expect(PathSanitizer.sanitizeSegment('a*b"c<d>e|f'), equals('a_b_c_d_e_f'));
      });

      test('falls back to defaultName if empty or only dots', () {
        expect(PathSanitizer.sanitizeSegment(''), equals('item'));
        expect(PathSanitizer.sanitizeSegment('...'), equals('item'));
        expect(PathSanitizer.sanitizeSegment('', defaultName: 'file'), equals('file'));
      });

      test('truncates byte length while preserving extension', () {
        final long = '${'a' * 400}.jpg';
        final sanitized = PathSanitizer.sanitizeSegment(long);
        expect(sanitized.endsWith('.jpg'), isTrue);
        expect(sanitized.length, lessThanOrEqualTo(AppConstants.qhtpMaxNameBytes));
      });
    });

    group('sanitizeRelativePath', () {
      test('normalizes separators and removes traversal segments', () {
        const path = r'foo\..\bar\./baz.txt';
        final sanitized = PathSanitizer.sanitizeRelativePath(path);
        expect(sanitized.contains('..'), isFalse);
        expect(sanitized.contains('/baz.txt'), isTrue);
      });

      test('returns defaultName if empty', () {
        expect(PathSanitizer.sanitizeRelativePath(''), equals('item'));
        expect(PathSanitizer.sanitizeRelativePath('../..', defaultName: 'received_file'),
            equals('received_file'));
      });
    });

    group('resolveSafePath', () {
      test('throws on empty baseDir', () {
        expect(() => PathSanitizer.resolveSafePath('foo.txt', ''),
            throwsA(isA<Exception>()));
      });

      test('resolves within target base directory', () {
        final base = Directory.systemTemp.createTempSync('path_test_');
        addTearDown(() => base.deleteSync(recursive: true));

        final res = PathSanitizer.resolveSafePath('docs/report.pdf', base.path);
        expect(res.startsWith(base.path), isTrue);
        expect(res.endsWith('docs/report.pdf'), isTrue);
      });

      test('neutralizes traversal attempts', () {
        final base = Directory.systemTemp.createTempSync('path_test_');
        addTearDown(() => base.deleteSync(recursive: true));

        final res = PathSanitizer.resolveSafePath('../../../../etc/passwd', base.path);
        expect(res.startsWith(base.path), isTrue);
        expect(res.endsWith('etc/passwd'), isTrue);
        expect(res.contains('..'), isFalse);
      });
    });
  });
}

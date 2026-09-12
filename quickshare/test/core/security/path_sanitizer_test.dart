import 'dart:io';
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

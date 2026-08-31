import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/utils/app_logger.dart';

void main() {
  String line(DateTime at, [String msg = 'something happened']) =>
      '[${at.toIso8601String()}] [INFO ] [APP] $msg';

  group('AppLogger.retainSince', () {
    test('drops entries older than the cutoff, keeps the rest', () {
      final now = DateTime(2026, 8, 31, 12);
      final cutoff = now.subtract(const Duration(days: 7));

      final lines = [
        line(now.subtract(const Duration(days: 9)), 'ancient'),
        line(now.subtract(const Duration(days: 8)), 'old'),
        line(now.subtract(const Duration(days: 3)), 'recent'),
        line(now, 'fresh'),
      ];

      final kept = AppLogger.retainSince(lines, cutoff);

      expect(kept, hasLength(2));
      expect(kept[0], contains('recent'));
      expect(kept[1], contains('fresh'));
    });

    test('a wrapped stack trace follows its entry', () {
      final now = DateTime(2026, 8, 31, 12);
      final cutoff = now.subtract(const Duration(days: 7));

      final lines = [
        line(now.subtract(const Duration(days: 10)), 'old error'),
        '#0      some.old.frame (file.dart:1)',
        '#1      another.old.frame (file.dart:2)',
        line(now, 'fresh error'),
        '#0      some.fresh.frame (file.dart:3)',
      ];

      final kept = AppLogger.retainSince(lines, cutoff);

      expect(kept, [
        line(now, 'fresh error'),
        '#0      some.fresh.frame (file.dart:3)',
      ]);
    });

    test('leaves a log entirely within the window untouched', () {
      final now = DateTime(2026, 8, 31, 12);
      final cutoff = now.subtract(const Duration(days: 7));
      final lines = [
        line(now.subtract(const Duration(days: 2))),
        line(now.subtract(const Duration(days: 1))),
        '',
      ];
      expect(AppLogger.retainSince(lines, cutoff), lines);
    });

    test('an entry exactly at the cutoff is kept', () {
      final now = DateTime(2026, 8, 31, 12);
      final cutoff = now.subtract(const Duration(days: 7));
      final kept = AppLogger.retainSince([line(cutoff, 'edge')], cutoff);
      expect(kept, hasLength(1));
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  testWidgets('app fonts load from bundled assets without network',
      (tester) async {
    final original = GoogleFonts.config.allowRuntimeFetching;
    GoogleFonts.config.allowRuntimeFetching = false;
    addTearDown(() => GoogleFonts.config.allowRuntimeFetching = original);

    await tester.runAsync(() async {
      final styles = [
        for (final weight in [
          FontWeight.w400,
          FontWeight.w500,
          FontWeight.w600,
          FontWeight.w700,
        ])
          GoogleFonts.inter(fontWeight: weight),
        GoogleFonts.firaCode(),
        GoogleFonts.robotoMono(),
      ];
      await GoogleFonts.pendingFonts(styles);
    });
  });
}

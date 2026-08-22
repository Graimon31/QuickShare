// Every sender/receiver route that appears as a `context.go(...)` target
// anywhere in the app must actually resolve, or go_router falls back to its
// `errorBuilder` — the "Oops! Page not found" screen a user can hit mid-transfer
// with no indication of what actually went wrong underneath.
//
// This caught a real bug: `fallback`, `local-network` and `qr` were declared
// as *siblings* of the `/send` GoRoute inside the sender ShellRoute, with
// relative paths. A relative path only resolves against its parent GoRoute —
// as a sibling it matched nothing at all, not `/send/qr`, not even `/qr`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/router/app_router.dart';

void main() {
  setUp(() async {
    await ServiceLocator.init();
  });

  tearDown(() async {
    await sl.reset();
  });

  // Every literal path string passed to `context.go(...)` in
  // lib/features/{sender,receiver}/. Extracted once so the list is the thing
  // that goes stale — not a hand-maintained duplicate of app_router.dart.
  const senderAndReceiverRoutes = [
    '/',
    '/send',
    '/send/qr',
    '/send/fallback',
    '/send/local-network',
    '/send/bluetooth',
    '/send/progress',
    '/receive',
    '/receive/bluetooth',
    '/receive/code',
    '/receive/preview',
    '/receive/download',
    '/receive/complete',
  ];

  for (final path in senderAndReceiverRoutes) {
    testWidgets('$path resolves to a real page, not the error screen',
        (tester) async {
      // Not pumpAndSettle(): several pages carry decorative animations
      // (gradient/particle effects) that repeat forever, which pumpAndSettle
      // waits on indefinitely. A handful of fixed frames is enough for
      // go_router to land on a page and paint it.
      await tester.pumpWidget(
        MaterialApp.router(routerConfig: AppRouter.router),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      AppRouter.router.go(path);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(
        find.text('Page not found'),
        findsNothing,
        reason: '$path hit the global errorBuilder',
      );
    });
  }
}

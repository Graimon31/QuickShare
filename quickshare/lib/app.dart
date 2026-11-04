import 'package:flutter/material.dart';
import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/localization/locale_controller.dart';
import 'package:quickshare/core/network/hotspot_lifecycle_guard.dart';
import 'package:quickshare/core/router/app_router.dart';
import 'package:quickshare/core/theme/app_theme.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

class DirectDropApp extends StatefulWidget {
  const DirectDropApp({super.key});

  @override
  State<DirectDropApp> createState() => _DirectDropAppState();
}

class _DirectDropAppState extends State<DirectDropApp> {
  // App-level rather than page-level: the hotspot outlives the screen that
  // raised it — the transfer moves on to the progress route while the network
  // stays up.
  final _hotspotGuard = HotspotLifecycleGuard();

  @override
  void initState() {
    super.initState();
    _hotspotGuard.attach();
  }

  @override
  void dispose() {
    _hotspotGuard.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds the whole MaterialApp on a language change rather than
    // reaching for a narrower InheritedWidget: `locale` is a MaterialApp
    // constructor parameter, and every localized string on screen has to
    // repaint together the moment someone picks a different language in
    // Settings — there is no meaningfully smaller scope to target.
    return ValueListenableBuilder<Locale?>(
      valueListenable: sl<LocaleController>(),
      builder: (context, locale, _) => MaterialApp.router(
        title: 'DirectDrop',
        theme: AppTheme.lightTheme(),
        darkTheme: AppTheme.darkTheme(),
        // DirectDrop's glass UI is intentionally dark-first across platforms.
        // Keeping one mode prevents light Material surfaces from appearing
        // between dark transfer screens.
        themeMode: ThemeMode.dark,
        routerConfig: AppRouter.router,
        debugShowCheckedModeBanner: false,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }
}

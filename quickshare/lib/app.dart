import 'dart:async';

import 'package:flutter/material.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
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
  final _deepLinks = DeepLinkService();
  // App-level rather than page-level: the hotspot outlives the screen that
  // raised it — the transfer moves on to the progress route while the network
  // stays up.
  final _hotspotGuard = HotspotLifecycleGuard();
  StreamSubscription<InternetInvite>? _inviteSub;
  StreamSubscription<ShareLinkContents>? _payloadSub;

  @override
  void initState() {
    super.initState();
    // A share link opened from Finder/Mail/Messages routes straight into the
    // receive flow, whether the app was already running or launched by it.
    // Prefer full invites (room + optional sig=) so Internet receive dials the
    // sender's signaling host, not the phone's localhost.
    _inviteSub = _deepLinks.invites.listen((invite) {
      final q = StringBuffer('/receive/code?room=${invite.roomCode}');
      if (invite.signalingUrl != null && invite.signalingUrl!.isNotEmpty) {
        q.write('&sig=${Uri.encodeComponent(invite.signalingUrl!)}');
      }
      AppRouter.router.go(q.toString());
    });
    // Payload links carry the QR itself (`?p=`). Receive/code submits that
    // string the same way a paste would.
    _payloadSub = _deepLinks.sharePayloads.listen((share) {
      final q = <String, String>{'p': share.qrPayload};
      if (share.name != null) q['n'] = share.name!;
      if (share.bytes != null) q['s'] = '${share.bytes}';
      if (share.itemCount != null) q['c'] = '${share.itemCount}';
      AppRouter.router.go(Uri(path: '/receive/code', queryParameters: q).toString());
    });
    _deepLinks.init();
    _hotspotGuard.attach();
  }

  @override
  void dispose() {
    _inviteSub?.cancel();
    _payloadSub?.cancel();
    _hotspotGuard.detach();
    _deepLinks.dispose();
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

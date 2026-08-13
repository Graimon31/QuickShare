import 'dart:async';

import 'package:flutter/material.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/core/router/app_router.dart';
import 'package:quickshare/core/theme/app_theme.dart';

class QuickShareApp extends StatefulWidget {
  const QuickShareApp({super.key});

  @override
  State<QuickShareApp> createState() => _QuickShareAppState();
}

class _QuickShareAppState extends State<QuickShareApp> {
  final _deepLinks = DeepLinkService();
  StreamSubscription<InternetInvite>? _sub;

  @override
  void initState() {
    super.initState();
    // A share link opened from Finder/Mail/Messages routes straight into the
    // receive flow, whether the app was already running or launched by it.
    // Prefer full invites (room + optional sig=) so Internet receive dials the
    // sender's signaling host, not the phone's localhost.
    _sub = _deepLinks.invites.listen((invite) {
      final q = StringBuffer('/receive/code?room=${invite.roomCode}');
      if (invite.signalingUrl != null && invite.signalingUrl!.isNotEmpty) {
        q.write('&sig=${Uri.encodeComponent(invite.signalingUrl!)}');
      }
      AppRouter.router.go(q.toString());
    });
    _deepLinks.init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _deepLinks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'QuickShare',
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      // QuickShare's glass UI is intentionally dark-first across platforms.
      // Keeping one mode prevents light Material surfaces from appearing
      // between dark transfer screens.
      themeMode: ThemeMode.dark,
      routerConfig: AppRouter.router,
      debugShowCheckedModeBanner: false,
    );
  }
}

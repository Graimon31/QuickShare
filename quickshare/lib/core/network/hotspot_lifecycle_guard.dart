import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Makes sure a hotspot never outlives the app that raised it.
///
/// `MainActivity.onDestroy` already closes the reservation, but that only fires
/// when Android actually destroys the activity — which it may defer, and which
/// some vendor builds handle loosely. Meanwhile the Wi-Fi radio sits in access
/// point mode, which costs real battery.
///
/// The two lifecycle states are treated differently on purpose:
///
/// * `detached` — the process is going away. Stop immediately.
/// * `paused` — the user switched apps. **Not** a reason to stop: they may be
///   copying a password or answering a message mid-transfer, and tearing the
///   network down under them would be worse than the battery it saves. A grace
///   period runs instead, cancelled the moment they come back.
class HotspotLifecycleGuard with WidgetsBindingObserver {
  final LocalHotspotService _hotspot;

  /// How long the app may sit in the background before the network is dropped.
  final Duration grace;

  Timer? _graceTimer;

  HotspotLifecycleGuard({
    LocalHotspotService? hotspot,
    this.grace = const Duration(minutes: 2),
  }) : _hotspot = hotspot ?? LocalHotspotService();

  void attach() => WidgetsBinding.instance.addObserver(this);

  void detach() {
    _graceTimer?.cancel();
    _graceTimer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_graceTimer?.isActive ?? false) {
          AppLogger.info('Back in the foreground, keeping the hotspot up',
              tag: 'HOTSPOT');
        }
        _graceTimer?.cancel();
        _graceTimer = null;

      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _graceTimer?.cancel();
        _graceTimer = Timer(grace, () {
          AppLogger.info(
              'Backgrounded for ${grace.inMinutes} min — dropping the hotspot '
              'so the Wi-Fi radio does not stay in AP mode',
              tag: 'HOTSPOT');
          unawaited(_hotspot.stopHosting());
        });

      case AppLifecycleState.detached:
        _graceTimer?.cancel();
        _graceTimer = null;
        unawaited(_hotspot.stopHosting());

      case AppLifecycleState.inactive:
        // A transient state — a notification shade, an incoming call, the app
        // switcher. Acting on it would tear the network down every time the
        // user glances at a banner.
        break;
    }
  }

  /// Whether a teardown is currently pending. For tests and diagnostics.
  @visibleForTesting
  bool get isGracePeriodRunning => _graceTimer?.isActive ?? false;
}

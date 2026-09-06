import 'dart:async';

import 'package:flutter/material.dart';
import 'package:quickshare/app.dart';
import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';

import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();
  
  // Initialize dependency injection
  await ServiceLocator.init();

  // Anything left in the transfer cache belongs to a session that ended
  // without the user saving it. Normally the completion screen clears its own
  // leftovers, but iOS can kill a backgrounded app without ever delivering a
  // lifecycle event, so a previous run's cache can outlive it. Clearing at
  // startup is the only place that reliably catches those.
  //
  // Backgrounding the app does not restart it, so "minimise and come back"
  // still finds the files where they were.
  unawaited(_clearOrphanedCache());
  
  // Sweep abandoned transfers and the partial files they left behind.
  // Deliberately not awaited: it walks the filesystem, and the first frame
  // should not wait on disk. Failures inside are already swallowed there.
  unawaited(SessionStateStore().cleanExpiredStates());

  // One line saying what this device can and cannot do about local networks.
  // The same reasoning as the DIAG line for transfers: when somebody reports
  // "it finds nothing", the answer is usually a permission or a platform
  // limit, and asking them to reproduce it with a debugger attached is not a
  // support process.
  unawaited(_reportWifiCapabilities());

  runApp(const DirectDropApp());
}

Future<void> _clearOrphanedCache() async {
  try {
    final freed = await const TransferCache().clear();
    if (freed > 0) {
      AppLogger.info(
          'Startup: released ${TransferCache.formatBytes(freed)} left by a '
          'session that never finished',
          tag: 'CACHE');
    }
  } catch (e) {
    // Never block a launch over housekeeping.
    AppLogger.warning('Startup cache sweep failed: $e', tag: 'CACHE');
  }
}

/// What this device can do about local networks, and whether the system is
/// letting it.
Future<void> _reportWifiCapabilities() async {
  try {
    final hotspot = LocalHotspotService();
    final can = [
      if (hotspot.canHost) 'host',
      if (hotspot.canJoinProgrammatically) 'join',
      if (hotspot.canScanForNetworks) 'scan',
    ].join(', ');
    final authorization = await hotspot.locationAuthorization();

    if (!hotspot.canScanForNetworks) {
      AppLogger.info('Local network: can $can', tag: 'WIFI');
      return;
    }

    try {
      final all = await hotspot.scanForNetworks();
      final ours = await hotspot.scanForNetworks(prefix: SessionCode.ssidPrefix);
      AppLogger.info(
          'Local network: can $can; location $authorization; '
          '${all.length} network(s) in range, ${ours.length} of them ours',
          tag: 'WIFI');
    } on HotspotException catch (e) {
      // The interesting case: the platform can scan, but something is stopping
      // it. This is the line that explains an empty list on screen.
      AppLogger.warning(
          'Local network: can $can; location $authorization; scan refused: '
          '${e.message}',
          tag: 'WIFI');
    }
  } catch (e) {
    AppLogger.warning('Could not report Wi-Fi capabilities: $e', tag: 'WIFI');
  }
}

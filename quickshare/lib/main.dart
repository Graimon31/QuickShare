import 'dart:async';

import 'package:flutter/material.dart';
import 'package:quickshare/app.dart';
import 'package:quickshare/core/di/service_locator.dart';

import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();
  
  // Initialize dependency injection
  await ServiceLocator.init();
  
  // Sweep abandoned transfers and the partial files they left behind.
  // Deliberately not awaited: it walks the filesystem, and the first frame
  // should not wait on disk. Failures inside are already swallowed there.
  unawaited(SessionStateStore().cleanExpiredStates());

  runApp(const DirectDropApp());
}

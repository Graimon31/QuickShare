import 'package:flutter/material.dart';
import 'package:quickshare/app.dart';
import 'package:quickshare/core/di/service_locator.dart';

import 'package:quickshare/core/utils/app_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();
  
  // Initialize dependency injection
  await ServiceLocator.init();
  
  runApp(const QuickShareApp());
}

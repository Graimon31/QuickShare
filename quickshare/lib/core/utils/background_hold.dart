import 'dart:io';

import 'package:flutter/services.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// Asks iOS for a short background budget around an in-flight transfer.
///
/// No-op on every other platform, and on iOS when the plugin is missing
/// (tests). See `ios/Runner/BackgroundHold.swift`.
class BackgroundHold {
  static const _channel = MethodChannel('directdrop/background_hold');

  static Future<void> begin() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('begin');
    } on MissingPluginException {
      // Headless tests have no registrar.
    } catch (e) {
      AppLogger.warning('BackgroundHold.begin failed: $e', tag: 'WAKELOCK');
    }
  }

  static Future<void> end() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('end');
    } on MissingPluginException {
      // Headless tests have no registrar.
    } catch (e) {
      AppLogger.warning('BackgroundHold.end failed: $e', tag: 'WAKELOCK');
    }
  }
}

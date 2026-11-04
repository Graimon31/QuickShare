import 'dart:io';

import 'package:flutter/foundation.dart';

/// Whether this build runs on a computer or on a phone, as far as how a
/// transfer is *joined* is concerned.
///
/// A computer has no camera worth pointing at a screen, so it only ever types
/// the digits a sender shows; a phone may also scan. Everything that has to
/// choose between the two — the home screen, the router, the code-entry
/// screen — asks here, so there is one answer and one place a test can change
/// it.
class DevicePlatform {
  const DevicePlatform._();

  static bool? _override;

  /// Forces the answer. Tests only: the platform running a test is whatever
  /// the developer's machine is, which says nothing about the other side.
  @visibleForTesting
  static set debugIsDesktop(bool? value) => _override = value;

  static bool get isDesktop =>
      _override ??
      (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS));

  /// The negation, for the call sites that read better the other way round.
  static bool get isMobile => !isDesktop;
}

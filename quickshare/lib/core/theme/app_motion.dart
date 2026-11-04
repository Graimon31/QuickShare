import 'package:flutter/widgets.dart';

/// Shared motion vocabulary for the product. Keeping durations here prevents
/// screens from feeling like unrelated mini-apps.
class AppMotion {
  static const press = Duration(milliseconds: 100);
  static const pressOut = Duration(milliseconds: 120);
  static const page = Duration(milliseconds: 350);
  static const pageReverse = Duration(milliseconds: 250);

  /// One direction of the QR scanline; reverse playback makes a 1.8 s loop.
  static const scanCycle = Duration(milliseconds: 900);
  static const scanSuccess = Duration(milliseconds: 360);
  static const shimmer = Duration(milliseconds: 1000);
  static const progressTween = Duration(milliseconds: 450);

  /// A group of options opening under the control that owns them. Closing is
  /// quicker than opening, the way a page leaves faster than it arrives.
  static const expand = Duration(milliseconds: 280);
  static const collapse = Duration(milliseconds: 200);
  static const pageCurve = Curves.fastOutSlowIn;
  static const pageReverseCurve = pageCurve;
  static const scanCurve = Curves.easeInOutSine;
  static const progressCurve = Curves.easeOutCubic;
  static const expandCurve = Curves.easeOutCubic;
  static const collapseCurve = Curves.easeInCubic;

  static const pullSpring = SpringDescription(
    mass: 1,
    stiffness: 180,
    damping: 12,
  );

  const AppMotion._();
}

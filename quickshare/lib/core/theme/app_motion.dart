import 'package:flutter/physics.dart';
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
  static const pageCurve = Curves.fastOutSlowIn;
  static const pageReverseCurve = pageCurve;
  static const scanCurve = Curves.easeInOutSine;
  static const progressCurve = Curves.easeOutCubic;

  static const pullSpring = SpringDescription(
    mass: 1,
    stiffness: 180,
    damping: 12,
  );

  const AppMotion._();
}

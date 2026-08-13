import 'package:flutter/material.dart';

class AppColors {
  // Dark Glass brand tokens. Keep semantic names here so screens do not
  // invent a second palette with local hex values.
  static const Color voidBg = Color(0xFF0B1220);
  static const Color primary = Color(0xFF22D3EE);
  static const Color primaryDeep = Color(0xFF0EA5E9);
  static const Color primaryLight = Color(0xFF67E8F9);
  static const Color primaryDark = Color(0xFF0369A1);

  static const Color secondary = Color(0xFF34D399);
  static const Color secondaryLight = Color(0xFF6EE7B7);
  static const Color secondaryDark = Color(0xFF10B981);

  static const Color accent = Color(0xFFA7F3D0);

  // Feedback colors
  static const Color success = Color(0xFF34D399);
  static const Color error = Color(0xFFF87171);
  static const Color warning = Color(0xFFFBBF24);
  static const Color info = Color(0xFF60A5FA);

  // Surface and Background (Light)
  static const Color backgroundLight = Color(0xFFF5F5F5);
  static const Color surfaceLight = Colors.white;

  // Surface and Background (Dark)
  static const Color backgroundDark = voidBg;
  static const Color surfaceDark = Color(0xFF111B2E);

  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color.fromRGBO(255, 255, 255, 0.78);
  static const Color glassFill = Color.fromRGBO(255, 255, 255, 0.09);
  static const Color glassFillStrong = Color.fromRGBO(255, 255, 255, 0.13);
  static const Color glassBorder = Color.fromRGBO(255, 255, 255, 0.28);
  static const Color glassBorderStrong = Color.fromRGBO(255, 255, 255, 0.45);
  static const Color darkTrack = Color.fromRGBO(255, 255, 255, 0.14);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primary, primaryDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient secondaryGradient = LinearGradient(
    colors: [secondaryLight, secondaryDark],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient darkGradient = LinearGradient(
    colors: [surfaceDark, voidBg],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  const AppColors._();
}

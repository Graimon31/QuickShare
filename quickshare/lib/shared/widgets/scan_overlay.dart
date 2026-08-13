import 'dart:math' as math;
import 'dart:ui'
    show
        Canvas,
        Color,
        MaskFilter,
        Paint,
        Path,
        PathMetric,
        Rect,
        RRect,
        Size,
        BlurStyle;

import 'package:flutter/material.dart';

/// Visual tokens for the QR scanner overlay.
///
/// Keeping these values together makes the scanner easy to tune without
/// spreading paint constants throughout the rendering code.
class ScanOverlayTokens {
  static const double viewportSize = 260;
  static const double viewportInset = 48;
  static const double viewportRadius = 20;
  static const double maskOpacity = 0.58;

  static const double cornerLength = 30;
  static const double cornerStrokeWidth = 3;
  static const double cornerSuccessStrokeWidth = 3.5;
  static const double cornerPulseScale = 0.03;
  static const double cornerIdleOpacity = 0.85;
  static const double cornerSuccessCompression = 0.58;

  static const double scanlineHorizontalInset = 14;
  static const double scanlineCoreWidth = 2;
  static const double scanlineGlowWidth = 8;
  static const double scanlineGlowBlur = 7;
  static const double scanlineTrailHeight = 56;

  static const double successCheckSize = 38;
  static const double successCheckStrokeWidth = 4;
  static const Color maskColor = Colors.black;
  static const Color cornerColor = Color(0xFF22D3EE);
  static const Color scanlineCoreColor = Color(0xFFE0F2FE);
  static const Color scanlineGlowColor = Color(0xFF22D3EE);
  static const Color successColor = Color(0xFF34D399);

  const ScanOverlayTokens._();
}

/// Telegram-style QR scanner overlay rendered in a single GPU-composited
/// [CustomPaint] layer. It avoids expensive backdrop reads while preserving a
/// transparent viewport, animated brackets, scanline, and success feedback.
class ScanOverlay extends StatelessWidget {
  final Animation<double> scanAnimation;
  final Animation<double> successAnimation;
  final double cutoutSize;
  final bool isSuccess;
  final bool reduceMotion;

  const ScanOverlay({
    super.key,
    required this.scanAnimation,
    required this.successAnimation,
    this.cutoutSize = ScanOverlayTokens.viewportSize,
    this.isSuccess = false,
    this.reduceMotion = false,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ScanOverlayPainter(
          scanAnimation: scanAnimation,
          successAnimation: successAnimation,
          cutoutSize: cutoutSize,
          isSuccess: isSuccess,
          reduceMotion: reduceMotion,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _ScanOverlayPainter extends CustomPainter {
  final Animation<double> scanAnimation;
  final Animation<double> successAnimation;
  final double cutoutSize;
  final bool isSuccess;
  final bool reduceMotion;

  _ScanOverlayPainter({
    required this.scanAnimation,
    required this.successAnimation,
    required this.cutoutSize,
    required this.isSuccess,
    required this.reduceMotion,
  }) : super(
          repaint: Listenable.merge(
            reduceMotion
                ? [successAnimation]
                : [scanAnimation, successAnimation],
          ),
        );

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final viewportSize = math.min(
      cutoutSize,
      math.min(size.width, size.height) - ScanOverlayTokens.viewportInset,
    );
    final viewport = Rect.fromCenter(
      center: center,
      width: viewportSize,
      height: viewportSize,
    );
    final viewportRRect = RRect.fromRectAndRadius(
      viewport,
      const Radius.circular(ScanOverlayTokens.viewportRadius),
    );

    _drawMask(canvas, size, viewportRRect);

    final success = Curves.easeInOutCubic.transform(successAnimation.value);
    final scanProgress = reduceMotion ? 0.5 : scanAnimation.value;
    final pulse = 1 +
        math.sin(scanProgress * math.pi) * ScanOverlayTokens.cornerPulseScale;
    final opacity = ScanOverlayTokens.cornerIdleOpacity +
        (1 - ScanOverlayTokens.cornerIdleOpacity) *
            math.sin(scanProgress * math.pi);

    if (success < 1) {
      _drawCorners(
        canvas,
        viewport,
        center,
        length: ScanOverlayTokens.cornerLength * pulse * (1 - success),
        opacity: opacity * (1 - success),
        success: success,
      );
    }

    if (!isSuccess && success == 0) {
      _drawScanline(canvas, viewport, scanProgress);
    }

    if (isSuccess || success > 0) {
      _drawCheckmark(canvas, center, success);
    }
  }

  void _drawMask(Canvas canvas, Size size, RRect viewport) {
    final maskPath = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(viewport)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      maskPath,
      Paint()
        ..color = ScanOverlayTokens.maskColor
            .withOpacity(ScanOverlayTokens.maskOpacity),
    );
  }

  void _drawCorners(
    Canvas canvas,
    Rect viewport,
    Offset center, {
    required double length,
    required double opacity,
    required double success,
  }) {
    final cornerColor = Color.lerp(
      ScanOverlayTokens.cornerColor,
      ScanOverlayTokens.successColor,
      success,
    )!;
    final compressedScale =
        1 - success * ScanOverlayTokens.cornerSuccessCompression;

    final cornerPaint = Paint()
      ..color = cornerColor.withOpacity(opacity)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = success > 0
          ? ScanOverlayTokens.cornerSuccessStrokeWidth
          : ScanOverlayTokens.cornerStrokeWidth;

    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..scale(compressedScale)
      ..translate(-center.dx, -center.dy);

    void drawCorner(
        Offset origin, double horizontalDirection, double verticalDirection) {
      canvas
        ..drawLine(origin, origin.translate(length * horizontalDirection, 0),
            cornerPaint)
        ..drawLine(origin, origin.translate(0, length * verticalDirection),
            cornerPaint);
    }

    drawCorner(viewport.topLeft, 1, 1);
    drawCorner(viewport.topRight, -1, 1);
    drawCorner(viewport.bottomLeft, 1, -1);
    drawCorner(viewport.bottomRight, -1, -1);
    canvas.restore();
  }

  void _drawScanline(Canvas canvas, Rect viewport, double progress) {
    final lineY = viewport.top + viewport.height * progress;
    final start = Offset(
        viewport.left + ScanOverlayTokens.scanlineHorizontalInset, lineY);
    final end = Offset(
        viewport.right - ScanOverlayTokens.scanlineHorizontalInset, lineY);
    final trailRect = Rect.fromLTRB(
      start.dx,
      math.max(viewport.top + 8, lineY - ScanOverlayTokens.scanlineTrailHeight),
      end.dx,
      math.min(
          viewport.bottom - 8, lineY + ScanOverlayTokens.scanlineTrailHeight),
    );

    final trailPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          ScanOverlayTokens.scanlineGlowColor.withOpacity(0),
          ScanOverlayTokens.scanlineGlowColor.withOpacity(0.05),
          ScanOverlayTokens.scanlineGlowColor.withOpacity(0.20),
          ScanOverlayTokens.scanlineGlowColor.withOpacity(0.05),
          ScanOverlayTokens.scanlineGlowColor.withOpacity(0),
        ],
        stops: const [0, 0.3, 0.5, 0.7, 1],
      ).createShader(trailRect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(trailRect, const Radius.circular(18)),
      trailPaint,
    );

    final glowPaint = Paint()
      ..color = ScanOverlayTokens.scanlineGlowColor.withOpacity(0.55)
      ..strokeWidth = ScanOverlayTokens.scanlineGlowWidth
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal, ScanOverlayTokens.scanlineGlowBlur);
    canvas.drawLine(start, end, glowPaint);

    final corePaint = Paint()
      ..color = ScanOverlayTokens.scanlineCoreColor
      ..strokeWidth = ScanOverlayTokens.scanlineCoreWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(start, end, corePaint);
  }

  void _drawCheckmark(Canvas canvas, Offset center, double success) {
    final progress = ((success - 0.2) / 0.8).clamp(0.0, 1.0).toDouble();
    if (progress == 0) return;

    final half = ScanOverlayTokens.successCheckSize / 2;
    final checkPath = Path()
      ..moveTo(center.dx - half, center.dy)
      ..lineTo(center.dx - half * 0.2, center.dy + half * 0.52)
      ..lineTo(center.dx + half, center.dy - half * 0.52);
    final metric = checkPath.computeMetrics().first;
    final visiblePath = metric.extractPath(0, metric.length * progress);
    final checkPaint = Paint()
      ..color = ScanOverlayTokens.successColor.withOpacity(progress)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = ScanOverlayTokens.successCheckStrokeWidth;
    canvas.drawPath(visiblePath, checkPaint);
  }

  @override
  bool shouldRepaint(covariant _ScanOverlayPainter oldDelegate) {
    return oldDelegate.cutoutSize != cutoutSize ||
        oldDelegate.isSuccess != isSuccess ||
        oldDelegate.reduceMotion != reduceMotion;
  }
}

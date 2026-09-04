import 'package:flutter/material.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/core/theme/app_motion.dart';
import 'package:quickshare/core/utils/byte_format.dart';

class CustomProgressIndicator extends StatelessWidget {
  final double progress; // 0.0 to 1.0
  final double speedBytesPerSec;
  final String fileName;
  final bool showSpeed;
  final Color? progressColor;
  final Color? speedColor;

  const CustomProgressIndicator({
    super.key,
    required this.progress,
    required this.speedBytesPerSec,
    required this.fileName,
    this.showSpeed = true,
    this.progressColor,
    this.speedColor,
  });

  String get _speedText => ByteFormat.rate(speedBytesPerSec);

  @override
  Widget build(BuildContext context) {
    final targetProgress = progress.clamp(0.0, 1.0).toDouble();
    final indicatorColor = progressColor ?? AppColors.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (fileName.isNotEmpty) ...[
          Text(
            fileName,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 24),
        ],
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 120,
              height: 120,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: targetProgress),
                duration: AppMotion.progressTween,
                curve: AppMotion.progressCurve,
                builder: (context, value, _) => CircularProgressIndicator(
                  value: value,
                  strokeWidth: 10,
                  backgroundColor: AppColors.darkTrack,
                  valueColor: AlwaysStoppedAnimation<Color>(indicatorColor),
                ),
              ),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: targetProgress * 100),
              duration: AppMotion.progressTween,
              curve: AppMotion.progressCurve,
              builder: (context, value, _) => Text(
                '${value.round()}%',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: indicatorColor,
                    ),
              ),
            ),
          ],
        ),
        if (showSpeed) ...[
          const SizedBox(height: 16),
          Text(
            _speedText,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: speedColor ?? Colors.grey[600],
                ),
          ),
        ],
      ],
    );
  }
}

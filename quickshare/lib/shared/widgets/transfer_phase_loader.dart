import 'package:flutter/material.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/shared/widgets/skeleton_shimmer.dart';

class TransferPhaseLoader extends StatelessWidget {
  final String phaseLabel;
  final String? detail;
  final IconData icon;

  const TransferPhaseLoader({
    super.key,
    required this.phaseLabel,
    this.detail,
    this.icon = Icons.sync_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            SkeletonShimmer(
              width: 112,
              height: 112,
              borderRadius: BorderRadius.circular(56),
            ),
            Icon(icon, color: AppColors.primary, size: 34),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          phaseLabel,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 8),
          Text(
            detail!,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
        ],
      ],
    );

    return RepaintBoundary(
      child: content,
    );
  }
}

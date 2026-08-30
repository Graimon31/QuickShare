import 'package:flutter/material.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// What a waiting screen shows once its session has run out: the QR is dead,
/// and the only way forward is a freshly minted session.
class SessionExpiredPanel extends StatelessWidget {
  final VoidCallback onRefresh;

  const SessionExpiredPanel({super.key, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.timer_off_outlined,
                size: 48, color: AppColors.error),
            const SizedBox(height: 16),
            Text(
              l10n.sessionExpiredTitle,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.sessionExpiredBody,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(l10n.sessionRefresh),
            ),
          ],
        ),
      ),
    );
  }
}

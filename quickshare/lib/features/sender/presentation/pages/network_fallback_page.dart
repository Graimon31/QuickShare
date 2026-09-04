import 'package:flutter/material.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/core/utils/byte_format.dart';

/// Shown when the internet path exists but is not worth using, or does not
/// exist at all.
///
/// Deliberately not an error screen. Nothing is broken and the user did
/// nothing wrong — the network in front of them cannot carry this transfer, and
/// there is a concrete way around it. So the page leads with the way out and
/// keeps the diagnosis underneath for the people who want it.
class NetworkFallbackPage extends StatelessWidget {
  /// Null when no usable path was found at all, set when a relay was found but
  /// the session is too large for it.
  final int? sessionBytes;
  final int? limitBytes;
  final VoidCallback? onUseLocalNetwork;
  final VoidCallback? onBack;

  /// Raises a hotspot and serves the transfer over it. Absent on platforms
  /// that cannot host one — iOS has no API for it, so offering the button
  /// there would be a dead end.
  final VoidCallback? onCreateNetwork;

  const NetworkFallbackPage({
    super.key,
    this.sessionBytes,
    this.limitBytes,
    this.onUseLocalNetwork,
    this.onBack,
    this.onCreateNetwork,
  });

  bool get _isSizeLimited => sessionBytes != null && limitBytes != null;

  static String _humanBytes(int bytes) => ByteFormat.size(bytes);

  String _headline(AppLocalizations l10n) =>
      _isSizeLimited ? l10n.fallbackTooLargeTitle : l10n.fallbackNoRouteTitle;

  String _explanation(AppLocalizations l10n) => _isSizeLimited
      ? l10n.fallbackTooLargeBody(_humanBytes(sessionBytes!))
      : l10n.fallbackNoRouteBody;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: onBack == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: onBack,
              ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    _isSizeLimited
                        ? Icons.speed_rounded
                        : Icons.vpn_lock_rounded,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _headline(l10n),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _explanation(l10n),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: Colors.white70, height: 1.45),
                  ),
                  const SizedBox(height: 32),
                  _SuggestionTile(
                    icon: Icons.wifi_rounded,
                    title: l10n.fallbackWifiTitle,
                    subtitle: l10n.fallbackWifiBody,
                  ),
                  const SizedBox(height: 12),
                  _SuggestionTile(
                    icon: Icons.settings_ethernet_rounded,
                    title: l10n.fallbackVpnTitle,
                    subtitle: l10n.fallbackVpnBody,
                  ),
                  const SizedBox(height: 32),
                  if (onCreateNetwork != null)
                    FilledButton.icon(
                      onPressed: onCreateNetwork,
                      icon: const Icon(Icons.wifi_tethering_rounded),
                      label: Text(l10n.fallbackCreateNetwork),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  if (onUseLocalNetwork != null) ...[
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: onUseLocalNetwork,
                      child: Text(l10n.fallbackGoBack),
                    ),
                  ],
                  if (_isSizeLimited) ...[
                    const SizedBox(height: 20),
                    Text(
                      l10n.fallbackRelayCap(_humanBytes(limitBytes!)),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.white38),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SuggestionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: theme.colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.white54, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

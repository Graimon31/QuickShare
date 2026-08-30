import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:quickshare/core/theme/app_colors.dart';

/// A glass row showing a copyable value (link, address) with a copy button.
class CopyValueRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String copiedMessage;
  final String copyTooltip;

  const CopyValueRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.copiedMessage,
    required this.copyTooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color.fromRGBO(255, 255, 255, 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color.fromRGBO(255, 255, 255, 0.25),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.primary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  maxLines: 3,
                  style: GoogleFonts.firaCode(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.copy_rounded, color: Colors.white, size: 20),
            tooltip: copyTooltip,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              HapticFeedback.mediumImpact();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(copiedMessage),
                  backgroundColor: AppColors.secondaryDark,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

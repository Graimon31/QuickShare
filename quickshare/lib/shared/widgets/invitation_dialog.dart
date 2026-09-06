import 'package:flutter/material.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/core/transfer/transfer_invitation.dart';
import 'package:quickshare/core/utils/byte_format.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// Asks whether to accept files another device is offering.
///
/// The one place a person decides, so it has to carry what the decision needs:
/// who is asking, how many files, and how big. Somebody offered forty
/// gigabytes over a hotel Wi-Fi should find that out here rather than four
/// minutes into a transfer.
///
/// Returns true only on an explicit accept. Dismissing it — tapping outside,
/// Escape, the system back gesture — is a decline, because a transfer nobody
/// agreed to must not start on an ambiguous gesture.
Future<bool> showInvitationDialog(
  BuildContext context,
  TransferInvitation invitation,
) async {
  final accepted = await showDialog<bool>(
    context: context,
    // Dismissing is a legitimate no, so this stays true — trapping somebody in
    // a dialog to force an answer is worse than treating "go away" as one.
    barrierDismissible: true,
    builder: (context) => _InvitationDialog(invitation: invitation),
  );
  return accepted ?? false;
}

class _InvitationDialog extends StatelessWidget {
  final TransferInvitation invitation;

  const _InvitationDialog({required this.invitation});

  IconData get _icon {
    switch (invitation.senderPlatform) {
      case 'ios':
        return Icons.phone_iphone_rounded;
      case 'android':
        return Icons.phone_android_rounded;
      case 'macos':
        return Icons.laptop_mac_rounded;
      case 'windows':
        return Icons.laptop_windows_rounded;
      case 'linux':
        return Icons.computer_rounded;
      default:
        return Icons.devices_other_rounded;
    }
  }

  /// "3 files · 1.2 GB", or as much of it as the invitation actually said.
  ///
  /// A sender on an older build, or one that could not count in time, sends
  /// zeroes; inventing a number there would be worse than admitting the gap.
  String _describe(AppLocalizations l10n) {
    final parts = <String>[
      if (invitation.itemCount > 0) '${invitation.itemCount}',
      if (invitation.totalBytes > 0)
        ByteFormat.size(invitation.totalBytes)
      else
        l10n.inviteUnknownSize,
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      backgroundColor: AppColors.surfaceDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text(
        l10n.inviteTitle,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_icon, size: 28, color: AppColors.textPrimary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  // Chosen by the far side, so it is shown as text and never
                  // interpreted: a device calling itself something alarming is
                  // still just a name in a list.
                  invitation.senderName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _describe(l10n),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            l10n.inviteDecline,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          child: Text(l10n.inviteAccept),
        ),
      ],
    );
  }
}

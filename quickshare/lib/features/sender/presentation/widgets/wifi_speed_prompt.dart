import 'package:flutter/material.dart';

import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// Asks for Wi-Fi before a Bluetooth transfer, and takes no for an answer.
///
/// Bluetooth alone carries about 12 KB/s on real hardware — the standard tops
/// out at 2 Mbit/s and Apple exposes only the low-energy half of it. With
/// Wi-Fi switched on the same files take a direct link between the two devices
/// and go hundreds of times faster. No network is joined and nothing else
/// changes; the radio simply has to be awake.
///
/// That last part is why this asks in those words. "Turn on Wi-Fi" sounds like
/// "connect to a network", which is exactly what someone without one will
/// refuse. Saying no is a legitimate answer and costs nothing but time — the
/// transfer still happens, over Bluetooth, as it always did.
class WifiSpeedPrompt {
  final PeerLinkService link;

  const WifiSpeedPrompt({this.link = const PeerLinkService()});

  /// Returns once the question is settled, whichever way it went.
  ///
  /// Silent when Wi-Fi is already usable, or when this platform has no direct
  /// link to offer: a question nobody can act on is just an obstacle.
  Future<void> ask(BuildContext context) async {
    if (!PeerLinkService.isSupported) return;
    if (await link.wifiReady) return;

    // Where the radio can be switched on without disturbing anything, do it
    // and say nothing. There is no decision here to put to a person.
    if (await link.enableWifi()) return;
    if (!context.mounted) return;

    final l10n = AppLocalizations.of(context);
    final wantsSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: Text(l10n.wifiPromptTitle),
        content: Text(l10n.wifiPromptBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.wifiPromptDecline),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.wifiPromptAccept),
          ),
        ],
      ),
    );

    if (wantsSettings ?? false) await link.openWifiSettings();
  }
}

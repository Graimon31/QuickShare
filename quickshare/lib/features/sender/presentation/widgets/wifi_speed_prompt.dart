import 'package:flutter/material.dart';

import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/theme/app_colors.dart';

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

    final wantsSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: const Text('Turn on Wi-Fi to send faster?'),
        content: const Text(
          'Bluetooth on its own is slow — a large video can take hours.\n\n'
          'With Wi-Fi switched on, the two devices connect directly and the '
          'same files take seconds. You do not need to join a network: the '
          'radio just has to be on.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Send over Bluetooth'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );

    if (wantsSettings ?? false) await link.openWifiSettings();
  }
}

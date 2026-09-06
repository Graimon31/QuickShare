import 'dart:async';

import 'package:flutter/material.dart';

import 'package:quickshare/core/network/device_presence.dart';
import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// The devices running this app on this network, as a list you can tap.
///
/// The alternative it replaces is pasting a link. Between two phones that was
/// merely a QR code away; between two desktops there is no camera to point at
/// anything, and the honest answer was "copy this link into a messenger, open
/// the messenger on the other machine, paste it back". This is that, deleted.
///
/// Three states, and the difference between the last two is the whole point:
///
///  * devices — a list;
///  * nothing yet — nobody has answered, keep looking;
///  * the network will not carry it — guest Wi-Fi, captive portals and
///    anything with client isolation block multicast, and there the list can
///    never fill. Saying "no devices" there would be a lie that leaves someone
///    waiting; the panel says so and points at the code instead.
class NearbyDevicesPanel extends StatefulWidget {
  /// Called with a device the user picked.
  final void Function(DiscoveredPeer peer) onSelected;

  /// Only list devices already offering a session.
  ///
  /// True on a receiving screen, where a device with nothing to send is a row
  /// that cannot be tapped. False on a sending screen, where the point is to
  /// pick somebody to send to.
  final bool servingOnly;

  /// Injected by tests; the real one talks to the network.
  final DevicePresence? presence;

  const NearbyDevicesPanel({
    super.key,
    required this.onSelected,
    this.servingOnly = false,
    this.presence,
  });

  @override
  State<NearbyDevicesPanel> createState() => _NearbyDevicesPanelState();
}

class _NearbyDevicesPanelState extends State<NearbyDevicesPanel> {
  late final DevicePresence _presence;
  StreamSubscription<List<DiscoveredPeer>>? _subscription;

  List<DiscoveredPeer> _peers = const [];

  /// Null until the first answer, so the panel can say "looking" rather than
  /// choosing between "empty" and "blocked" before it knows.
  bool? _announcing;

  @override
  void initState() {
    super.initState();
    _presence = widget.presence ?? DevicePresence();
    _start();
  }

  Future<void> _start() async {
    _subscription = _presence.peers.listen((peers) {
      if (mounted) setState(() => _peers = peers);
    });
    final started = await _presence.start();
    if (mounted) {
      setState(() {
        _announcing = started;
        _peers = _presence.current;
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    // Not awaited: dispose cannot be async, and the socket closing a moment
    // after the screen is gone harms nothing.
    unawaited(_presence.dispose());
    super.dispose();
  }

  List<DiscoveredPeer> get _visible => widget.servingOnly
      ? _peers.where((p) => p.isServing).toList()
      : _peers;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final devices = _visible;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n.nearbyTitle,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            const Spacer(),
            if (_announcing == null || (devices.isEmpty && _announcing == true))
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: AppColors.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (devices.isNotEmpty)
          ...devices.map((peer) => _DeviceRow(
                peer: peer,
                onTap: () => widget.onSelected(peer),
              ))
        else
          _Explanation(
            title: _announcing == false ? l10n.nearbyBlocked : l10n.nearbyEmpty,
            body: _announcing == false
                ? l10n.nearbyBlockedHint
                : l10n.nearbyEmptyHint,
            isProblem: _announcing == false,
          ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final DiscoveredPeer peer;
  final VoidCallback onTap;

  const _DeviceRow({required this.peer, required this.onTap});

  /// Only ever decoration: an unknown platform is a future build, not an
  /// error, so anything unrecognised still gets a row and a generic icon.
  IconData get _icon {
    switch (peer.platform) {
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(_icon, size: 22, color: AppColors.textPrimary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        peer.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        peer.isServing ? l10n.nearbyReady : l10n.nearbyIdle,
                        style: TextStyle(
                          color: peer.isServing
                              ? AppColors.primary
                              : AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    size: 20, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Explanation extends StatelessWidget {
  final String title;
  final String body;
  final bool isProblem;

  const _Explanation({
    required this.title,
    required this.body,
    required this.isProblem,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isProblem
                ? Icons.wifi_tethering_off_rounded
                : Icons.wifi_find_rounded,
            size: 20,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

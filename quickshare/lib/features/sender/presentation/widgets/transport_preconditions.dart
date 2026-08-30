import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// Gates the choice of a transport on the radio or network it cannot work
/// without.
///
/// The check runs when the mode is *picked*, not when the session is already
/// being created: a QR code for a transport that is switched off is a promise
/// the app cannot keep, and the session must not exist yet when the user
/// says "no" to enabling it.
class TransportPreconditions {
  static final NetworkInfoService _networkInfo = NetworkInfoService();

  /// True when [type] may be selected. Otherwise the user has been told what
  /// is missing, and the caller must leave the current selection untouched.
  static Future<bool> ensure(BuildContext context, TransportType type) {
    switch (type) {
      case TransportType.wifi:
        return _ensureWifi(context);
      case TransportType.bluetooth:
        return _ensureBluetooth(context);
      case TransportType.internet:
        return _ensureInternet(context);
    }
  }

  static Future<bool> _ensureWifi(BuildContext context) async {
    if (await _networkInfo.hasWifiTransportNetwork()) return true;
    if (!context.mounted) return false;
    final l10n = AppLocalizations.of(context);
    final openSettings = await _askEnable(
      context,
      title: l10n.precondWifiTitle,
      body: l10n.precondWifiBody,
    );
    if (!context.mounted) return false;
    if (openSettings) {
      await _openWirelessSettings();
    } else {
      _showBlocked(context, l10n.precondWifiBlocked);
    }
    return false;
  }

  static Future<bool> _ensureBluetooth(BuildContext context) async {
    bool powered;
    try {
      final state = await UniversalBle.getBluetoothAvailabilityState();
      powered = state == AvailabilityState.poweredOn;
    } catch (_) {
      // The radio check itself failed — fail open and let the transport
      // report the real error, exactly as it did before this gate existed.
      return true;
    }
    if (powered) return true;
    if (!context.mounted) return false;
    final l10n = AppLocalizations.of(context);
    final openSettings = await _askEnable(
      context,
      title: l10n.precondBluetoothTitle,
      body: l10n.precondBluetoothBody,
    );
    if (!context.mounted) return false;
    if (openSettings) {
      await _openWirelessSettings();
    } else {
      _showBlocked(context, l10n.precondBluetoothBlocked);
    }
    return false;
  }

  static Future<bool> _ensureInternet(BuildContext context) async {
    if (await _networkInfo.hasAnyActiveConnection()) return true;
    if (!context.mounted) return false;
    _showBlocked(context, AppLocalizations.of(context).precondInternetBlocked);
    return false;
  }

  /// Asks to switch the radio on; true = user wants to do it via settings.
  static Future<bool> _askEnable(
    BuildContext context, {
    required String title,
    required String body,
  }) async {
    final l10n = AppLocalizations.of(context);
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.precondOpenSettings),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  static Future<void> _openWirelessSettings() async {
    // PeerLinkService knows the Wi-Fi pane on Apple platforms; everywhere
    // else the app's own settings page is the closest a store app may open.
    if (PeerLinkService.isSupported &&
        await const PeerLinkService().openWifiSettings()) {
      return;
    }
    await openAppSettings();
  }

  static void _showBlocked(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

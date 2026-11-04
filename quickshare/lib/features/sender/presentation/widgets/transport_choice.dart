import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// What a transport is called on the screens that offer it, and where it is
/// offered.
///
/// The home screen names three ways to send and the file screen titles itself
/// with the one that was picked. Both read the words from here, so the name a
/// person tapped is the name they see at the top of the next screen.
extension TransportChoice on TransportType {
  /// Whether this device can use the transport at all.
  ///
  /// Bluetooth is listed for the five platforms the app sends from; anywhere
  /// else the option is not drawn and a link that asks for it is turned away
  /// (see `SendRoutes.guard`). The two network transports have no such
  /// condition: their own checks (`TransportPreconditions`) say whether the
  /// network is there.
  bool get offeredHere {
    if (this != TransportType.bluetooth) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
      case TargetPlatform.android:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  IconData get icon => switch (this) {
        TransportType.wifi => Icons.wifi_rounded,
        TransportType.bluetooth => Icons.bluetooth_rounded,
        TransportType.internet => Icons.language_rounded,
      };
}

/// The words for the three ways to send.
extension TransportLabels on AppLocalizations {
  /// The "AirDrop" label, as one string. Every place that shows the name —
  /// the home card, the alternative's title, the screen reader's description —
  /// takes it from here, so renaming it is one edit per language file.
  String get airdropName => homeAirdropTitle;

  String transportTitle(TransportType type) => switch (type) {
        TransportType.wifi => homeLocalNetworkTitle,
        TransportType.bluetooth => homeAirdropAltTitle(airdropName),
        TransportType.internet => homeInternetTitle,
      };

  /// One line, and only what is true of the transport itself.
  String transportSubtitle(TransportType type) => switch (type) {
        TransportType.wifi => homeLocalNetworkSubtitle,
        TransportType.bluetooth => homeAirdropAltSubtitle,
        TransportType.internet => homeInternetSubtitle,
      };
}

import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// The one place a stored value becomes a sentence a person reads.
///
/// Everything the app records about a transfer — which way it went, which
/// end this device was, why it stopped — is kept as a value, because the
/// language the app is set to is not known when it is recorded and can
/// change afterwards. The screens ask here, and get the current language.
///
/// Nothing in this file writes to the log or the diagnostics block. Those
/// stay English on purpose: their reader is whoever is being asked for help,
/// who may not have the app at all. `TransferRoute.label` and
/// `Failure.message` are theirs.

/// What the screen says about a failure.
///
/// [code] is a [FailureCode]; when it names something the app itself
/// decided, the answer is a translated sentence. When it is null the failure
/// was a caught exception and [fallback] — its own text, in English, the
/// only words that exist for it — is all there is. That was previously the
/// answer for every failure, including the dozen the app writes itself.
String localizedFailure(
  AppLocalizations l10n, {
  required String? code,
  required String fallback,
}) {
  switch (code) {
    case FailureCode.senderUnreachable:
      return l10n.downloadErrorSenderUnreachable;
    case FailureCode.cancelledBySender:
      return l10n.downloadErrorCancelledBySender;
    case FailureCode.transferFailedUnexpectedly:
      return l10n.errorTransferFailedUnexpectedly;
    case FailureCode.bluetoothStartFailed:
      return l10n.errorBluetoothStartFailed;
    case FailureCode.bluetoothTransferFailed:
      return l10n.errorBluetoothTransferFailed;
    case FailureCode.internetStartFailed:
      return l10n.errorInternetStartFailed;
    case FailureCode.nothingSelected:
      return l10n.errorNothingSelected;
    case FailureCode.selectionUnreadable:
      return l10n.errorSelectionUnreadable;
    case FailureCode.networkCreateFailed:
      return l10n.errorNetworkCreateFailed;
    case FailureCode.networkWithoutAddress:
      return l10n.errorNetworkWithoutAddress;
    case FailureCode.nothingToRestart:
      return l10n.errorNothingToRestart;
    case FailureCode.receiverTooOldForDirectLink:
      return l10n.errorReceiverTooOldForDirectLink;
    case FailureCode.receiverTooOldToPair:
      return l10n.errorReceiverTooOldToPair;
    case FailureCode.linkWifiOff:
      return l10n.errorLinkWifiOff;
    case FailureCode.linkPeerSilentAtSetup:
      return l10n.errorLinkPeerSilentAtSetup;
    case FailureCode.linkSetupFailed:
      return l10n.errorLinkSetupFailed;
    case FailureCode.linkPeerLost:
      return l10n.errorLinkPeerLost;
    case FailureCode.linkWithoutAddress:
      return l10n.errorLinkWithoutAddress;
    case FailureCode.sessionWithoutCertificate:
      return l10n.errorSessionWithoutCertificate;
    case FailureCode.cancelledHere:
      return l10n.errorCancelledHere;
    default:
      return fallback;
  }
}

extension TransferRouteText on TransferRoute {
  /// The route, in the language on screen. See [TransferRoute.label] for the
  /// English the diagnostics keep using.
  String localized(AppLocalizations l10n) => switch (this) {
        TransferRoute.directWifiLink => l10n.routeDirectWifiLink,
        TransferRoute.localNetwork => l10n.routeLocalNetwork,
        TransferRoute.internetDirect => l10n.routeInternetDirect,
        TransferRoute.internetPeerToPeer => l10n.routeInternetPeerToPeer,
        TransferRoute.internetRelayed => l10n.routeInternetRelayed,
        TransferRoute.bluetooth => l10n.routeBluetooth,
        TransferRoute.unknown => l10n.routeUnknown,
      };
}

extension TransferReportText on TransferReport {
  /// The one line under a journal entry: what this device did, how much of
  /// it, and how long it took — or why it stopped.
  ///
  /// Composed here rather than in the screen because the pieces do not
  /// survive translation separately: "sent" + size + "in Ns" is three
  /// fragments in English and one sentence in Russian, with the verb agreeing
  /// with neither of the other two.
  String outcome(AppLocalizations l10n) {
    if (!succeeded) {
      return localizedFailure(l10n, code: failureCode, fallback: failure);
    }
    final size = TransferReport.formatBytes(bytes);
    final seconds = took.inSeconds;
    return switch (role) {
      TransferRole.sent => l10n.settingsTransferSent(size, seconds),
      TransferRole.received => l10n.settingsTransferReceived(size, seconds),
    };
  }
}

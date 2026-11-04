import 'package:equatable/equatable.dart';

/// A stable tag for a failure the app has to explain in the user's own
/// language rather than repeat as-is.
///
/// [Failure.message] stays raw and technical on purpose — it is what a log
/// line, a `debugPrint`, or the diagnostics block somebody copies for help
/// gets, and it is written in English for exactly that audience. Whatever
/// the screen shows instead is chosen from the code by
/// `localizedFailure`, so the same failure reads as Russian under a Russian
/// interface.
///
/// Every sentence this app writes itself has a code. What does not is a
/// caught exception's own text — a `DioException`, a socket error, a
/// platform channel's complaint — which no translation table can cover; a
/// code still names *what was being attempted* when it was thrown, and the
/// exception text goes underneath as detail for whoever reads it.
class FailureCode {
  FailureCode._();

  /// The sender's server stopped answering mid-session: the user cancelled,
  /// its app closed, its Wi-Fi dropped. A one-way HTTP pull has no channel to
  /// ask which one it was — they all look identical from here — and this
  /// name is true of every one of them.
  static const senderUnreachable = 'senderUnreachable';

  /// The sender explicitly said "cancelled" over a channel that can say
  /// that — the WebRTC data channel carries a real control message, unlike
  /// the QHTP pull [senderUnreachable] covers.
  static const cancelledBySender = 'cancelledBySender';

  /// A transport reported `failed` and said nothing else. The last resort,
  /// and the one the screen used to show in English for everything.
  static const transferFailedUnexpectedly = 'transferFailedUnexpectedly';

  /// The Bluetooth session never got as far as advertising.
  static const bluetoothStartFailed = 'bluetoothStartFailed';

  /// A Bluetooth session that was advertising, and then failed.
  static const bluetoothTransferFailed = 'bluetoothTransferFailed';

  /// The Bluetooth radio is switched off, so there is nothing to advertise
  /// with. Carried by [BluetoothRadioException].
  static const bluetoothOff = 'bluetoothOff';

  /// The person said no to the Nearby devices permission, which an Android
  /// phone needs before it can make itself visible to another device.
  static const bluetoothPermissionDenied = 'bluetoothPermissionDenied';

  /// This device's Bluetooth cannot act as the sending end at all: the
  /// platform says peripheral mode is unsupported, or the adapter cannot do it.
  static const bluetoothSendUnsupported = 'bluetoothSendUnsupported';

  /// The platform accepted the request to advertise and then did not start,
  /// or never said whether it had. The reason it gave rides in the message.
  static const bluetoothAdvertiseFailed = 'bluetoothAdvertiseFailed';

  /// The WebRTC session never got as far as an offer.
  static const internetStartFailed = 'internetStartFailed';

  /// Send was asked for with nothing chosen to send.
  static const nothingSelected = 'nothingSelected';

  /// Walking the chosen files threw: an unreadable folder, a selection past
  /// the size or depth ceiling.
  static const selectionUnreadable = 'selectionUnreadable';

  /// `startHosting()` refused or threw — no local network came up.
  static const networkCreateFailed = 'networkCreateFailed';

  /// The hotspot started but reports no address of its own, so there is
  /// nothing to point the other device at.
  static const networkWithoutAddress = 'networkWithoutAddress';

  /// The expired-session panel offered a restart for a session whose file
  /// selection is gone.
  static const nothingToRestart = 'nothingToRestart';

  /// The receiver is an older build that can only take bytes over the radio
  /// itself. See `BleControlProtocol.directLinkRequiredMessage`.
  static const receiverTooOldForDirectLink = 'receiverTooOldForDirectLink';

  /// The receiver is an older build that writes a `START` with no session
  /// token. See `BleControlProtocol.staleReceiverMessage`.
  static const receiverTooOldToPair = 'receiverTooOldToPair';

  /// The sender is an older build that moves files over Bluetooth itself,
  /// which this build no longer receives. The mirror image of
  /// [receiverTooOldForDirectLink]: the same fix, on the other device.
  static const senderTooOldForDirectLink = 'senderTooOldForDirectLink';

  /// The Wi-Fi radio is off, and the direct link the Bluetooth rendezvous
  /// hands the transfer to is a Wi-Fi link.
  static const linkWifiOff = 'linkWifiOff';

  /// The far side never answered the key exchange the link credentials are
  /// sealed under.
  static const linkPeerSilentAtSetup = 'linkPeerSilentAtSetup';

  /// Every rung of the direct-link ladder was tried and none came up.
  static const linkSetupFailed = 'linkSetupFailed';

  /// The far side stopped answering before the link existed — out of range,
  /// or its app closed.
  static const linkPeerLost = 'linkPeerLost';

  /// The link is up but this device cannot name its own address on it, so
  /// there is nothing to serve from.
  static const linkWithoutAddress = 'linkWithoutAddress';

  /// The person holding this device pressed Cancel. Not an error, but it is
  /// why the transfer has no bytes, and the journal has to say so.
  static const cancelledHere = 'cancelledHere';

  /// The offer on the sender's screen had been left to run until its server
  /// gave up, or the system closed it. Shown instead of a code that leads
  /// nowhere.
  static const offerEnded = 'offerEnded';

  /// The QHTP session came up without a TLS certificate to pin, so the
  /// receiver has nothing to trust and the pull would be refused.
  static const sessionWithoutCertificate = 'sessionWithoutCertificate';

  /// The two devices could not connect directly, and the relay service that
  /// would have carried them is throttling this client: `429 rate_limited`, or
  /// the Worker's limiter being down. Trying again in about a minute is the
  /// advice, and it is the right one.
  static const noPathRelayLimited = 'noPathRelayLimited';

  /// No direct connection, and the relay service could not be reached, did not
  /// answer in time, or answered with something unusable.
  static const noPathRelayUnreachable = 'noPathRelayUnreachable';

  /// No direct connection, and this build has no relay to fall back on: it is
  /// switched off or not configured at the Worker, or the build names no Worker.
  static const noPathRelayOff = 'noPathRelayOff';

  /// A relay *was* available and the connection still failed. Something
  /// between the devices blocks even relayed traffic — not the relay's fault,
  /// and the one cause that must not be blamed on it.
  static const noPathRelayWasAvailable = 'noPathRelayWasAvailable';

  /// The disk filled up while a file was being written. Distinct from
  /// [notEnoughSpace], which is the refusal *before* anything was written.
  static const diskFull = 'diskFull';

  /// There is not enough free room for what is left to receive. Carried
  /// bare, it is a sentence without numbers; [notEnoughSpaceFor] adds how much
  /// was needed and how much there is, and [parseNotEnoughSpace] reads them
  /// back — the code is the one thing that travels unchanged from the
  /// transport to the screen and into the journal, so the sizes ride on it.
  static const notEnoughSpace = 'notEnoughSpace';

  /// [notEnoughSpace] with the two sizes, in bytes.
  static String notEnoughSpaceFor(int needed, int available) =>
      '$notEnoughSpace:$needed:$available';

  /// The sizes inside a code made by [notEnoughSpaceFor]; null for any other.
  static ({int needed, int available})? parseNotEnoughSpace(String? code) {
    if (code == null) return null;
    final parts = code.split(':');
    if (parts.length != 3 || parts[0] != notEnoughSpace) return null;
    final needed = int.tryParse(parts[1]);
    final available = int.tryParse(parts[2]);
    if (needed == null || available == null) return null;
    return (needed: needed, available: available);
  }

  /// The destination holds a link (or a file where a folder must be) on the
  /// way to where a received file belongs. Nothing was written through it.
  static const unsafeDestination = 'unsafeDestination';

  /// The destination folder is nested so deeply that Windows could not open
  /// the file that would be written there.
  static const pathTooLong = 'pathTooLong';

  /// A received file was missing, the wrong size or changed by the time the
  /// session was checked at its end, so it is not reported as delivered.
  static const receivedFilesNotIntact = 'receivedFilesNotIntact';

  /// Whether [code] names a problem with the receiving disk or destination —
  /// the ones every receive path reports the same way, whichever transport
  /// carried the bytes.
  static bool isStorage(String? code) =>
      code != null &&
      (code == diskFull ||
          code == unsafeDestination ||
          code == pathTooLong ||
          code == receivedFilesNotIntact ||
          code == notEnoughSpace ||
          code.startsWith('$notEnoughSpace:'));
}

abstract class Failure extends Equatable {
  final String message;

  /// See [FailureCode]. Null means the UI should show [message] itself, as
  /// it always has.
  final String? code;

  const Failure(this.message, {this.code});

  @override
  List<Object?> get props => [message, code];
}

class ServerFailure extends Failure {
  const ServerFailure(super.message, {super.code});
}

class NetworkFailure extends Failure {
  const NetworkFailure(super.message, {super.code});
}

class PermissionFailure extends Failure {
  const PermissionFailure(super.message, {super.code});
}

class FileFailure extends Failure {
  const FileFailure(super.message, {super.code});
}

class QRFailure extends Failure {
  const QRFailure(super.message, {super.code});
}

class StorageFailure extends Failure {
  const StorageFailure(super.message, {super.code});
}

class TimeoutFailure extends Failure {
  const TimeoutFailure(super.message, {super.code});
}

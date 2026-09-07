import 'dart:async';

import 'package:quickshare/core/network/device_presence.dart';
import 'package:quickshare/core/router/app_router.dart';
import 'package:quickshare/core/transfer/transfer_invitation.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/shared/widgets/invitation_dialog.dart';

/// This device's presence on the local network, for as long as the app is
/// open.
///
/// It used to belong to whichever screen happened to show a list, which made
/// being discoverable an accident of navigation: the sending screen announced,
/// and so did the desktop code-entry screen, but the QR scanner a phone lands
/// on when you tap "Receive" did not. So a phone was invisible unless its
/// owner happened to walk further into the app — and the sender, waiting on
/// its QR screen, saw nothing and had no way to know why.
///
/// The empty state on that screen says "open DirectDrop on the other device",
/// which is the promise this keeps. Being open is enough; no particular screen
/// is required.
///
/// It stops when the app does. Nothing is announced in the background.
class AppPresence {
  AppPresence._();

  static final AppPresence instance = AppPresence._();

  DevicePresence? _presence;

  /// The shared presence, or null before [start] or after [stop].
  ///
  /// Screens that show a list pass this to their panel rather than making one
  /// of their own — two presences on one device would announce it twice and
  /// list it against itself.
  DevicePresence? get presence => _presence;

  bool get isRunning => _presence != null;

  /// Begins announcing this device and listening for invitations.
  ///
  /// Returns whether the network carried it. False is not a failure worth
  /// stopping for: the code and QR paths work regardless, and the panel says
  /// as much on screen.
  Future<bool> start() async {
    if (_presence != null) return true;

    final presence = DevicePresence();
    _presence = presence;

    final announcing = await presence.start(onInvitation: _ask);
    if (!announcing) {
      AppLogger.warning(
          'Not discoverable on this network — on Apple platforms check Local '
          'Network permission, otherwise the network is blocking mDNS',
          tag: 'DISCOVERY');
    }
    return announcing;
  }

  /// Shows the accept/decline dialog wherever the app currently is.
  ///
  /// Through the router's navigator rather than a screen's own context: an
  /// invitation can arrive while the user is anywhere, including a screen that
  /// knows nothing about transfers, and declining by default is the wrong
  /// answer to "you were not on the right page".
  Future<bool> _ask(TransferInvitation invitation) async {
    final context = AppRouter.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      // No UI to ask with. Silence is a decline, as it is everywhere else.
      AppLogger.warning(
          'An invitation arrived with no screen to show it on', tag: 'INVITE');
      return false;
    }
    return showInvitationDialog(context, invitation);
  }

  /// Says this device is now offering a session, so a receiver that was given
  /// the code can find it.
  void nowServing({
    required int port,
    required String tlsFingerprint,
    required String sessionPublicId,
  }) =>
      _presence?.nowServing(
        port: port,
        tlsFingerprint: tlsFingerprint,
        sessionPublicId: sessionPublicId,
      );

  /// Says the session is over. The device stays listed, just not as serving.
  void noLongerServing() => _presence?.noLongerServing();

  Future<void> stop() async {
    final presence = _presence;
    _presence = null;
    await presence?.dispose();
  }
}

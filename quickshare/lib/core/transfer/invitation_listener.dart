import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:quickshare/core/transfer/transfer_invitation.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Asks the person whether to accept, and answers when they have.
///
/// Returning false declines. Taking a long time is fine — the sender waits,
/// and the listener has its own ceiling.
typedef InvitationPrompt = Future<bool> Function(TransferInvitation invitation);

/// Listens for other devices offering to send something.
///
/// The half of the handshake that makes a list of devices useful. Discovery
/// says who is present; this is how one of them asks, and how the answer gets
/// back — which has to exist before tapping a name can start a transfer,
/// because a name is not permission.
///
/// Plain HTTP, not HTTPS. There is nothing to pin a certificate to yet: the
/// two devices have not met, and generating one here would only prove that
/// whoever answered is whoever answered. What matters for safety is on the
/// other side of this call — a person reads who is asking and decides.
class InvitationListener {
  /// How long an invitation may sit in front of a person before the sender is
  /// told no.
  ///
  /// Long enough to walk back to the machine, short enough that a sender is
  /// not left staring at a spinner because somebody wandered off. A decline on
  /// timeout is the safe direction: a transfer nobody agreed to must not start
  /// because the dialog was ignored.
  static const Duration answerWindow = Duration(seconds: 45);

  final InvitationPrompt _prompt;

  /// Overridable so the timeout can be tested in milliseconds rather than by
  /// sitting through the real window.
  final Duration _answerWindow;

  HttpServer? _server;

  /// True while a person is looking at a dialog, so a second sender is told to
  /// wait rather than queueing behind a prompt nobody can see.
  bool _busy = false;

  InvitationListener({
    required InvitationPrompt onInvitation,
    Duration? answerWindow,
  })  : _prompt = onInvitation,
        _answerWindow = answerWindow ?? InvitationListener.answerWindow;

  /// The port invitations arrive on, or null when not listening.
  int? get port => _server?.port;

  bool get isListening => _server != null;

  /// Starts listening on an ephemeral port.
  ///
  /// The port is whatever the system hands out and is published through
  /// discovery, so nothing has to agree on a number in advance.
  Future<int> start() async {
    if (_server != null) return _server!.port;

    final handler = const Pipeline().addHandler(_handle);
    // Bound to every interface on purpose: the sender reaches this over the
    // LAN, which may be Wi-Fi, Ethernet, or a network one of them raised.
    final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, 0);
    _server = server;
    AppLogger.info('Listening for invitations on :${server.port}',
        tag: 'INVITE');
    return server.port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _busy = false;
    await server?.close(force: true);
  }

  Future<Response> _handle(Request request) async {
    if (request.method != 'POST' || request.url.path != 'invite') {
      return Response.notFound('');
    }

    final invitation = TransferInvitation.decode(await request.readAsString());
    if (invitation == null) {
      // Anyone can reach this port, so junk is an ordinary event.
      return Response.badRequest(
          body: const InvitationVerdict.decline('not an invitation').encode());
    }

    if (_busy) {
      return Response.ok(
        const InvitationVerdict.decline('already deciding on another transfer')
            .encode(),
        headers: const {'content-type': 'application/json'},
      );
    }

    _busy = true;
    try {
      AppLogger.info(
          'Invitation from ${invitation.senderName} '
          '(${invitation.itemCount} item(s), ${invitation.totalBytes} bytes)',
          tag: 'INVITE');

      final accepted = await _prompt(invitation).timeout(
        _answerWindow,
        // Nobody answered. Declining is the only safe reading of silence.
        onTimeout: () => false,
      );

      AppLogger.info(
          accepted
              ? 'Accepted the transfer from ${invitation.senderName}'
              : 'Declined the transfer from ${invitation.senderName}',
          tag: 'INVITE');

      return Response.ok(
        accepted
            ? const InvitationVerdict.accept().encode()
            : const InvitationVerdict.decline().encode(),
        headers: const {'content-type': 'application/json'},
      );
    } catch (e) {
      AppLogger.warning('Invitation handling failed: $e', tag: 'INVITE');
      return Response.ok(
        const InvitationVerdict.decline('the other device could not ask')
            .encode(),
        headers: const {'content-type': 'application/json'},
      );
    } finally {
      _busy = false;
    }
  }
}

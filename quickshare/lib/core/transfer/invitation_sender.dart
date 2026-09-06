import 'dart:async';
import 'dart:io';

import 'package:quickshare/core/transfer/transfer_invitation.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Why an invitation did not lead to a transfer.
///
/// Separated from a plain decline because they need different words on screen:
/// "they said no" is an answer, "we could not ask" is a problem, and telling
/// somebody their friend declined when the network dropped is worse than
/// saying nothing.
enum InvitationOutcome {
  accepted,
  declined,

  /// The device answered, but it is already deciding on another transfer.
  busy,

  /// Nothing answered on that address and port.
  unreachable,

  /// It answered with something this build cannot read.
  unusable,
}

/// The result, with whatever the far side had to say about it.
class InvitationResult {
  final InvitationOutcome outcome;
  final String detail;

  const InvitationResult(this.outcome, [this.detail = '']);

  bool get accepted => outcome == InvitationOutcome.accepted;
}

/// Offers a transfer to one device and waits for the person to answer.
///
/// The sending half of the handshake. Deliberately one device at a time:
/// broadcasting an offer to everyone in range and taking whoever answers first
/// would be a different product, and a worse one — the point is to send
/// something to a person you can see.
class InvitationSender {
  /// How long to wait for a human to decide.
  ///
  /// A little past the listener's own window, so a receiver that times out
  /// gets to say "declined" rather than having the sender give up first and
  /// report a network problem for what was really a shrug.
  static const Duration answerWindow = Duration(seconds: 50);

  /// How long to wait for the device itself to answer at all.
  ///
  /// Separate from the human's window: a machine that is switched off should
  /// be reported as unreachable in seconds, not after a minute of waiting for
  /// somebody who is not there.
  static const Duration connectTimeout = Duration(seconds: 5);

  final HttpClient Function() _clientFactory;

  InvitationSender({HttpClient Function()? clientFactory})
      : _clientFactory = clientFactory ?? HttpClient.new;

  /// Asks [address]:[port] to accept [invitation].
  Future<InvitationResult> invite({
    required InternetAddress address,
    required int port,
    required TransferInvitation invitation,
  }) async {
    HttpClient? client;
    try {
      client = _clientFactory()
        ..connectionTimeout = connectTimeout
        ..idleTimeout = answerWindow;

      final request = await client
          .postUrl(Uri.parse('http://${address.address}:$port/invite'))
          .timeout(connectTimeout);
      request.headers.contentType = ContentType.json;
      request.write(invitation.encode());

      final response = await request.close().timeout(answerWindow);
      final body = await response.transform(const SystemEncoding().decoder)
          .join()
          .timeout(connectTimeout);

      if (response.statusCode != 200) {
        return InvitationResult(
            InvitationOutcome.unusable, 'HTTP ${response.statusCode}');
      }

      final verdict = InvitationVerdict.decode(body);
      if (verdict.accepted) {
        return const InvitationResult(InvitationOutcome.accepted);
      }
      if (verdict.reason.contains('already deciding')) {
        return InvitationResult(InvitationOutcome.busy, verdict.reason);
      }
      return InvitationResult(InvitationOutcome.declined, verdict.reason);
    } on TimeoutException {
      // Could be a machine that is gone, or a person who never came back. The
      // sender cannot tell, and either way there is nothing to transfer.
      return const InvitationResult(
          InvitationOutcome.unreachable, 'no answer in time');
    } on SocketException catch (e) {
      return InvitationResult(InvitationOutcome.unreachable, e.message);
    } catch (e) {
      AppLogger.warning('Invitation could not be sent: $e', tag: 'INVITE');
      return InvitationResult(InvitationOutcome.unusable, '$e');
    } finally {
      client?.close(force: true);
    }
  }
}

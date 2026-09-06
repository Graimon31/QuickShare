import 'dart:convert';

/// One device asking another to accept a transfer.
///
/// This is the piece that turns a list of devices into AirDrop's shape. A
/// discovery announcement says who is here; it deliberately does not say how
/// to open somebody's session, because every device on the network can read
/// it. The invitation is the private half: sent to one address, carrying what
/// that one device needs to fetch the files, and only after the person on the
/// far side has agreed.
///
/// ## What is in it, and what that means for who can read it
///
/// The invitation carries the session token — the same one a QR code would
/// have carried — so the receiver can authenticate against the sender's QHTP
/// server. It travels over plain HTTP on the local network.
///
/// That is a deliberate line, so it is worth being exact about where it sits.
/// The token is only useful to somebody who can also reach the sender's
/// server, which means being on the same network already; on WPA2 and WPA3
/// each client's traffic is encrypted to the access point under its own key,
/// so a neighbour on the same Wi-Fi cannot simply read it off the air. An open
/// network is the real exposure, and there the answer is the same as for
/// everything else on an open network: the transfer is between two people
/// standing next to each other, and the token dies with the session.
///
/// What this does *not* rely on is secrecy of the announcement: an attacker
/// who spams invitations at somebody gets a dialog they will decline, and an
/// attacker who guesses a token still has to reach a server that stops
/// existing when the transfer ends.
class TransferInvitation {
  static const int version = 1;

  /// Shown in the "accept?" dialog, so the person can tell whether this is the
  /// device their friend is holding. Display text and nothing more.
  final String senderName;
  final String senderPlatform;

  /// How many files and how big, so the answer can be an informed one. A
  /// person who is offered 40 GB should get to know that before agreeing.
  final int itemCount;
  final int totalBytes;

  /// Where the files are, once the offer is accepted.
  final int port;
  final String sessionId;
  final String token;
  final String tlsFingerprint;

  const TransferInvitation({
    required this.senderName,
    required this.senderPlatform,
    required this.itemCount,
    required this.totalBytes,
    required this.port,
    required this.sessionId,
    required this.token,
    required this.tlsFingerprint,
  });

  Map<String, dynamic> toJson() => {
        'v': version,
        'name': senderName,
        'os': senderPlatform,
        'items': itemCount,
        'bytes': totalBytes,
        'port': port,
        'sid': sessionId,
        'token': token,
        'tf': tlsFingerprint,
      };

  String encode() => jsonEncode(toJson());

  /// Parses an invitation, or returns null if it is not one.
  ///
  /// Null rather than an exception: this parses bytes that arrived unsolicited
  /// from anyone who can reach the port, so malformed input is an expected
  /// event and not an error worth unwinding the stack for.
  static TransferInvitation? decode(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return null;
      if (json['v'] != version) return null;

      final name = json['name'];
      final token = json['token'];
      final sessionId = json['sid'];
      final port = json['port'];
      final fingerprint = json['tf'];

      // Every one of these is needed to fetch anything, so an invitation
      // missing one cannot be acted on even if the user accepts it.
      if (name is! String || name.isEmpty) return null;
      if (token is! String || token.isEmpty) return null;
      if (sessionId is! String || sessionId.isEmpty) return null;
      if (fingerprint is! String || fingerprint.isEmpty) return null;
      if (port is! int || port <= 0 || port > 65535) return null;

      final items = json['items'];
      final bytes = json['bytes'];

      return TransferInvitation(
        senderName: name,
        senderPlatform: json['os'] as String? ?? 'unknown',
        // Sizes are for the dialog, not for the transfer, so nonsense in them
        // is worth showing as "unknown" rather than refusing the invitation.
        itemCount: items is int && items > 0 ? items : 0,
        totalBytes: bytes is int && bytes > 0 ? bytes : 0,
        port: port,
        sessionId: sessionId,
        token: token,
        tlsFingerprint: fingerprint,
      );
    } catch (_) {
      return null;
    }
  }
}

/// What the far side said about an invitation.
class InvitationVerdict {
  final bool accepted;

  /// Why not, when the answer is no and there is something to say. A person
  /// declining says nothing; a device that is mid-transfer can say so.
  final String reason;

  const InvitationVerdict({required this.accepted, this.reason = ''});

  const InvitationVerdict.accept() : accepted = true, reason = '';

  const InvitationVerdict.decline([this.reason = '']) : accepted = false;

  Map<String, dynamic> toJson() => {
        'accepted': accepted,
        if (reason.isNotEmpty) 'reason': reason,
      };

  String encode() => jsonEncode(toJson());

  static InvitationVerdict decode(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) {
        return const InvitationVerdict.decline();
      }
      return InvitationVerdict(
        accepted: json['accepted'] == true,
        reason: json['reason'] as String? ?? '',
      );
    } catch (_) {
      // An answer nobody can read is not a yes.
      return const InvitationVerdict.decline();
    }
  }
}

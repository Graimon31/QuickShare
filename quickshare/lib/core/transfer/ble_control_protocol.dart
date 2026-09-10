import 'dart:convert';

/// The commands a Bluetooth receiver writes to the sender's control
/// characteristic.
///
/// Kept in one file for the same reason [TransferProtocol] is: the two halves
/// live in different layers and the native bridges repeat these literals in
/// Swift, so a value that drifts here breaks a pairing nobody can reproduce
/// without two devices.
///
/// ## Why a receiver announces itself at all
///
/// This channel has no handshake. The receiver subscribes, writes `START`, and
/// the sender streams — which was enough while a session was always exactly
/// one file. It stopped being enough when a session became a list: a receiver
/// on an older build finishes at the first file's last byte and disconnects,
/// so a folder sent to one arrives as its first file and *nothing says so*.
/// Silent partial delivery is the one failure mode worth adding a round trip
/// to avoid.
///
/// So a receiver that understands lists says so, in a write the older senders
/// already tolerate: they answer it (with success or `requestNotSupported`,
/// depending on the platform) and carry on waiting for `START`. A sender that
/// reaches `START` without having seen it knows the far side is old, and
/// refuses a multi-file session with something the user can act on instead of
/// delivering one file quietly.
///
/// ## What the channel is for now
///
/// Generation 4 is where the bytes left this radio. The rendezvous still
/// happens here — who is present, what they can take, which session may
/// start, and, via [BleControlProtocol.apOffer], where to join when the
/// network's name could not be chosen — but the file itself crosses a Wi-Fi
/// link the two devices raise for the occasion, at Wi-Fi speed. A peer below
/// 4 only knows how to receive over Bluetooth itself, a path this build
/// never takes, so it is told to update rather than sent the file slowly.
class BleControlProtocol {
  const BleControlProtocol._();

  /// What this build can receive.
  ///
  /// 1 — one file per session, the only shape that existed through v1.0.10.
  /// 2 — a list of files, each with the relative path it keeps, so a folder
  ///     crosses as a folder.
  /// 3 — `START` must carry the session token. A bare `START` is refused:
  ///     without the token any device in radio range could open the GATT
  ///     server and pull the file the sender is offering to someone else.
  /// 4 — the direct-link generation. The file never travels this channel:
  ///     after the rendezvous the two devices raise a Wi-Fi link of their
  ///     own and the bytes cross there.
  static const int generation = 4;

  /// Sent before [startCommand], never instead of it.
  static String capabilities([int gen = generation]) => 'CAPS:$gen';

  static String start(String token) => 'START:$token';

  /// Written by a receiver that is present but not asking for anything yet.
  ///
  /// Bluetooth put the two roles the wrong way round for a device list: only
  /// the sender advertises, and the receiver that finds it used to write
  /// [start] straight away — so the transfer began before the person sending
  /// had seen who was there. A receiver with no code to act on says this
  /// instead and waits to be picked, which is the shape the local network
  /// already had and the one people expect from AirDrop.
  ///
  /// Deliberately not a new generation. Senders through this build answer an
  /// unrecognised control write with success and carry on waiting, so this
  /// costs nothing on an older one — and bumping [generation] would make
  /// every current receiver look too old to take a folder.
  static const String helloPrefix = 'HELLO:';

  static String hello(String deviceName) => '$helloPrefix$deviceName';

  /// The name a HELLO announces, or null if [command] is not one.
  static String? parseHello(String command) {
    if (!command.startsWith(helloPrefix)) return null;
    final name = command.substring(helloPrefix.length).trim();
    // A row in a list needs something to draw, and a name is chosen by the
    // far side — so it is length-capped here and treated as display text.
    if (name.isEmpty || name.length > 64) return null;
    return name;
  }

  /// Receiver → sender: "the network is up at these credentials — join it".
  ///
  /// Credentials travel only when they could not be derived from the session
  /// code: Android's hotspot API names the network itself, so its name and
  /// passphrase have to cross this channel. A host that chose its own name
  /// took it from the session code, the joiner derives the same credentials
  /// locally, and nothing is written.
  static const String apPrefix = 'AP:';

  static String apOffer(String ssid, String passphrase) =>
      '$apPrefix${Uri.encodeComponent(ssid)}:${Uri.encodeComponent(passphrase)}';

  /// The credentials an [apOffer] write carries, or null if [command] is
  /// not one.
  ///
  /// The parts are percent-encoded, so a colon inside either of them cannot
  /// be mistaken for the separator. The limits are the 802.11 ones — an SSID
  /// is at most 32 bytes and a WPA passphrase 8 to 63 characters — so a
  /// malformed write is dropped here rather than handed to the Wi-Fi stack
  /// to fail less legibly.
  static ({String ssid, String passphrase})? parseApOffer(String command) {
    if (!command.startsWith(apPrefix)) return null;
    final parts = command.substring(apPrefix.length).split(':');
    if (parts.length != 2) return null;
    final String ssid;
    final String passphrase;
    try {
      ssid = Uri.decodeComponent(parts[0]);
      passphrase = Uri.decodeComponent(parts[1]);
      // decodeComponent reports bad percent-encoding as ArgumentError and
      // bad UTF-8 as FormatException; both mean the write was malformed.
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
    if (ssid.isEmpty ||
        utf8.encode(ssid).length > 32 ||
        passphrase.length < 8 ||
        passphrase.length > 63) {
      return null;
    }
    return (ssid: ssid, passphrase: passphrase);
  }

  /// The generation [command] announces, or null if it is not a CAPS write.
  ///
  /// Anything unparseable reads as null rather than as generation 1: a command
  /// this build does not recognise is not evidence about the peer either way.
  static int? parseCapabilities(String command) {
    if (!command.startsWith('CAPS:')) return null;
    return int.tryParse(command.substring(5).trim());
  }

  /// Whether a peer can take part in a session at all.
  ///
  /// Generation 4 is where the bytes left this radio: a peer below it only
  /// knows how to receive over Bluetooth itself, a path this build never
  /// takes — so the session does not begin, whatever it could once have
  /// carried. The person sending gets [directLinkRequiredMessage] instead of
  /// a transfer that crawls.
  ///
  /// This replaced a softer rule, deliberately. That one refused a folder to
  /// an older peer — which would have taken the first file and reported the
  /// whole thing done — while still sending it a single file over the radio.
  /// One file was worth keeping when the radio was the road; it is not worth
  /// keeping a second delivery mechanism for, and the one it used publishes
  /// what arrives without checking its length. An older build is an older
  /// build of this same app, and the fix for it is to update it.
  static bool peerSupportsDirectLink(int? peerGeneration) =>
      (peerGeneration ?? 1) >= generation;

  /// Shown to the person sending when [peerSupportsDirectLink] says no.
  /// Names the fix, and the reason is in the same breath so the update does
  /// not feel arbitrary.
  static const String directLinkRequiredMessage =
      'The receiving device is on an older version that can only receive '
      'over Bluetooth. Update it, and the transfer moves to a direct Wi-Fi '
      'link.';

  /// Whether [command] is a valid start for a session opened with [token].
  ///
  /// The token is mandatory. It is the only thing that ties the write to the
  /// QR code the sender showed: without it, a bare `START` from any device
  /// that connected to the GATT server would begin the transfer.
  static bool isStart(String command, String? token) =>
      token != null && token.isNotEmpty && command == 'START:$token';

  /// Whether [command] is a `START` write that failed [isStart] — a device
  /// trying to begin a transfer without the session token.
  ///
  /// Almost always a receiver on a build from before the token was required;
  /// the sender turns this into [staleReceiverMessage] rather than ignoring
  /// the write and leaving both sides waiting.
  static bool isUnauthorizedStart(String command, String? token) =>
      (command == 'START' || command.startsWith('START:')) &&
      !isStart(command, token);

  /// Shown to the person sending when a receiver writes a `START` without the
  /// session token — see [isUnauthorizedStart].
  static const String staleReceiverMessage =
      'The receiving device is on an older version that cannot pair securely '
      'over Bluetooth. Update it, or send over Wi-Fi.';
}

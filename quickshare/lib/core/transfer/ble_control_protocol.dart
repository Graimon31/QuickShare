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
  static const int generation = 3;

  /// Sent before [startCommand], never instead of it.
  static String capabilities([int gen = generation]) => 'CAPS:$gen';

  static String start(String token) => 'START:$token';

  /// The generation [command] announces, or null if it is not a CAPS write.
  ///
  /// Anything unparseable reads as null rather than as generation 1: a command
  /// this build does not recognise is not evidence about the peer either way.
  static int? parseCapabilities(String command) {
    if (!command.startsWith('CAPS:')) return null;
    return int.tryParse(command.substring(5).trim());
  }

  /// Whether a peer that announced [peerGeneration] can take a session of
  /// [fileCount] files.
  ///
  /// A missing announcement counts as the old generation. That is the safe
  /// direction and the only honest one: every build through v1.0.10 sent
  /// nothing here, so silence is what an old receiver sounds like.
  ///
  /// One file is sent to anyone. That shape never changed, and refusing it
  /// would break the ordinary case to protect the new one.
  static bool peerCanTakeSession({
    required int fileCount,
    required int? peerGeneration,
  }) =>
      fileCount <= 1 || (peerGeneration ?? 1) >= generation;

  /// What to tell the person sending when [peerCanTakeSession] says no.
  ///
  /// Names the thing they can do about it. "Bluetooth transfer failed" sends
  /// somebody hunting a radio problem that is not there.
  static const String sessionRefusedMessage =
      'The receiving device is on an older version that can only accept one '
      'file over Bluetooth. Update it, or send over Wi-Fi.';

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

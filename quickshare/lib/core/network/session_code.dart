import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// One short secret both devices hold, and everything derived from it.
///
/// The problem this solves is the second QR code. A device that raises a
/// network knows its name and passphrase; the device that has to join needs
/// them, and there is no channel to send them over — the first code has
/// already been shown, and a QR cannot answer back. The usual fix is a second
/// code in the other direction, which needs a camera and a screen at both
/// ends, and two desktops have neither pointed at the other.
///
/// So nothing is sent. Both ends derive the same network name, passphrase and
/// session token from a secret they already share, exactly as
/// `PeerLinkService.serviceNameFor` already derives a Bonjour name from the
/// session token. What travels between the devices is only the code itself —
/// as a QR where there is a camera, and as eight characters a person can read
/// aloud where there is not.
///
/// ## Why ten digits
///
/// Digits, not letters, because this is read aloud across a table or typed on
/// a phone keypad — and both are noticeably worse with an alphabet that mixes
/// cases and shapes. Ten of them is 10^10, a shade over 33 bits.
///
/// That is the whole strength of the passphrase too, since it is derived from
/// this and nothing else — worth stating plainly rather than implying WPA2's
/// usual margins. It is sized for what it defends: a network that exists for
/// one transfer, in radio range, for a couple of minutes, where an attacker
/// has to be in the room and gets that long to try against an access point
/// answering at radio speed.
class SessionCode {
  /// Digits only. What a person reads out or types on a numeric keypad.
  static const String alphabet = '0123456789';

  /// Ten digits, shown in two groups of five.
  static const int length = 10;

  /// The alphabet the *derived* passphrase uses.
  ///
  /// Crockford's Base32, less `I`, `L`, `O` and `U`: the passphrase is
  /// occasionally read off a screen and typed into a system Wi-Fi dialog by
  /// hand, where those are the characters people get wrong. Exactly 32 symbols
  /// matters beyond readability — deriving a character is a byte modulo the
  /// alphabet size, and only a power of two divides 256 evenly.
  static const String passphraseAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// The canonical form: upper case, no separators.
  final String code;

  const SessionCode(this.code);

  /// A fresh code from a cryptographic source.
  factory SessionCode.generate([Random? random]) {
    final source = random ?? Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(alphabet[source.nextInt(alphabet.length)]);
    }
    return SessionCode(buffer.toString());
  }

  /// Reads a code a person typed, or null if it is not one.
  ///
  /// Tolerant on the way in and strict on the way out: dashes, spaces and
  /// lower case are all how people actually type these, and none of them
  /// change what was meant. Anything left over that is not in the alphabet is
  /// a typo worth reporting rather than quietly dropping — `O` typed for `0`
  /// is the classic one, and silently ignoring it would produce a
  /// valid-looking code that derives the wrong network, surfacing later as
  /// "cannot connect" with nothing to point at.
  static SessionCode? parse(String input) {
    final cleaned = input.replaceAll(RegExp(r'[\s\-—–_()]'), '');
    if (cleaned.length != length) return null;
    for (final rune in cleaned.runes) {
      if (!alphabet.contains(String.fromCharCode(rune))) return null;
    }
    return SessionCode(cleaned);
  }

  /// How the code is shown to a person: `12345 67890`.
  ///
  /// Split in the middle because ten unbroken digits is past what most people
  /// hold in their head between glancing at one screen and typing on another.
  String get display =>
      '${code.substring(0, 5)} ${code.substring(5)}';

  /// Domain-separated derivation, so one output can never be read off another.
  ///
  /// The network name is broadcast in the clear to everyone in range; if the
  /// passphrase shared a derivation with it, the name would hand out the key.
  List<int> _derive(String purpose) =>
      sha256.convert(utf8.encode('directdrop/$purpose/$code')).bytes;

  String _deriveString(String purpose, int chars) {
    final bytes = _derive(purpose);
    final buffer = StringBuffer();
    for (var i = 0; i < chars; i++) {
      buffer.write(passphraseAlphabet[bytes[i] % passphraseAlphabet.length]);
    }
    return buffer.toString();
  }

  /// A public name for this session, used as a locator.
  ///
  /// Note on threat model: with 10 decimal digits (~33.2 bits of entropy),
  /// a public identifier derived via SHA-256 can be brute-forced offline in seconds
  /// if observed by an attacker on the same L2 network. Therefore, [publicId] acts
  /// strictly as a discovery locator. For high-security channels (such as QR flow),
  /// the session token must be generated independently using 128-bit cryptographically
  /// secure randomness, breaking the link between the advertised code/locator and the
  /// authentication token.
  String get publicId => _deriveString('cid', 8);

  /// What every network this app raises is called, before the derived part.
  ///
  /// A device scanning the air filters on this to tell our networks from the
  /// neighbours' — which is how two desktops find each other with no camera
  /// between them.
  static const String ssidPrefix = 'DirectDrop-';

  /// The network's name, which both ends work out independently.
  ///
  /// Short enough to leave room inside the 32 bytes an SSID allows.
  String get ssid => '$ssidPrefix${_deriveString('ssid', 6)}';

  /// The network's passphrase. Twelve characters, comfortably past WPA2's
  /// eight-character floor.
  String get passphrase => _deriveString('psk', 12);

  /// The QHTP session token, so the transfer authenticates against the same
  /// secret that got the devices onto one network.
  ///
  /// Hex rather than the display alphabet: this one is never read by a person,
  /// and the existing token format is hex everywhere else.
  String get sessionToken {
    final bytes = _derive('token');
    return bytes
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// The `WIFI:` payload every phone camera understands, so the joining device
  /// can be walked onto the network without the app installed.
  String get wifiQrPayload {
    String escape(String value) =>
        value.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');
    return 'WIFI:T:WPA;S:${escape(ssid)};P:${escape(passphrase)};;';
  }

  @override
  bool operator ==(Object other) =>
      other is SessionCode && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'SessionCode($display)';
}

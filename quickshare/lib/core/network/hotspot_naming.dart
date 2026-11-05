import 'dart:math';

/// The name and passphrase of a Wi-Fi network this app is about to raise.
///
/// **Drawn at random, each time, from nothing.** They are not worked out from a
/// session code, a token, a locator, a device name or the time. That used to be
/// the design: both ends derived the same pair from the ten digits they shared,
/// so nothing about the network had to be sent. It cannot be kept, because the
/// network's name is broadcast in the clear to everybody in range, and a name
/// that is a hash of a 33-bit secret is a search key for it: thirty of the
/// thirty-three bits are in the name, ten billion codes are tried in seconds,
/// the few that match are tried against the passphrase, and the passphrase —
/// the thing WPA2 rests on — falls out. The receiver of a Bluetooth session
/// never needed to derive anything: the credentials reach it sealed in the link
/// frame (see `LinkSecret`), or in the Wi-Fi QR beside the screen.
///
/// Whatever the platform will accept:
///
///  * the name is [ssidPrefix] and [ssidSuffixLength] characters — 17 bytes,
///    inside the 32 an SSID may have, and the prefix is how a device scanning
///    the air tells our networks from the neighbours';
///  * the passphrase is [passphraseLength] characters, past WPA2's floor of 8
///    and far under its ceiling of 63, from an alphabet of 32 letters and
///    digits — 60 bits, which is out of reach of an offline attack on a network
///    that lives for a minute or two;
///  * no character in either needs escaping anywhere it goes: not in the
///    `WIFI:` QR (`\ ; , : "`), not in a command line, not in the XML Windows
///    keeps a profile in, not in the dialog a person types it into by hand.
///
/// Android picks its own and ignores these; what it picked is what the platform
/// answers with, and what the rest of the app uses.
class HotspotNaming {
  const HotspotNaming._(this.ssid, this.passphrase);

  /// What every network this app raises is called, before the random part.
  static const String ssidPrefix = 'DirectDrop-';

  /// Characters after [ssidPrefix]. Random and public: it tells two networks
  /// raised near each other apart and nothing else.
  static const int ssidSuffixLength = 6;

  /// Characters of passphrase.
  static const int passphraseLength = 12;

  /// Crockford's Base32 without `I`, `L`, `O` and `U`: no look-alikes for a
  /// person typing it by hand, and exactly 32 symbols, so a random index into
  /// it is uniform.
  static const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  final String ssid;
  final String passphrase;

  /// A new pair. [random] is for a test that has to know it; otherwise a
  /// cryptographic source, fresh for each network.
  factory HotspotNaming.generate([Random? random]) {
    final source = random ?? Random.secure();
    String draw(int length) => [
          for (var i = 0; i < length; i++) alphabet[source.nextInt(alphabet.length)]
        ].join();
    // Two separate draws: nothing in the name says anything about the
    // passphrase, not even by sharing a stretch of one random string.
    return HotspotNaming._(
        '$ssidPrefix${draw(ssidSuffixLength)}', draw(passphraseLength));
  }

  @override
  String toString() => 'HotspotNaming($ssid)';
}

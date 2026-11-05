import 'dart:convert';
import 'dart:math';

/// The GATT layout and the advertisement every platform agrees on.
///
/// Five implementations speak this: CoreBluetooth on iOS and macOS (Swift,
/// which repeats these literals), `universal_ble` on Android and Windows, and
/// BlueZ on Linux. A value that drifts in any one of them breaks a pairing
/// nobody can reproduce without two devices, so `test/features/ble_advertisement_contract_test.dart`
/// reads the native sources and holds them to what is written here.
class BleGatt {
  const BleGatt._();

  static const String service = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';

  /// Receiver -> sender writes: CAPS, HELLO, KEX, AP, START.
  static const String control = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B11';

  /// Sender -> receiver notifications: the link and serve frames.
  static const String metadata = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B12';

  /// Subscribed to, and nothing else.
  ///
  /// No byte of a file crosses it since protocol generation 4. It stays in the
  /// service because the receiver's subscription to it is how the sender
  /// learns that the far side is fully connected: both ends wait for that
  /// before the first frame goes out.
  static const String data = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B13';

  /// Client Characteristic Configuration: what a subscription is written to.
  static const String cccd = '00002902-0000-1000-8000-00805F9B34FB';
}

/// What a sender puts on the air, and what a receiver accepts of it.
class BleAdvertisement {
  const BleAdvertisement._();

  /// The local name starts with this when it carries a session locator.
  static const String namePrefix = 'QuickShare-';

  /// How many characters a locator has.
  static const int locatorLength = 8;

  /// The alphabet a locator is spelled in: Crockford's Base32 without `I`, `L`,
  /// `O` and `U`. Thirty-two symbols, so a random index is a uniform one.
  static const String _locatorAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// A fresh locator for one session: [locatorLength] characters from a
  /// cryptographic source, forty bits, **related to nothing**.
  ///
  /// This is what goes in the advertised name (Apple and Linux senders) and in
  /// the QR the receiver scans, and that is the whole of its job: a receiver
  /// that was shown the QR picks this sender out of several by it. It is not
  /// derived from the session's code, its token, its network name or anything
  /// else, so reading it off the air tells a listener nothing they could search
  /// for — there is nothing for it to be searched against. The value that used
  /// to be advertised here, `SessionCode.publicId`, was forty bits of a hash
  /// over a space of about thirty-three: anybody in range could try all ten
  /// billion codes against it in seconds and keep the one that matched.
  ///
  /// A new one for every session, which means every time the code changes.
  static String newLocator([Random? random]) {
    final source = random ?? Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < locatorLength; i++) {
      buffer.write(_locatorAlphabet[source.nextInt(_locatorAlphabet.length)]);
    }
    return buffer.toString();
  }

  /// The local name for a session whose locator is [locator].
  ///
  /// Carries the locator and never the token or any slice of it. The locator is
  /// random and public by design (see [newLocator]) — which is also why
  /// Android and Windows senders can leave it off the air without losing
  /// anything: it does not authenticate, the `START:<token>` write after the
  /// connection does. See `BluetoothTransferTransport.startSharing`.
  static String nameFor(String locator) =>
      '$namePrefix${locator.isNotEmpty ? locator : 'directdrop'}';

  /// Bytes in a legacy (Bluetooth 4.x) advertising packet or scan response.
  static const int legacyPacketLimit = 31;

  /// How many bytes an Android advertisement puts in its primary packet.
  ///
  /// Counted the way `BluetoothLeAdvertiser.totalBytes` counts: three bytes of
  /// flags for a connectable advertisement, then two bytes of header per field
  /// plus the field. This is what the old Android code got wrong — a 128-bit
  /// service UUID is 18 bytes and `QuickShare-` plus an eight-character
  /// locator is 21, which together with the flags is 42, and the platform
  /// answers `ADVERTISE_FAILED_DATA_TOO_LARGE`.
  static int legacyPrimaryPacketBytes({
    bool connectable = true,
    int serviceUuids128 = 0,
    String? localName,
  }) {
    var size = connectable ? 3 : 0;
    if (serviceUuids128 > 0) size += 2 + 16 * serviceUuids128;
    if (localName != null) size += 2 + utf8.encode(localName).length;
    return size;
  }

  /// Whether a receiver looking for the session with [locator] (or, for a QR
  /// from a build that carried none, [sessionToken]) connects to a peripheral
  /// that advertises [advertisedName].
  ///
  /// The scan is already filtered to [BleGatt.service], so every device here
  /// runs DirectDrop. A device without a `QuickShare-` name — a Windows PC,
  /// which cannot set one, or an Android phone, which cannot fit one beside
  /// the service UUID — is accepted: the `START:<token>` write after the
  /// connection is what authenticates the session. A device that does carry a
  /// locator must carry this session's, or it is somebody else's offer.
  ///
  /// The iOS and macOS receivers apply the same rule in Swift
  /// (`didDiscover`); the contract test pins them to it.
  static bool accepts({
    String? advertisedName,
    String? locator,
    String? sessionToken,
  }) {
    final name = advertisedName ?? '';
    if (!name.startsWith(namePrefix)) return true;
    if (locator != null && locator.isNotEmpty) {
      return name.contains(locator);
    }
    if (sessionToken != null && sessionToken.isNotEmpty) {
      // Builds that predate the locator advertised a slice of the token. Only
      // read here, never written.
      final end = sessionToken.length < 8 ? sessionToken.length : 8;
      return name.contains(sessionToken.substring(0, end));
    }
    return true;
  }
}

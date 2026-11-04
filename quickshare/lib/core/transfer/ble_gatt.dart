import 'dart:convert';

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

  /// The local name for a session whose public identifier is [publicId].
  ///
  /// Carries the identifier and never the token or any slice of it. That is
  /// not the same as safe: the identifier is a locator that can be searched
  /// for the code (see `SessionCode.publicId`), which is why Android and
  /// Windows senders do not broadcast it at all — see
  /// `BluetoothTransferTransport.advertisedLocalName`.
  static String nameFor(String publicId) =>
      '$namePrefix${publicId.isNotEmpty ? publicId : 'directdrop'}';

  /// Bytes in a legacy (Bluetooth 4.x) advertising packet or scan response.
  static const int legacyPacketLimit = 31;

  /// How many bytes an Android advertisement puts in its primary packet.
  ///
  /// Counted the way `BluetoothLeAdvertiser.totalBytes` counts: three bytes of
  /// flags for a connectable advertisement, then two bytes of header per field
  /// plus the field. This is what the old Android code got wrong — a 128-bit
  /// service UUID is 18 bytes and `QuickShare-` plus an eight-character
  /// identifier is 21, which together with the flags is 42, and the platform
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

  /// Whether a receiver looking for the session with [publicId] (or, for a QR
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
    String? publicId,
    String? sessionToken,
  }) {
    final name = advertisedName ?? '';
    if (!name.startsWith(namePrefix)) return true;
    if (publicId != null && publicId.isNotEmpty) {
      return name.contains(publicId);
    }
    if (sessionToken != null && sessionToken.isNotEmpty) {
      // Builds that predate the public identifier advertised a slice of the
      // token. Only read here, never written.
      final end = sessionToken.length < 8 ? sessionToken.length : 8;
      return name.contains(sessionToken.substring(0, end));
    }
    return true;
  }
}

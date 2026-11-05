import 'dart:math';

import 'ble_gatt.dart';

/// The two values a Bluetooth session is told apart by, both random and
/// neither related to anything else — least of all to a session code.
///
/// ## Why this exists
///
/// A Bluetooth session used to take both from the ten digits of a
/// `SessionCode`: the token as a hash of the code, the locator as another hash
/// of it. Ten digits are about 33 bits, so each of those hashes could be
/// searched backwards in seconds, and the radio carries both in the clear — the
/// locator in the advertised name (Apple and Linux), the token in the
/// `START:<token>` write and the serve frame, neither of which is encrypted or
/// bonded. A listener who read either one recovered the code, and from the
/// code the network name and the network's passphrase.
///
/// A Bluetooth session has no digits to type — the screen shows a QR and
/// nothing else — so nothing needs the values to come from a code. They are
/// drawn independently from a cryptographic source, and a session is bound to
/// them by a QR only the receiver that was shown it has.
class BleSession {
  const BleSession({required this.locator, required this.token});

  /// Spelled out in the advertised name and in the QR, and nowhere else. It
  /// only picks this sender out of several; see [BleAdvertisement.newLocator].
  final String locator;

  /// What authorises the session: the receiver proves it by writing
  /// `START:<token>`, and the file is later pulled with it as the bearer token.
  /// 128 bits, as hex. Travels in the QR, then in the clear on the radio — so it
  /// is worth exactly as much as nobody being able to listen in on that one
  /// connection, and no more, which is why it must not also be a key to
  /// something else.
  final String token;

  /// A new session's values. [random] is for a test that has to know them.
  factory BleSession.generate([Random? random]) {
    final source = random ?? Random.secure();
    final token = List<int>.generate(16, (_) => source.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return BleSession(
        locator: BleAdvertisement.newLocator(source), token: token);
  }
}

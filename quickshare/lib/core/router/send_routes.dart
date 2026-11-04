import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/widgets/transport_choice.dart';

/// Where the sending flow starts, and how it is told which transport to use.
///
/// The way to send is chosen on the home screen, so the file screen no longer
/// asks. It is told by the address: `/send?mode=internet`. Everything that
/// builds or reads that address goes through here, so the spelling lives in
/// one place and a value nobody recognises has one answer.
abstract final class SendRoutes {
  /// The home screen. Every way out of the sending flow lands here: the
  /// transport is chosen there, and a transfer that ended, was cancelled or
  /// could not start has nothing to go back to that still means anything.
  static const String home = '/';

  /// The file screen. Meaningless without a [modeParam].
  static const String files = '/send';

  static const String modeParam = 'mode';

  /// The file screen for [mode], e.g. `/send?mode=wifi`.
  static String filesFor(TransportType mode) =>
      Uri(path: files, queryParameters: {modeParam: mode.name}).toString();

  /// The transport [raw] names, or null for anything else: missing, empty, a
  /// different case, a word that was never one.
  static TransportType? parseMode(String? raw) {
    for (final type in TransportType.values) {
      if (type.name == raw) return type;
    }
    return null;
  }

  /// The redirect for the file screen: where to send [uri] instead, or null
  /// to let it through.
  ///
  /// A missing or unreadable `mode` goes **home**, not to a default
  /// transport. Falling back to Wi-Fi would put a person who followed a link
  /// meant for the internet on a different path without telling them, and the
  /// home screen is the one place that asks the question properly. The same
  /// goes for a transport this device cannot use (Bluetooth on a platform the
  /// app does not send over it from).
  ///
  /// Only `/send` itself is judged. The pages below it — `/send/qr`,
  /// `/send/progress` and the rest — are part of a transfer already under way
  /// and carry no mode of their own.
  static String? guard(Uri uri) {
    final path = uri.path.length > 1 && uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    if (path != files) return null;
    final mode = parseMode(uri.queryParameters[modeParam]);
    if (mode == null || !mode.offeredHere) return home;
    return null;
  }

  const SendRoutes._();
}

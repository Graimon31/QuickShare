import 'dart:async';
import 'dart:io';

/// A tiny probe, run beside a transfer in a debug build, that says whether the
/// host's network still opens new TCP connections when a transfer's connection
/// dies. If the transfer's UDP stops while this keeps answering in milliseconds,
/// the loss is in the UDP flow and not in the machine's connectivity.
///
/// (A UDP twin of it was tried and dropped: a bare STUN binding request to
/// public servers got no answer from this machine even while a relayed
/// transfer was running, so its silence proved nothing.)
///
/// Not part of the product: it is read by a person with the logs of a failed
/// run open.
class PathLivenessProbe {
  PathLivenessProbe({
    this.tcpHost = '1.1.1.1',
    this.tcpPort = 443,
    this.timeout = const Duration(milliseconds: 900),
  });

  final String tcpHost;
  final int tcpPort;
  final Duration timeout;

  /// `ok:<ms>` or `timeout` or `error:<type>`.
  Future<String> tcp() async {
    final watch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(tcpHost, tcpPort, timeout: timeout);
      final ms = watch.elapsedMilliseconds;
      socket.destroy();
      return 'ok:$ms';
    } on TimeoutException {
      return 'timeout';
    } on SocketException catch (e) {
      return e.message.contains('timed out') ? 'timeout' : 'error:Socket';
    } catch (e) {
      return 'error:${e.runtimeType}';
    }
  }
}

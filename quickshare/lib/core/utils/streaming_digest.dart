import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

/// SHA-256 over bytes that are already passing through, computed somewhere
/// else.
///
/// Both ends of a transfer need a digest of every file, and there are only
/// three places to get it. Reading the finished file back off the disk is a
/// second full pass over everything, serialised against the transfer.
/// Hashing inline, on the isolate that is also driving TLS and the socket, is
/// cheaper in I/O but costs a third of the throughput: measured on this
/// machine, serving a 400 MB file over the local HTTPS server ran at 53 MB/s
/// with no hashing and 34.7 MB/s with SHA-256 in the same loop — Dart's
/// SHA-256 does about 103 MB/s, and it is competing for the one core the
/// event loop runs on.
///
/// The third place is a worker isolate fed the blocks the transfer has
/// already read. No second read of the disk, and the hashing happens on
/// another core while the first one keeps the link busy. The blocks are
/// copied on the way in — [TransferableTypedData] takes ownership of what it
/// is given, and these bytes are still on their way to a socket — which costs
/// a memcpy per megabyte, around half a percent of the time it buys back.
///
/// Bounded on purpose: [add] waits once more than [_window] blocks are
/// unacknowledged, so a device whose hashing cannot keep up with its network
/// slows the reader rather than growing a queue of megabytes in memory.
class StreamingDigest {
  /// Below this, hashing inline is not worth an isolate.
  ///
  /// Spawning one costs a couple of milliseconds, which is nothing against a
  /// large file and everything against a folder of ten thousand small ones —
  /// where the transfer is dominated by per-item round trips anyway and the
  /// hashing does not show.
  static const int worthAnIsolate = 8 * 1024 * 1024;

  /// How many blocks may be in flight before the producer has to wait.
  static const int _window = 4;

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;
  final StreamQueue<Object?> _incoming;

  var _outstanding = 0;
  var _closed = false;

  StreamingDigest._(
      this._isolate, this._commands, this._replies, this._incoming);

  /// Spawns the worker and waits for it to be ready to take bytes.
  static Future<StreamingDigest> start() async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(_worker, replies.sendPort);
    final incoming = StreamQueue<Object?>(replies);
    final commands = await incoming.next as SendPort;
    return StreamingDigest._(isolate, commands, replies, incoming);
  }

  /// Hands one block to the worker, waiting only if too many are unanswered.
  Future<void> add(List<int> block) async {
    if (_closed) return;
    // Copied because the transfer still needs these bytes: whatever is handed
    // to TransferableTypedData is detached from this isolate.
    _commands.send(TransferableTypedData.fromList(
        [Uint8List.fromList(block)]));
    _outstanding++;
    while (_outstanding >= _window) {
      await _incoming.next;
      _outstanding--;
    }
  }

  /// The digest as `sha256:<hex>`, and the end of the worker.
  Future<String> finish() async {
    if (_closed) throw StateError('digest already finished');
    _closed = true;
    _commands.send(null);
    // Drain the acks still on their way before the answer.
    Object? reply;
    do {
      reply = await _incoming.next;
    } while (reply is! String);
    await _shutdown();
    return reply;
  }

  /// Gives up on a digest that will not be needed — a transfer that failed
  /// half-way. Safe to call after [finish].
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    await _shutdown();
  }

  Future<void> _shutdown() async {
    _isolate.kill(priority: Isolate.immediate);
    await _incoming.cancel(immediate: true);
    _replies.close();
  }

  static void _worker(SendPort replies) {
    final commands = ReceivePort();
    replies.send(commands.sendPort);

    final accumulator = AccumulatorSink<Digest>();
    final hasher = sha256.startChunkedConversion(accumulator);

    commands.listen((Object? message) {
      if (message is TransferableTypedData) {
        hasher.add(message.materialize().asUint8List());
        // The ack is what bounds the producer; see [_window].
        replies.send(1);
        return;
      }
      hasher.close();
      replies.send('sha256:${accumulator.events.single}');
      commands.close();
    });
  }
}

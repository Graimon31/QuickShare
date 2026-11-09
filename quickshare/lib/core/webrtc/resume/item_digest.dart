import 'dart:async';
import 'dart:convert' show ByteConversionSink;
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

import 'package:quickshare/core/utils/streaming_digest.dart';

/// SHA-256 of one file, taken as its bytes go past.
///
/// Both ends of a WebRTC transfer keep one per item: the sender over what it
/// reads, the receiver over what it writes, and the two are compared when the
/// item ends. Small items are hashed where they are; anything at or above
/// [StreamingDigest.worthAnIsolate] goes to a worker isolate, so that the
/// isolate driving the data channel keeps its core (see [StreamingDigest] for
/// the measurements).
///
/// The digest covers the whole file. After a reconnection the side that
/// restarts mid-file begins a new digest and feeds it the part that is already
/// on disk first ([primeFrom]), so what is compared at the end is the whole
/// file as it now is, spliced or not.
abstract class ItemDigest {
  /// A digest for an item of [expectedBytes]. [forceInline] hashes in the
  /// calling isolate whatever the size, for tests under a fake clock where a
  /// worker's reply would never be pumped.
  static Future<ItemDigest> start(int expectedBytes,
      {bool forceInline = false}) async {
    if (forceInline || expectedBytes < StreamingDigest.worthAnIsolate) {
      return _InlineDigest();
    }
    return _WorkerDigest(await StreamingDigest.start());
  }

  /// Hands [bytes] to the digest, in file order. Completes when the digest is
  /// ready for more; a worker that cannot keep up slows the caller down
  /// instead of growing a queue.
  Future<void> add(List<int> bytes);

  /// The SHA-256 of everything added, as 64 lowercase hex digits, and the end
  /// of this digest.
  Future<String> finish();

  /// Drops a digest that will not be needed. Safe after [finish].
  Future<void> abort();

  /// Feeds the first [length] bytes of the file at [path] to this digest, in
  /// blocks, giving the event loop back between them. Used to catch a digest
  /// up with the part of a file that was already on disk when a transfer
  /// resumed. Throws when the file is shorter than [length].
  Future<void> primeFrom(String path, int length) async {
    final raf = await File(path).open();
    try {
      var left = length;
      while (left > 0) {
        final block = await raf.read(left < _primeBlock ? left : _primeBlock);
        if (block.isEmpty) {
          throw FileSystemException(
              'the file is shorter than the $length bytes expected', path);
        }
        await add(block);
        left -= block.length;
        // A megabyte is about ten milliseconds of hashing; between blocks the
        // screen and the sockets get their turn.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await raf.close();
    }
  }

  static const int _primeBlock = 1024 * 1024;
}

class _InlineDigest extends ItemDigest {
  _InlineDigest() {
    _hash = sha256.startChunkedConversion(_out);
  }

  // Closed through the chunked conversion sink in finish/abort.
  // ignore: close_sinks
  final _out = AccumulatorSink<Digest>();
  late final ByteConversionSink _hash;
  var _closed = false;

  @override
  Future<void> add(List<int> bytes) async {
    if (_closed) return;
    _hash.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  }

  @override
  Future<String> finish() async {
    if (_closed) throw StateError('digest already finished');
    _closed = true;
    _hash.close();
    return _out.events.single.toString();
  }

  @override
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    _hash.close();
  }
}

class _WorkerDigest extends ItemDigest {
  _WorkerDigest(this._worker);

  final StreamingDigest _worker;
  var _done = false;

  @override
  Future<void> add(List<int> bytes) =>
      _done ? Future<void>.value() : _worker.add(bytes);

  @override
  Future<String> finish() async {
    if (_done) throw StateError('digest already finished');
    _done = true;
    final tagged = await _worker.finish();
    const prefix = 'sha256:';
    return tagged.startsWith(prefix) ? tagged.substring(prefix.length) : tagged;
  }

  @override
  Future<void> abort() async {
    if (_done) return;
    _done = true;
    await _worker.abort();
  }
}

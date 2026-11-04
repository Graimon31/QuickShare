import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

import 'package:quickshare/core/utils/streaming_digest.dart';

/// The hashing was abandoned because the caller no longer wanted it.
class DigestCancelled implements Exception {
  const DigestCancelled();
  @override
  String toString() => 'the digest was cancelled';
}

/// SHA-256 of a file already on disk, without stalling the isolate that is
/// drawing the screen or driving a socket.
///
/// Re-reading a finished file is the expensive way to get a digest — the
/// streaming one costs nothing because the bytes are going past anyway — and
/// it is needed exactly when the bytes did not go past: a resumed download's
/// earlier half, and a file the resume has to prove is still whole. At
/// roughly a hundred megabytes a second, a multi-gigabyte file is the better
/// part of a minute of pure Dart arithmetic; on the calling isolate that is a
/// minute of dead interface, and a Cancel that does nothing.
class FileDigest {
  const FileDigest._();

  /// How much of the file the worker reads, and hashes, between two looks at
  /// whether it was told to stop. A megabyte is about ten milliseconds of
  /// hashing, which is also how long a cancel can wait for the worker.
  static const int _block = 1024 * 1024;

  /// How long a cancel waits for the worker to put the file down before it
  /// stops waiting and ends the worker by force. Only a read that is stuck —
  /// a share that went away mid-read — gets near it.
  static const Duration _cancelGrace = Duration(seconds: 2);

  /// `sha256:<hex>` of the file at [path].
  ///
  /// Small files are hashed where they are asked for — spawning an isolate
  /// costs more than the read — and anything past
  /// [StreamingDigest.worthAnIsolate] is hashed in a worker. Throws a
  /// [FileSystemException] if the file cannot be read.
  ///
  /// [cancelled] is a future that completes when the caller gives up (a
  /// `CancelToken`'s `whenCancel`). Cancelling is a request to the worker, not
  /// an execution of it: the worker is asked to stop, finishes the block it is
  /// reading, closes the file and says so, and only then does this throw
  /// [DigestCancelled]. So **when [DigestCancelled] is thrown the file is no
  /// longer open** — the caller can rename it, delete it, or start the item
  /// over, which on Windows an open handle forbids. (An isolate that is killed
  /// takes its open files with it only when it is torn down, some time later,
  /// not when the kill is sent.)
  ///
  /// The one exception is a worker that does not answer within [_cancelGrace]
  /// — blocked inside a read the operating system will not return from. A
  /// Cancel that waits for it would be a Cancel that does nothing, so then the
  /// worker is killed and [DigestCancelled] is thrown at once, and the handle
  /// is released when the isolate is torn down. A file small enough to be
  /// hashed in place is read in one go and is not interruptible; [cancelled]
  /// has no effect on it.
  static Future<String> sha256Of(String path, {Future<void>? cancelled}) async {
    final length = await File(path).length();
    if (length < StreamingDigest.worthAnIsolate) {
      final digest = await sha256.bind(File(path).openRead()).first;
      return 'sha256:$digest';
    }

    final replies = ReceivePort();
    final answer = Completer<String>();
    SendPort? commands;
    var stopRequested = false;
    Timer? grace;
    final isolate = await Isolate.spawn(
      _hash,
      _Job(path, replies.sendPort),
      onError: replies.sendPort,
      onExit: replies.sendPort,
      errorsAreFatal: true,
      debugName: 'file-digest',
    );
    final subscription = replies.listen((Object? message) {
      // The worker's way to be told things; it can arrive after a cancel was
      // asked for, in which case the request goes out now.
      if (message is SendPort) {
        commands = message;
        if (stopRequested) message.send(_stop);
        return;
      }
      if (answer.isCompleted) return;
      switch (message) {
        case final String digest:
          answer.complete(digest);
        case _Stopped():
          answer.completeError(const DigestCancelled());
        case final _Failed failed:
          answer.completeError(FileSystemException(failed.message, path));
        case final List<dynamic> errorAndStack:
          answer.completeError(
              FileSystemException('${errorAndStack.first}', path));
        case null:
          answer.completeError(
              FileSystemException('the hashing worker exited early', path));
      }
    });
    unawaited(cancelled?.then((_) {
      if (answer.isCompleted) return;
      stopRequested = true;
      commands?.send(_stop);
      grace = Timer(_cancelGrace, () {
        if (answer.isCompleted) return;
        isolate.kill(priority: Isolate.immediate);
        answer.completeError(const DigestCancelled());
      });
    }));

    try {
      return await answer.future;
    } finally {
      grace?.cancel();
      await subscription.cancel();
      replies.close();
      // By now the worker has put the file down, whichever way it ended; this
      // only makes sure the isolate itself does not outlive the call.
      isolate.kill(priority: Isolate.immediate);
    }
  }

  static const String _stop = 'stop';

  /// Runs on the worker. Reads the file itself, a block at a time, and looks
  /// for a request to stop between blocks — which it can only do because each
  /// read is awaited, and an awaited read lets the isolate take its messages.
  /// The file is closed on every way out, before the answer is sent.
  static Future<void> _hash(_Job job) async {
    final requests = ReceivePort();
    var stop = false;
    requests.listen((Object? message) {
      if (message == _stop) stop = true;
    });
    job.replies.send(requests.sendPort);

    Object result;
    RandomAccessFile? file;
    try {
      file = await File(job.path).open();
      final digest = AccumulatorSink<Digest>();
      final hasher = sha256.startChunkedConversion(digest);
      var stopped = false;
      while (true) {
        if (stop) {
          stopped = true;
          break;
        }
        final block = await file.read(_block);
        if (block.isEmpty) break;
        hasher.add(block);
      }
      if (stopped) {
        result = const _Stopped();
      } else {
        hasher.close();
        result = 'sha256:${digest.events.single}';
      }
    } catch (e) {
      result = _Failed('$e');
    } finally {
      try {
        await file?.close();
      } catch (_) {
        // Nothing is waiting on this handle any more; the answer matters more.
      }
      requests.close();
    }
    job.replies.send(result);
  }
}

class _Job {
  const _Job(this.path, this.replies);
  final String path;
  final SendPort replies;
}

class _Failed {
  const _Failed(this.message);
  final String message;
}

/// The worker was asked to stop, did, and has closed the file.
class _Stopped {
  const _Stopped();
}

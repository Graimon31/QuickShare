import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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

  /// `sha256:<hex>` of the file at [path].
  ///
  /// Small files are hashed where they are asked for — spawning an isolate
  /// costs more than the read — and anything past
  /// [StreamingDigest.worthAnIsolate] is hashed in a worker. [cancelled] is a
  /// future that completes when the caller gives up (a `CancelToken`'s
  /// `whenCancel`); the worker is killed on the spot and this throws
  /// [DigestCancelled]. Throws a [FileSystemException] if the file cannot be
  /// read.
  static Future<String> sha256Of(String path, {Future<void>? cancelled}) async {
    final length = await File(path).length();
    if (length < StreamingDigest.worthAnIsolate) {
      final digest = await sha256.bind(File(path).openRead()).first;
      return 'sha256:$digest';
    }

    final replies = ReceivePort();
    final answer = Completer<String>();
    final isolate = await Isolate.spawn(
      _hash,
      _Job(path, replies.sendPort),
      onError: replies.sendPort,
      onExit: replies.sendPort,
      errorsAreFatal: true,
      debugName: 'file-digest',
    );
    final subscription = replies.listen((Object? message) {
      if (answer.isCompleted) return;
      switch (message) {
        case final String digest:
          answer.complete(digest);
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
      isolate.kill(priority: Isolate.immediate);
      answer.completeError(const DigestCancelled());
    }));

    try {
      return await answer.future;
    } finally {
      await subscription.cancel();
      replies.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  static Future<void> _hash(_Job job) async {
    try {
      final digest = await sha256.bind(File(job.path).openRead()).first;
      job.replies.send('sha256:$digest');
    } catch (e) {
      job.replies.send(_Failed('$e'));
    }
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

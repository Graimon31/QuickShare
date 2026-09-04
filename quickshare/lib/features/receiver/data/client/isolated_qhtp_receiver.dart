import 'dart:async';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_receive_result.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

/// Receiving a session, off the isolate that draws the screen.
///
/// One isolate is one thread: until now the same one decrypted every packet,
/// wrote every block to disk and also rebuilt the progress bar sixty times a
/// second. They took turns, and on a phone — weaker cores, and a screen it is
/// obliged to keep drawing — the turns the interface took were turns the
/// transfer did not. That is what a Desktop→iOS transfer "hanging" was:
/// reads falling behind, the sender waiting on a window that never opened.
///
/// This does not make the transfer faster than it can go. TLS in Dart tops
/// out near 53 MB/s on one isolate whatever else is happening (see
/// benchmark/README.md), and moving it does not raise that. What it removes
/// is everything competing for the same core, so the transfer reaches its
/// ceiling instead of sharing it with the animation of its own progress bar.
///
/// The worker cannot call plugins — those answer only on the main isolate —
/// so every path one would have provided is resolved here first and handed
/// over: where session state lives, and where to write if the destination
/// turns out to be unwritable. Its log lines come back the same way, or the
/// journal would lose exactly the half of itself worth reading.
class IsolatedQhtpReceiver {
  /// Where session resume state is kept, and where to write if the chosen
  /// destination turns out to be unwritable.
  ///
  /// Both are plugin calls by default, which is precisely what the worker
  /// cannot make — so they are resolved out here and handed over. Injectable
  /// because a test has no plugins on either isolate.
  final Future<String> Function() stateDirectory;
  final Future<String> Function() fallbackDirectory;

  IsolatedQhtpReceiver({
    Future<String> Function()? stateDirectory,
    Future<String> Function()? fallbackDirectory,
  })  : stateDirectory = stateDirectory ?? _supportDirectory,
        fallbackDirectory = fallbackDirectory ?? _documentsDirectory;

  static Future<String> _supportDirectory() async =>
      (await getApplicationSupportDirectory()).path;

  static Future<String> _documentsDirectory() async =>
      (await getApplicationDocumentsDirectory()).path;

  Isolate? _isolate;
  SendPort? _commands;
  var _cancelled = false;

  /// Runs a whole session in a worker and reports it as it goes.
  Future<Either<Failure, QhtpReceiveResult>> downloadSession({
    required QRPayload payload,
    required String targetBaseDir,
    void Function(QhtpProgress progress)? onProgress,
  }) async {
    _cancelled = false;
    final replies = ReceivePort();
    final done = Completer<Either<Failure, QhtpReceiveResult>>();

    final stateDir = await stateDirectory();
    final fallbackDir = await fallbackDirectory();

    replies.listen((Object? message) {
      switch (message) {
        case final SendPort port:
          _commands = port;
          // Cancelled while the isolate was still starting: tell it now, or
          // it would run the whole session for a screen nobody is on.
          if (_cancelled) port.send(_cancel);
        case final QhtpProgress progress:
          onProgress?.call(progress);
        case final _WorkerLog line:
          AppLogger.adopt(line.text);
        case final _WorkerResult result:
          if (!done.isCompleted) done.complete(result.value);
        case final _WorkerCrash crash:
          if (!done.isCompleted) {
            done.complete(Left(NetworkFailure(crash.message)));
          }
      }
    });

    try {
      _isolate = await Isolate.spawn(
        _work,
        _WorkerRequest(
          replies: replies.sendPort,
          payload: payload,
          targetBaseDir: targetBaseDir,
          stateDirectory: stateDir,
          fallbackDirectory: fallbackDir,
        ),
        onError: replies.sendPort,
        onExit: replies.sendPort,
        errorsAreFatal: true,
        debugName: 'qhtp-receive',
      );
    } catch (e) {
      replies.close();
      return Left(NetworkFailure('Could not start the transfer: $e'));
    }

    try {
      return await done.future;
    } finally {
      replies.close();
      _isolate?.kill(priority: Isolate.beforeNextEvent);
      _isolate = null;
      _commands = null;
    }
  }

  /// Stops a transfer in flight.
  ///
  /// A message rather than killing the isolate: the worker holds a socket and
  /// a half-written file, and it has a cancel path that closes both properly.
  /// Killing it would leave the partial file unflushed and the sender waiting
  /// on a connection nobody ever closed.
  void cancel() {
    _cancelled = true;
    _commands?.send(_cancel);
  }

  static const String _cancel = 'cancel';

  static Future<void> _work(_WorkerRequest request) async {
    // Everything this isolate logs goes back to the one that owns the
    // journal; see [AppLogger.mirror].
    AppLogger.mirror = (line) => request.replies.send(_WorkerLog(line));

    final commands = ReceivePort();
    final client = QhtpReceiverClient(
      store: SessionStateStore(storeDirectory: request.stateDirectory),
      fallbackDirectory: () async => request.fallbackDirectory,
    );
    commands.listen((Object? message) {
      if (message == _cancel) client.cancel();
    });
    request.replies.send(commands.sendPort);

    try {
      // Both ends of the session, in the journal. Which isolate carried a
      // transfer is the first thing worth knowing when one behaves oddly, and
      // a worker that produced nothing at all is indistinguishable from one
      // that never started.
      AppLogger.info(
          'Receiving from ${request.payload.ip}:${request.payload.port} '
          'in a worker isolate',
          tag: 'QHTP');
      final result = await client.downloadSession(
        payload: request.payload,
        targetBaseDir: request.targetBaseDir,
        onProgress: (progress) => request.replies.send(progress),
      );
      result.fold(
        (failure) => AppLogger.warning('Worker session failed: '
            '${failure.message}', tag: 'QHTP'),
        (_) => AppLogger.info('Worker session finished', tag: 'QHTP'),
      );
      request.replies.send(_WorkerResult(result));
    } catch (e, stack) {
      // Nothing may escape: an uncaught error here kills the isolate and the
      // caller would wait on a future nobody completes.
      AppLogger.error('The receiving worker failed outright',
          error: e, stackTrace: stack, tag: 'QHTP');
      request.replies.send(_WorkerCrash('$e'));
    } finally {
      commands.close();
    }
  }
}

class _WorkerRequest {
  final SendPort replies;
  final QRPayload payload;
  final String targetBaseDir;
  final String stateDirectory;
  final String fallbackDirectory;

  const _WorkerRequest({
    required this.replies,
    required this.payload,
    required this.targetBaseDir,
    required this.stateDirectory,
    required this.fallbackDirectory,
  });
}

class _WorkerLog {
  final String text;
  const _WorkerLog(this.text);
}

class _WorkerResult {
  final Either<Failure, QhtpReceiveResult> value;
  const _WorkerResult(this.value);
}

class _WorkerCrash {
  final String message;
  const _WorkerCrash(this.message);
}

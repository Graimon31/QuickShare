import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/features/sender/data/server/http_range.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LocalHttpServer {
  HttpServer? _server;
  String? _authToken;
  SessionTlsIdentity? _tls;
  Timer? _timeoutTimer;

  /// The fingerprint the receiver must pin this session's HTTPS connection to
  /// — belongs in the QR. Null until a server is started.
  String? get tlsFingerprint => _tls?.fingerprint;
  QhtpManifest? _activeManifest;
  Map<String, String>? _itemIdToAbsPathMap;
  Map<String, Future<String?>>? _itemChecksums;
  int _qhtpBytesSent = 0;

  /// Where the bytes actually went, this session — not who was invited.
  ///
  /// The QR names one address and the direct Wi-Fi link offers another, but
  /// whichever of them the receiver actually opened a socket to is a fact of
  /// the connection, not of the UI state that set the session up. Recording
  /// it here is what lets a transfer's history say which one carried the
  /// bytes instead of guessing from whether the offer succeeded — an offer
  /// that comes up says nothing about which route the far side picked.
  InternetAddress? _lastClientAddress;
  InternetAddress? get lastClientAddress => _lastClientAddress;

  /// When the last progress value went out, for [_progressIsDue].
  DateTime _lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Whether a progress update has waited long enough to be worth sending.
  ///
  /// A chunk is 64 KB, so reporting on each one meant hundreds of events a
  /// second, every one of them a bloc event and a rebuilt screen on a device
  /// that is also trying to read a file and drive a socket. Ten a second is
  /// past what a progress bar can show.
  bool _progressIsDue() {
    final now = DateTime.now();
    if (now.difference(_lastProgressAt) < const Duration(milliseconds: 100)) {
      return false;
    }
    _lastProgressAt = now;
    return true;
  }

  final _progressController = StreamController<double>.broadcast();
  Stream<double> get transferProgress => _progressController.stream;

  bool get isRunning => _server != null;

  /// Legacy single-file start method
  Future<int> start(
    String filePath,
    String fileName,
    String mimeType,
    int fileSize,
    String authToken,
  ) async {
    if (_server != null) {
      await stop();
    }
    // Keeping the screen awake is a nicety, and nothing here depends on it
    // having happened. Awaiting it put a plugin call on the path between the
    // user's selection and the QR — the QHTP start below never did.
    unawaited(WakelockPlus.enable().catchError((_) {}));
    _authToken = authToken;

    final router = Router();

    router.get('/info', (Request request) {
      return Response.ok(
        jsonEncode({'name': fileName, 'size': fileSize, 'mime': mimeType}),
        headers: {'Content-Type': 'application/json'},
      );
    });

    router.head('/download', (Request request) {
      return Response.ok('', headers: {
        'Content-Length': fileSize.toString(),
        'Content-Type': mimeType,
      });
    });

    router.get('/download', (Request request) async {
      final file = File(filePath);
      if (!await file.exists()) {
        return Response.notFound('File not found');
      }

      final actualSize = await file.length();
      var bytesSent = 0;
      var downloadStarted = false;
      final stream = file.openRead().transform<List<int>>(
            StreamTransformer.fromHandlers(
              handleData: (data, sink) {
                sink.add(data);
                bytesSent += data.length;
                downloadStarted = true;
                if (actualSize > 0) {
                  _progressController.add(bytesSent / actualSize);
                }
              },
              handleDone: (sink) {
                sink.close();
                if (downloadStarted) {
                  _progressController.add(1.0);
                  if (bytesSent >= actualSize) {
                    _invalidateToken();
                  }
                }
              },
              handleError: (error, stackTrace, sink) {
                sink.addError(error, stackTrace);
              },
            ),
          );

      return Response.ok(
        stream,
        headers: {
          'Content-Length': actualSize.toString(),
          'Content-Type': mimeType,
          'Content-Disposition':
              "attachment; filename*=UTF-8''${Uri.encodeComponent(fileName)}",
        },
      );
    });

    return _bindServer(router);
  }

  /// QHTP v2 Heavy Session Start Method
  ///
  /// [checksums] is the background hashing of the selection as one future per
  /// item, started after the QR is already up. The manifest answers without
  /// waiting for it — gating the manifest on the full session's digests put
  /// the entire hash run on the receiver's connect path, seconds of
  /// "connecting" for any session under the checksum budget. The receiver
  /// picks up each digest from `GET /v2/files/<id>/digest` when it is about
  /// to verify that item, and hashing outruns the transfer by an order of
  /// magnitude, so that wait is effectively never a wait. Above the checksum
  /// budget the session skips hashes entirely, as before.
  Future<int> startQhtpSession({
    required QhtpManifest manifest,
    required Map<String, String> itemIdToAbsPathMap,
    required String authToken,
    Map<String, Future<String?>>? checksums,
  }) async {
    if (_server != null) {
      await stop();
    }
    WakelockPlus.enable();
    _authToken = authToken;
    _activeManifest = manifest;
    _itemIdToAbsPathMap = itemIdToAbsPathMap;
    _qhtpBytesSent = 0;
    _itemChecksums = checksums;
    if (checksums != null) {
      for (final entry in checksums.entries) {
        // Hashing is best-effort: an item whose digest never arrives is
        // verified by byte count, exactly like a session over the budget.
        // The identity check keeps a previous session's late finisher from
        // merging into this session's manifest — item ids are deterministic,
        // so a stale digest would land on a same-indexed but different file.
        unawaited(entry.value.then((digest) {
          if (digest != null && identical(_itemChecksums, checksums)) {
            _mergeChecksum(entry.key, digest);
          }
        }).catchError((_) => null));
      }
    }

    final router = Router();

    // 1. GET /v2/health (No auth required)
    router.get('/v2/health', (Request request) {
      return Response.ok(
        jsonEncode({'ok': true, 'protocol': 'QHTP', 'protocolVersion': 1}),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );
    });

    // 2. GET /v2/session (Auth required)
    router.get('/v2/session', (Request request) {
      return Response.ok(
        jsonEncode({
          'sessionId': manifest.sessionId,
          'state': 'READY',
          'itemCount': manifest.itemCount,
          'totalBytes': manifest.totalBytes,
          'protocolVersion': 1,
          'supportsRange': true,
          'supportsNdjsonManifest': false,
        }),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );
    });

    // 3. GET /v2/manifest (Auth required)
    router.get('/v2/manifest', (Request request) async {
      // Answers with whatever digests have merged in so far — usually none,
      // hashing has barely started when the receiver asks. Holding this
      // answer until hashing completed used to put the whole session's
      // SHA-256 run between the QR scan and the first byte transferred.
      final active = _activeManifest ?? manifest;
      return Response.ok(
        jsonEncode(active.toJson()),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );
    });

    // 4. GET /v2/files/<id> (Auth required, supports HTTP Range)
    router.get('/v2/files/<id>', (Request request, String id) async {
      _startTimeoutTimer(); // Reset idle timer on authed request
      _recordClientAddress(request);

      final absPath = _itemIdToAbsPathMap?[id];
      if (absPath == null) {
        return Response.notFound(
          jsonEncode({'error': 'Item not found', 'code': 'ITEM_NOT_FOUND'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
        );
      }

      final file = File(absPath);
      if (!await file.exists()) {
        return Response(
          410,
          body: jsonEncode({'error': 'File gone on disk', 'code': 'ITEM_GONE'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
        );
      }

      final item = manifest.items.firstWhere(
        (i) => i.id == id,
        orElse: () => QhtpItem(id: id, path: '', size: 0),
      );

      final totalSize = await file.length();
      final parsed = parseRangeHeader(request.headers['range'], totalSize);

      if (parsed.outcome == RangeOutcome.unsatisfiable) {
        return Response(
          416,
          body: jsonEncode(
              {'error': 'Range Not Satisfiable', 'code': 'INVALID_RANGE'}),
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'Content-Range': 'bytes */$totalSize',
          },
        );
      }

      final isRange = parsed.outcome == RangeOutcome.satisfiable;
      final startOffset = parsed.range?.start ?? 0;
      final endOffset =
          parsed.range?.end ?? (totalSize > 0 ? totalSize - 1 : 0);

      final contentLength = totalSize > 0 ? (endOffset - startOffset + 1) : 0;
      final rawStream = file.openRead(
          startOffset, contentLength > 0 ? startOffset + contentLength : 0);
      final sessionTotalBytes = manifest.totalBytes;
      final stream = rawStream.transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleData: (data, sink) {
            sink.add(data);
            _qhtpBytesSent += data.length;
            if (sessionTotalBytes > 0 && _progressIsDue()) {
              final progress = _qhtpBytesSent / sessionTotalBytes;
              // Byte counting only guesses at completion — retried Range
              // requests count their bytes twice — so it must never reach
              // 1.0: the receiver's POST /v2/session/complete is the one
              // authoritative signal that everything arrived, and the only
              // event allowed to release the session teardown.
              _progressController.add(progress >= 1.0 ? 0.999 : progress);
            }
          },
          handleDone: (sink) => sink.close(),
          handleError: (error, stackTrace, sink) =>
              sink.addError(error, stackTrace),
        ),
      );

      final responseHeaders = {
        'Content-Length': contentLength.toString(),
        'Content-Type': item.mime ?? 'application/octet-stream',
        'Accept-Ranges': 'bytes',
        'X-QS-Item-Id': id,
        'X-QS-Rel-Path': Uri.encodeComponent(item.path),
        'X-QS-Size': totalSize.toString(),
      };

      if (isRange) {
        responseHeaders['Content-Range'] =
            'bytes $startOffset-$endOffset/$totalSize';
        return Response(206, body: stream, headers: responseHeaders);
      }

      return Response.ok(stream, headers: responseHeaders);
    });

    // 4b. GET /v2/files/<id>/digest (Auth required)
    router.get('/v2/files/<id>/digest', (Request request, String id) async {
      _startTimeoutTimer();

      // A manifest that arrived with hashes inline (indexed synchronously)
      // answers from itself; a background-hashed session waits on just this
      // item's future. By the time a receiver has downloaded an item and
      // asks for its digest, that future has long completed — hashing
      // outruns the transfer — so the hold here exists for correctness, not
      // because it is ever expected to bite.
      final active = _activeManifest ?? manifest;
      for (final item in active.items) {
        if (item.id == id && item.sha256 != null && item.sha256!.isNotEmpty) {
          return Response.ok(
            jsonEncode({'sha256': item.sha256}),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
          );
        }
      }

      final pending = _itemChecksums?[id];
      if (pending == null) {
        // No hashing for this session (over the checksum budget) — the
        // receiver falls back to byte-count verification, as designed.
        return Response(204);
      }
      final digest = await pending;
      if (digest == null) {
        // The file vanished mid-hashing; the receiver verifies by size and
        // the download itself will already have failed with a 410.
        return Response(204);
      }
      return Response.ok(
        jsonEncode({'sha256': digest}),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );
    });

    // 5. POST /v2/session/complete (Auth required)
    router.post('/v2/session/complete', (Request request) async {
      // Authoritative completion signal, independent of byte-counted progress
      // (which can undercount across retried/resumed Range requests).
      _progressController.add(1.0);
      return Response.ok(
        jsonEncode({'ok': true}),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );
    });

    // 6. POST /v2/session/cancel (Auth required)
    router.post('/v2/session/cancel', (Request request) async {
      stop();
      return Response.ok(
        jsonEncode({'ok': true}),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );
    });

    return _bindServer(router);
  }

  Future<int> _bindServer(Router router) async {
    final handler = const Pipeline()
        .addMiddleware(_authMiddleware())
        .addHandler(router.call);

    // HTTPS with a throwaway per-session certificate. The receiver pins its
    // fingerprint from the QR, so both the bearer token and the file bytes
    // are unreadable to anyone watching a shared network. Both this and the
    // QHTP v2 routes go through here, so both are covered at once.
    final tls = _tls = SessionTlsIdentity.generate();

    int? boundPort;
    for (int port = AppConstants.serverPortMin;
        port <= AppConstants.serverPortMax;
        port++) {
      try {
        _server = await shelf_io.serve(
          handler,
          InternetAddress.anyIPv4,
          port,
          securityContext: tls.securityContext,
        );
        boundPort = port;
        break;
      } catch (e) {
        // Try next port
      }
    }

    if (boundPort == null) {
      throw Exception('Could not bind server to any port in range.');
    }

    _startTimeoutTimer();
    return boundPort;
  }

  Middleware _authMiddleware() {
    return (Handler innerHandler) {
      return (Request request) async {
        // Unauthenticated by design: /info is a name-and-size preview and
        // /v2/health is a liveness probe. The POST /webrtc/answer route that
        // used to sit here is gone — it accepted an SDP answer from anyone on
        // the network and handed it to the active peer connection, and the
        // rendezvous moved to a sealed out-of-band channel long ago.
        if (request.url.path == 'info' || request.url.path == 'v2/health') {
          return innerHandler(request);
        }

        final authHeader = request.headers['authorization'];
        if (authHeader == null || !authHeader.startsWith('Bearer ')) {
          return Response(
            401,
            body:
                jsonEncode({'error': 'unauthorized', 'code': 'AUTH_REQUIRED'}),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
          );
        }

        final token = authHeader.substring(7);
        // Constant-time token comparison
        if (!_constantTimeEquals(token, _authToken ?? '')) {
          return Response(
            403,
            body: jsonEncode({'error': 'forbidden', 'code': 'AUTH_INVALID'}),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
          );
        }

        // Reset idle timeout on any valid authenticated request
        _startTimeoutTimer();

        return innerHandler(request);
      };
    };
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  void _invalidateToken() {
    _authToken = null;
    stop();
  }

  void _startTimeoutTimer() {
    _timeoutTimer?.cancel();
    final timeoutSecs = _activeManifest != null
        ? AppConstants.qhtpSessionTimeoutSeconds
        : AppConstants.sessionTimeoutSeconds;
    _timeoutTimer = Timer(Duration(seconds: timeoutSecs), () {
      stop();
    });
  }

  /// Notes which address just opened a file-serving connection.
  ///
  /// `shelf_io` attaches the real socket's [HttpConnectionInfo] to every
  /// request under this context key — the one fact in this whole session
  /// that is not something the app told itself, but something the network
  /// actually did.
  void _recordClientAddress(Request request) {
    final info = request.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) {
      _lastClientAddress = info.remoteAddress;
    }
  }

  void _mergeChecksum(String itemId, String digest) {
    final current = _activeManifest;
    if (current == null) return;
    _activeManifest = QhtpManifest(
      sessionId: current.sessionId,
      createdAt: current.createdAt,
      itemCount: current.itemCount,
      totalBytes: current.totalBytes,
      items: [
        for (final item in current.items)
          item.id == itemId
              ? QhtpItem(
                  id: item.id,
                  path: item.path,
                  size: item.size,
                  mtime: item.mtime,
                  mime: item.mime,
                  sha256: digest,
                )
              : item,
      ],
    );
  }

  /// Ends the session. Graceful by default: an in-flight response keeps
  /// writing until it finishes, because for a small single-chunk file the
  /// client's own byte count hits "complete" as soon as the last chunk is
  /// handed to the response sink — often before that chunk has actually
  /// been flushed out of the kernel socket buffer, and a force-close racing
  /// that flush would truncate the response the receiver is still reading.
  ///
  /// [force]: for the one caller that means it — the user pressing Cancel on
  /// a session that is actively sending bytes. There, "let it finish" is
  /// backwards: nothing downstream wants those bytes, and every second the
  /// socket stays open is a second the receiver's connection looks alive
  /// while nothing is coming. Destroying it here lands a TCP reset while the
  /// network underneath is still up — this is called before the hotspot or
  /// peer link that carries it comes down — so the receiver's `await for`
  /// over the response stream fails within about a round trip instead of
  /// riding out its 30-second idle timeout.
  Future<void> stop({bool force = false}) async {
    // Not awaited, for the reason given in [start]: every new session begins
    // by stopping the old one, and releasing a wakelock is not something a
    // transfer should be able to queue behind.
    unawaited(WakelockPlus.disable().catchError((_) {}));
    _timeoutTimer?.cancel();
    _authToken = null;
    _tls = null;
    _activeManifest = null;
    _itemIdToAbsPathMap = null;
    _itemChecksums = null;
    _lastClientAddress = null;
    if (_server != null) {
      await _server!.close(force: force);
      _server = null;
    }
  }
}

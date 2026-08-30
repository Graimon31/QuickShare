import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/features/sender/data/server/http_range.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LocalHttpServer {
  HttpServer? _server;
  String? _authToken;
  Timer? _timeoutTimer;
  QhtpManifest? _activeManifest;
  Map<String, String>? _itemIdToAbsPathMap;
  Future<Map<String, String>>? _checksumsInFlight;
  int _qhtpBytesSent = 0;

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
    try {
      await WakelockPlus.enable();
    } catch (_) {}
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
  /// [checksums] is the background hashing of the selection, started after
  /// the QR is already up. The manifest endpoint holds its answer until the
  /// digests are merged in, so the receiver never sees a hash-less manifest
  /// for a session that is meant to have them — and the QR never waits for
  /// the hashing.
  Future<int> startQhtpSession({
    required QhtpManifest manifest,
    required Map<String, String> itemIdToAbsPathMap,
    required String authToken,
    Future<Map<String, String>>? checksums,
  }) async {
    if (_server != null) {
      await stop();
    }
    WakelockPlus.enable();
    _authToken = authToken;
    _activeManifest = manifest;
    _itemIdToAbsPathMap = itemIdToAbsPathMap;
    _qhtpBytesSent = 0;
    _checksumsInFlight = checksums;
    if (checksums != null) {
      unawaited(checksums.then(_mergeChecksums).catchError((_) {
        // Hashing is best-effort: without it the receiver verifies byte
        // counts, exactly as it does for sessions over the checksum budget.
      }));
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
      // Hold the answer until background hashing has merged in; without the
      // hashes the manifest is still correct, just weaker on verification.
      final pending = _checksumsInFlight;
      if (pending != null) {
        try {
          await pending;
        } catch (_) {}
      }
      final active = _activeManifest ?? manifest;
      return Response.ok(
        jsonEncode(active.toJson()),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );
    });

    // 4. GET /v2/files/<id> (Auth required, supports HTTP Range)
    router.get('/v2/files/<id>', (Request request, String id) async {
      _startTimeoutTimer(); // Reset idle timer on authed request

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
            if (sessionTotalBytes > 0) {
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

    int? boundPort;
    for (int port = AppConstants.serverPortMin;
        port <= AppConstants.serverPortMax;
        port++) {
      try {
        _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
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

  void _mergeChecksums(Map<String, String> hashes) {
    final current = _activeManifest;
    if (current == null || hashes.isEmpty) return;
    _activeManifest = QhtpManifest(
      sessionId: current.sessionId,
      createdAt: current.createdAt,
      itemCount: current.itemCount,
      totalBytes: current.totalBytes,
      items: [
        for (final item in current.items)
          QhtpItem(
            id: item.id,
            path: item.path,
            size: item.size,
            mtime: item.mtime,
            mime: item.mime,
            sha256: hashes[item.id] ?? item.sha256,
          ),
      ],
    );
  }

  Future<void> stop() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
    _timeoutTimer?.cancel();
    _authToken = null;
    _activeManifest = null;
    _itemIdToAbsPathMap = null;
    _checksumsInFlight = null;
    if (_server != null) {
      // force:true (the old value) severs in-flight sockets immediately.
      // For small single-chunk files, the client's own byte count hits
      // "complete" as soon as the last chunk is handed to the response
      // sink — often before that chunk has actually been flushed out of
      // the kernel socket buffer. A force-close racing that flush truncates
      // the response the client is still receiving. Graceful close (the
      // dart:io default) lets in-flight responses finish writing first.
      await _server!.close();
      _server = null;
    }
  }
}

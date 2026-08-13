import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LocalHttpServer {
  HttpServer? _server;
  String? _authToken;
  Timer? _timeoutTimer;
  QhtpManifest? _activeManifest;
  Map<String, String>? _itemIdToAbsPathMap;
  int _qhtpBytesSent = 0;

  WebRtcTransferTransport? activeWebRtcTransport;

  final _progressController = StreamController<double>.broadcast();
  Stream<double> get transferProgress => _progressController.stream;

  bool get isRunning => _server != null;

  void _registerWebRtcRoutes(Router router) {
    router.post('/webrtc/answer', (Request request) async {
      try {
        final bodyText = await request.readAsString();
        final jsonMap = jsonDecode(bodyText) as Map<String, dynamic>;
        final sdp = jsonMap['sdp'] as String?;
        final type = jsonMap['type'] as String? ?? 'answer';
        if (sdp != null && activeWebRtcTransport != null) {
          await activeWebRtcTransport!.handleDirectAnswer(sdp, type);
          return Response.ok(
            jsonEncode({'status': 'accepted'}),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
          );
        }
        return Response.badRequest(
          body: jsonEncode({'error': 'Missing sdp or WebRTC transport active'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
        );
      }
    });
  }

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
    _registerWebRtcRoutes(router);

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
          'Content-Disposition': "attachment; filename*=UTF-8''${Uri.encodeComponent(fileName)}",
        },
      );
    });

    return _bindServer(router);
  }

  /// QHTP v2 Heavy Session Start Method
  Future<int> startQhtpSession({
    required QhtpManifest manifest,
    required Map<String, String> itemIdToAbsPathMap,
    required String authToken,
  }) async {
    if (_server != null) {
      await stop();
    }
    WakelockPlus.enable();
    _authToken = authToken;
    _activeManifest = manifest;
    _itemIdToAbsPathMap = itemIdToAbsPathMap;
    _qhtpBytesSent = 0;

    final router = Router();
    _registerWebRtcRoutes(router);

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
    router.get('/v2/manifest', (Request request) {
      return Response.ok(
        jsonEncode(manifest.toJson()),
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
      final rangeHeader = request.headers['range'];

      int startOffset = 0;
      int endOffset = totalSize > 0 ? totalSize - 1 : 0;
      bool isRange = false;

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        if (parts.isNotEmpty && parts[0].isNotEmpty) {
          startOffset = int.tryParse(parts[0]) ?? 0;
        }
        if (parts.length > 1 && parts[1].isNotEmpty) {
          endOffset = int.tryParse(parts[1]) ?? endOffset;
        }
        if (startOffset <= endOffset && startOffset < totalSize) {
          isRange = true;
        } else if (totalSize > 0) {
          return Response(
            416,
            body: jsonEncode({'error': 'Range Not Satisfiable', 'code': 'INVALID_RANGE'}),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Content-Range': 'bytes */$totalSize',
            },
          );
        }
      }

      final contentLength = totalSize > 0 ? (endOffset - startOffset + 1) : 0;
      final rawStream = file.openRead(startOffset, contentLength > 0 ? startOffset + contentLength : 0);
      final sessionTotalBytes = manifest.totalBytes;
      final stream = rawStream.transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleData: (data, sink) {
            sink.add(data);
            _qhtpBytesSent += data.length;
            if (sessionTotalBytes > 0) {
              final progress = _qhtpBytesSent / sessionTotalBytes;
              _progressController.add(progress > 1.0 ? 1.0 : progress);
            }
          },
          handleDone: (sink) => sink.close(),
          handleError: (error, stackTrace, sink) => sink.addError(error, stackTrace),
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
        responseHeaders['Content-Range'] = 'bytes $startOffset-$endOffset/$totalSize';
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
    final handler = const Pipeline().addMiddleware(_authMiddleware()).addHandler(router.call);

    int? boundPort;
    for (int port = AppConstants.serverPortMin; port <= AppConstants.serverPortMax; port++) {
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
        // Allow unauthed GET /info, GET /v2/health, and POST /webrtc/answer
        if (request.url.path == 'info' ||
            request.url.path == 'v2/health' ||
            request.url.path == 'webrtc/answer') {
          return innerHandler(request);
        }

        final authHeader = request.headers['authorization'];
        if (authHeader == null || !authHeader.startsWith('Bearer ')) {
          return Response(
            401,
            body: jsonEncode({'error': 'unauthorized', 'code': 'AUTH_REQUIRED'}),
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


  Future<void> stop() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
    _timeoutTimer?.cancel();
    _authToken = null;
    _activeManifest = null;
    _itemIdToAbsPathMap = null;
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

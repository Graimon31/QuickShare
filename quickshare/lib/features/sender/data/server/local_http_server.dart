import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/network/device_presence.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/core/transfer/invitation_sender.dart';
import 'package:quickshare/core/transfer/transfer_invitation.dart';
import 'package:quickshare/core/utils/streaming_digest.dart';
import 'package:quickshare/features/sender/data/server/http_range.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';
import 'package:quickshare/core/utils/background_hold.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Represents a pending human-approval request when a receiver asks for files
/// via LAN code entry (/v2/invite/request).
class TransferApprovalRequest {
  final String id;
  final InternetAddress? remoteAddress;
  final String deviceName;
  final String code;
  final int itemCount;
  final int totalBytes;
  final Completer<bool> _completer = Completer<bool>();

  TransferApprovalRequest({
    required this.id,
    required this.remoteAddress,
    required this.deviceName,
    required this.code,
    this.itemCount = 0,
    this.totalBytes = 0,
  });

  Future<bool> get decision => _completer.future;

  void complete(bool accepted) {
    if (!_completer.isCompleted) {
      _completer.complete(accepted);
    }
  }
}

class LocalHttpServer {
  HttpServer? _server;
  String? _authToken;
  String? _sessionPublicId;

  final Map<InternetAddress, List<DateTime>> _codeAttempts = {};
  final Map<InternetAddress, DateTime> _declineCooldowns = {};
  final Map<String, TransferApprovalRequest> _pendingApprovals = {};
  final _approvalController =
      StreamController<TransferApprovalRequest>.broadcast();

  Stream<TransferApprovalRequest> get approvalRequests =>
      _approvalController.stream;

  @visibleForTesting
  Future<bool> Function(TransferApprovalRequest request)? onApprovalRequested;

  void respondToApproval(String requestId, bool accepted) {
    final pending = _pendingApprovals[requestId];
    pending?.complete(accepted);
  }

  Future<bool> _requestApproval(
    TransferApprovalRequest request, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (onApprovalRequested != null) {
      try {
        return await onApprovalRequested!(request)
            .timeout(timeout, onTimeout: () => false);
      } catch (_) {
        return false;
      }
    }
    _pendingApprovals[request.id] = request;
    _approvalController.add(request);
    try {
      return await request.decision.timeout(timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    } finally {
      _pendingApprovals.remove(request.id);
    }
  }

  /// True once the receiver has said the session is delivered. From then on
  /// the token answers for nothing but a repeat of that acknowledgement.
  bool _sessionComplete = false;
  SessionTlsIdentity? _tls;
  Timer? _timeoutTimer;

  /// The fingerprint the receiver must pin this session's HTTPS connection to
  /// — belongs in the QR. Null until a server is started.
  String? get tlsFingerprint => _tls?.fingerprint;
  Completer<void> _firstClient = Completer<void>();

  /// Resolves to true when the first HTTP client reaches this server,
  /// or false if [timeout] expires without any request arriving.
  Future<bool> waitForFirstClient({Duration timeout = const Duration(seconds: 10)}) async {
    try {
      await _firstClient.future.timeout(timeout);
      return true;
    } catch (_) {
      return false;
    }
  }
  QhtpManifest? _activeManifest;
  Map<String, String>? _itemIdToAbsPathMap;
  Map<String, Future<String?>>? _itemChecksums;

  /// The file list, once whatever is producing it has finished.
  ///
  /// A QHTP session serves before it knows what is in it. Walking a
  /// thousand-folder selection is one directory read after another and one
  /// `stat` per file, and holding the QR code behind that made the wait
  /// proportional to the number of files rather than to their size — a
  /// terabyte in four files appeared at once, and forty thousand small ones
  /// took as long as the disk needed to describe every one of them, with
  /// nothing on screen but a spinner. The port is bound and the QR is up as
  /// soon as the socket exists; everything that actually needs the list —
  /// the manifest, the session summary, any file request — waits here.
  Future<QhtpIndexerResult>? _pendingIndex;

  /// Whether the session being served speaks QHTP, independent of whether
  /// its manifest has arrived yet.
  bool _isQhtpSession = false;

  /// Digests worked out while the file was going out over the wire.
  ///
  /// The sender used to hash the whole selection up front, in four worker
  /// isolates, starting the moment the QR appeared — which is the moment the
  /// transfer starts too. Both read every byte of the same files from the
  /// same disk at the same time, and on anything slower than an internal SSD
  /// they simply halved each other. Hashing the bytes as they are read to be
  /// sent costs one pass instead of two and cannot contend with itself.
  final Map<String, String> _streamedDigests = {};

  /// On-demand hashes for the items streaming never covered — a resumed
  /// download served from a Range request, most of all. One per item, kept so
  /// a retried request does not start a second read of the same file.
  final Map<String, Future<String?>> _lazyDigests = {};

  /// How much is read from disk at a time when serving a file.
  ///
  /// `File.openRead()` reads in 64 KB blocks, which at gigabit speeds is
  /// around fifteen thousand reads a second, each one an async hop through
  /// the event loop before the next can start. A megabyte at a time is the
  /// same bytes in a sixteenth of the round trips, and gives the OS a request
  /// big enough to read ahead on.
  static const int _readBlock = 1024 * 1024;

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

  /// The response body: the file, counted as it goes, and hashed beside it.
  ///
  /// One generator rather than a stream transformer, because both of the
  /// things that happen per block now need to wait — the digest worker has a
  /// bounded window, and a transformer's `handleData` is synchronous and has
  /// nowhere to put an await.
  ///
  /// The hashing is on another isolate whenever the file is big enough to be
  /// worth one. It is the same bytes either way; what changes is which core
  /// does it. Measured here on a 400 MB file over the local HTTPS server:
  /// 53 MB/s with no hashing in the loop, 34.7 MB/s with SHA-256 inline. The
  /// event loop is already carrying TLS and the socket, and Dart's SHA-256
  /// wants a whole core to itself.
  Stream<List<int>> _serve({
    required File file,
    required String id,
    required int start,
    required int end,
    required int totalSize,
    required bool digestWanted,
    required int sessionTotalBytes,
  }) async* {
    final inlineHash = digestWanted && totalSize < StreamingDigest.worthAnIsolate
        ? AccumulatorSink<Digest>()
        : null;
    final inline =
        inlineHash == null ? null : sha256.startChunkedConversion(inlineHash);
    final worker = digestWanted && totalSize >= StreamingDigest.worthAnIsolate
        ? await StreamingDigest.start()
        : null;

    var hashedBytes = 0;
    var finished = false;
    try {
      await for (final block in _readRange(file, start, end)) {
        if (inline != null) {
          inline.add(block);
          hashedBytes += block.length;
        } else if (worker != null) {
          await worker.add(block);
          hashedBytes += block.length;
        }

        _qhtpBytesSent += block.length;
        if (sessionTotalBytes > 0 && _progressIsDue()) {
          final progress = _qhtpBytesSent / sessionTotalBytes;
          // Byte counting only guesses at completion — retried Range requests
          // count their bytes twice — so it must never reach 1.0: the
          // receiver's POST /v2/session/complete is the one authoritative
          // signal that everything arrived, and the only event allowed to
          // release the session teardown.
          _progressController.add(progress >= 1.0 ? 0.999 : progress);
        }

        yield block;
      }

      // A read that stopped short — the file truncated under us, or the
      // receiver hanging up — still gets here, so the byte count is what says
      // whether the digest covers the file the manifest describes.
      if (hashedBytes == totalSize && totalSize > 0) {
        if (inline != null && inlineHash != null) {
          inline.close();
          _streamedDigests[id] = 'sha256:${inlineHash.events.single}';
        } else if (worker != null) {
          _streamedDigests[id] = await worker.finish();
          finished = true;
        }
      }
    } finally {
      if (worker != null && !finished) await worker.abort();
    }
  }

  /// Hashes one item because nothing else did, and remembers the attempt.
  ///
  /// Only reached by an item served from a Range request — a resumed
  /// download — since a whole-file response is hashed as it goes out. Kept in
  /// a map so a retried request joins the read already running rather than
  /// starting a second one over the same file.
  Future<String?> _hashOnDemand(String id) {
    final path = _itemIdToAbsPathMap?[id];
    if (path == null) return Future.value(null);
    return _lazyDigests.putIfAbsent(id, () => FileIndexer.hashFile(path));
  }

  /// Reads `[start, end)` of [file] a megabyte at a time, one block ahead.
  ///
  /// The lookahead is what makes it more than a bigger block size: without
  /// it the disk sits idle for as long as the socket takes to accept a block,
  /// and the socket sits idle for as long as the disk takes to produce the
  /// next one — the two alternate instead of overlapping, which is a large
  /// part of why the measured rate sawtoothed well under what the link could
  /// carry. Reads on one handle are queued in order, so issuing the next one
  /// before yielding the current block is safe and keeps the disk busy.
  ///
  /// Exactly one block may be in flight, so the memory this holds is bounded
  /// at two blocks whatever the file size.
  static Stream<List<int>> _readRange(File file, int start, int end) async* {
    final raf = await file.open();
    try {
      if (start > 0) await raf.setPosition(start);
      var remaining = end - start;
      if (remaining <= 0) return;

      Future<Uint8List>? next =
          raf.read(remaining < _readBlock ? remaining : _readBlock);
      while (next != null) {
        final block = await next;
        if (block.isEmpty) break;
        remaining -= block.length;
        next = remaining > 0
            ? raf.read(remaining < _readBlock ? remaining : _readBlock)
            : null;
        yield block;
      }
    } finally {
      await raf.close();
    }
  }

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
    unawaited(BackgroundHold.begin());
    _authToken = authToken;
    _sessionComplete = false;

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
  }) =>
      _serveQhtpSession(
        sessionId: manifest.sessionId,
        index: Future.value(QhtpIndexerResult(
          manifest: manifest,
          itemIdToAbsPathMap: itemIdToAbsPathMap,
        )),
        authToken: authToken,
        checksums: checksums,
      );

  /// Serves a session whose selection is still being walked.
  ///
  /// Returns as soon as the port is bound, which is everything the QR code
  /// needs: an address, a port, a token and a certificate. [index] is the
  /// walk still running; the handlers that need it wait on it, so the first
  /// byte still leaves only once the manifest is real. [sessionId] is known
  /// up front because the caller mints it, not the indexer.
  ///
  /// Nothing here starts the walk or owns its errors: an index that throws
  /// makes every request that needs it answer 500, and the caller is
  /// expected to be watching the same future and to end the session.
  Future<int> startQhtpSessionWhileIndexing({
    required String sessionId,
    required Future<QhtpIndexerResult> index,
    required String authToken,
    String? sessionPublicId,
  }) =>
      _serveQhtpSession(
        sessionId: sessionId,
        index: index,
        authToken: authToken,
        sessionPublicId: sessionPublicId,
      );

  Future<int> _serveQhtpSession({
    required String sessionId,
    required Future<QhtpIndexerResult> index,
    required String authToken,
    Map<String, Future<String?>>? checksums,
    String? sessionPublicId,
  }) async {
    if (_server != null) {
      await stop();
    }
    WakelockPlus.enable();
    unawaited(BackgroundHold.begin());
    _authToken = authToken;
    _sessionPublicId = sessionPublicId;
    _sessionComplete = false;
    _firstClient = Completer<void>();
    _isQhtpSession = true;
    _activeManifest = null;
    _itemIdToAbsPathMap = null;
    _pendingIndex = index;
    _qhtpBytesSent = 0;
    _itemChecksums = checksums;

    // Published the moment the walk lands, so everything that reads the
    // manifest synchronously — the idle timeout, a merged digest — sees it
    // without going through the future again. The identity check keeps a
    // walk that outlived its session from arming the one that replaced it.
    unawaited(index.then((result) {
      if (!identical(_pendingIndex, index)) return;
      _activeManifest = result.manifest;
      _itemIdToAbsPathMap = result.itemIdToAbsPathMap;
    }, onError: (Object _) {
      // The caller owns this failure; here it only means no manifest.
    }));
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

    // POST /v2/invite/request (No auth required — authenticated via 10-digit code)
    router.post('/v2/invite/request', (Request request) async {
      try {
        final connection =
            request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
        final remoteAddress = connection?.remoteAddress;

        // Rate limit attempts per source address (Layer C): max 5 attempts per minute
        if (remoteAddress != null) {
          final now = DateTime.now();
          final attempts = (_codeAttempts[remoteAddress] ??= [])
            ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
          if (attempts.length >= 5) {
            return Response(
              429,
              body: jsonEncode(
                  {'error': 'too many attempts', 'code': 'RATE_LIMITED'}),
              headers: {'Content-Type': 'application/json; charset=utf-8'},
            );
          }
          attempts.add(now);

          final cooldownUntil = _declineCooldowns[remoteAddress];
          if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil)) {
            return Response.ok(
              jsonEncode({
                'outcome': 'declined',
                'detail': 'cooldown',
              }),
              headers: {'Content-Type': 'application/json; charset=utf-8'},
            );
          }
        }

        final bodyText = await request.readAsString();
        final Map<String, dynamic> body;
        try {
          body = jsonDecode(bodyText) as Map<String, dynamic>;
        } catch (_) {
          return Response.badRequest(
            body: jsonEncode({'error': 'invalid json'}),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
          );
        }

        final codeText = body['code'] as String? ?? '';
        final parsedCode = SessionCode.parse(codeText);
        if (parsedCode == null ||
            _sessionPublicId == null ||
            parsedCode.publicId != _sessionPublicId) {
          return Response.forbidden(
            jsonEncode({'error': 'invalid code', 'code': 'CODE_MISMATCH'}),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
          );
        }

        final rawDeviceName = body['deviceName'] as String? ??
            (remoteAddress?.address ?? 'Unknown Device');
        final deviceName = rawDeviceName.length > 40
            ? '${rawDeviceName.substring(0, 40)}…'
            : rawDeviceName;

        final indexed = await _indexOrNull(index);

        final approval = TransferApprovalRequest(
          id: const Uuid().v4(),
          remoteAddress: remoteAddress,
          deviceName: deviceName,
          code: codeText,
          itemCount: indexed?.manifest.itemCount ?? 0,
          totalBytes: indexed?.manifest.totalBytes ?? 0,
        );

        // Sender-side approval (Layer B): human approval required before any token is issued
        final senderAccepted = await _requestApproval(
          approval,
          timeout: const Duration(seconds: 90),
        );
        if (!senderAccepted) {
          if (remoteAddress != null) {
            _declineCooldowns[remoteAddress] =
                DateTime.now().add(const Duration(seconds: 60));
          }
          return Response.ok(
            jsonEncode({
              'outcome': 'declined',
              'detail': 'Transfer declined by sender',
            }),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
          );
        }

        if (indexed == null) return _indexUnavailable();

        final invitePort = body['invitePort'] as int? ?? 0;

        if (invitePort > 0 && remoteAddress != null) {
          final result = await InvitationSender().invite(
            address: remoteAddress,
            port: invitePort,
            invitation: TransferInvitation(
              senderName: DevicePresence.describeThisDevice(),
              senderPlatform: Platform.operatingSystem,
              itemCount: indexed.manifest.itemCount,
              totalBytes: indexed.manifest.totalBytes,
              port: _server?.port ?? 8000,
              sessionId: sessionId,
              token: _authToken ?? '',
              tlsFingerprint: _tls?.fingerprint ?? '',
            ),
          );
          final responseBody = <String, dynamic>{
            'outcome': result.accepted ? 'accepted' : 'declined',
            'detail': result.detail,
          };
          // Token and session details only returned upon explicit acceptance (Layer A)
          if (result.accepted) {
            responseBody.addAll({
              'token': _authToken,
              'sessionId': sessionId,
              'port': _server?.port ?? 8000,
              'tlsFingerprint': _tls?.fingerprint ?? '',
              'itemCount': indexed.manifest.itemCount,
              'totalBytes': indexed.manifest.totalBytes,
              'senderName': DevicePresence.describeThisDevice(),
            });
          } else {
            // Receiver declined the invitation that already received the auth token.
            // Invalidate/stop the session immediately so the issued token cannot be abused.
            unawaited(stop());
          }
          return Response.ok(
            jsonEncode(responseBody),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
          );
        }

        // Long-poll / probe path (invitePort == 0): sender has approved, return token (Layer A)
        return Response.ok(
          jsonEncode({
            'outcome': 'accepted',
            'token': _authToken,
            'sessionId': sessionId,
            'port': _server?.port ?? 8000,
            'tlsFingerprint': _tls?.fingerprint ?? '',
            'itemCount': indexed.manifest.itemCount,
            'totalBytes': indexed.manifest.totalBytes,
            'senderName': DevicePresence.describeThisDevice(),
          }),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error': '$e'}),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
        );
      }
    });

    // 2. GET /v2/session (Auth required)
    //
    // Waits for the walk. The receiver asks this to fill in "how much am I
    // about to accept", and a summary of nothing would be worse than a
    // summary that takes a moment: the counts are the whole answer.
    router.get('/v2/session', (Request request) async {
      final indexed = await _indexOrNull(index);
      if (indexed == null) return _indexUnavailable();
      return Response.ok(
        jsonEncode({
          'sessionId': indexed.manifest.sessionId,
          'state': 'READY',
          'itemCount': indexed.manifest.itemCount,
          'totalBytes': indexed.manifest.totalBytes,
          'protocolVersion': 1,
          'supportsRange': true,
          'supportsNdjsonManifest': false,
          'senderName': DevicePresence.describeThisDevice(),
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
      final indexed = await _indexOrNull(index);
      if (indexed == null) return _indexUnavailable();
      final active = _activeManifest ?? indexed.manifest;
      return Response.ok(
        jsonEncode(active.toJson()),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );
    });

    // 4. GET /v2/files/<id> (Auth required, supports HTTP Range)
    router.get('/v2/files/<id>', (Request request, String id) async {
      _startTimeoutTimer(); // Reset idle timer on authed request
      _recordClientAddress(request);

      // The first request usually arrives while the walk is still running:
      // the receiver scanned a QR that existed before the file list did.
      final indexed = await _indexOrNull(index);
      if (indexed == null) return _indexUnavailable();
      final manifest = indexed.manifest;

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

      // A response that carries the whole file is also the whole input to
      // its digest, so it is hashed on the way past rather than by a second
      // full read of the same file from the same disk. A Range response is a
      // fragment and gets no digest here; `/digest` hashes those on demand.
      final coversWholeFile =
          startOffset == 0 && contentLength == totalSize && totalSize > 0;
      final sessionTotalBytes = manifest.totalBytes;

      final stream = _serve(
        file: file,
        id: id,
        start: startOffset,
        end: contentLength > 0 ? startOffset + contentLength : 0,
        totalSize: totalSize,
        digestWanted: coversWholeFile,
        sessionTotalBytes: sessionTotalBytes,
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

      // Four places a digest can come from, cheapest first.
      //
      // A manifest indexed synchronously carries them inline. Otherwise the
      // ordinary answer is the one worked out while the file was being sent,
      // which is already waiting by the time the receiver — having just
      // finished downloading that item — asks for it. A session started with
      // background hashing still has its future. What is left is an item that
      // never streamed in one piece, a resumed download served from a Range
      // request, and only that one is read off the disk now.
      final indexed = await _indexOrNull(index);
      if (indexed == null) return _indexUnavailable();
      final active = _activeManifest ?? indexed.manifest;
      for (final item in active.items) {
        if (item.id == id && item.sha256 != null && item.sha256!.isNotEmpty) {
          return Response.ok(
            jsonEncode({'sha256': item.sha256}),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
          );
        }
      }

      final streamed = _streamedDigests[id];
      if (streamed != null) {
        return Response.ok(
          jsonEncode({'sha256': streamed}),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
        );
      }

      final digest = await (_itemChecksums?[id] ?? _hashOnDemand(id));
      if (digest == null) {
        // Nothing to hash, or the file vanished: the receiver verifies by
        // size, and a download of a missing file has already failed with a
        // 410.
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
      _sessionComplete = true;
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

  /// The walk's result, or null if it failed.
  ///
  /// Failure is the caller's to report — it knows which folder was
  /// unreadable and has a screen to say so on. All this needs from it is
  /// that there is no list, so the request cannot be answered.
  Future<QhtpIndexerResult?> _indexOrNull(
      Future<QhtpIndexerResult> index) async {
    try {
      return await index;
    } catch (_) {
      return null;
    }
  }

  Response _indexUnavailable() => Response(
        500,
        body: jsonEncode({
          'error': 'The selection could not be read',
          'code': 'INDEX_FAILED',
        }),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );

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
        final path = request.url.path;
        if (path != 'v2/health') {
          if (!_firstClient.isCompleted) _firstClient.complete();
        }
        if (path.startsWith('v2/files') || path == 'v2/invite/request') {
          _recordClientAddress(request);
        }
        // One route is unauthenticated, and it answers nothing about the
        // session: /v2/health says a server of this protocol is listening and
        // stops there. /info used to sit here too, and it is a name and a
        // size — so anyone on the network who guessed a port in 8000–9000
        // learned what was being sent and to whom, with no code and no QR.
        // Its one caller has always sent the token, so requiring it costs
        // nothing.
        //
        // The POST /webrtc/answer route that used to be exempt is gone: it
        // accepted an SDP answer from anyone on the network and handed it to
        // the active peer connection, and the rendezvous moved to a sealed
        // out-of-band channel long ago.
        if (request.url.path == 'v2/health' ||
            request.url.path == 'v2/invite/request') {
          return innerHandler(request);
        }

        // One answer for a missing credential and a wrong one.
        //
        // They used to differ — 401 against 403 — which told anybody probing
        // the port which of the two they had got, and there is nothing here
        // that needs telling them apart. A retry of the completion call is
        // the exception below rather than a third answer.
        Response refuse() => Response(
              401,
              body: jsonEncode(
                  {'error': 'unauthorized', 'code': 'AUTH_REQUIRED'}),
              headers: {'Content-Type': 'application/json; charset=utf-8'},
            );

        final authHeader = request.headers['authorization'];
        if (authHeader == null || !authHeader.startsWith('Bearer ')) {
          return refuse();
        }

        final token = authHeader.substring(7);
        // Constant-time token comparison
        if (!_constantTimeEquals(token, _authToken ?? '')) return refuse();

        // A finished session's token opens nothing further. The server lives
        // on for a moment after the last byte — long enough to be asked
        // again, by the receiver or by anyone who watched it work — and the
        // token was good for all of it.
        //
        // The completion call itself is exempt, and idempotent: the receiver
        // retries it when the answer is lost, and turning a delivered
        // transfer into an error over a repeated acknowledgement would be a
        // worse bug than the one this closes.
        if (_sessionComplete && request.url.path != 'v2/session/complete') {
          return refuse();
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
    _sessionComplete = false;
    stop();
  }

  void _startTimeoutTimer() {
    _timeoutTimer?.cancel();
    // Keyed off the kind of session, not off whether its manifest has
    // landed: a QHTP session serves before it is indexed, and reading the
    // manifest's absence as "this is a legacy session" gave a still-walking
    // selection the shorter timeout.
    final timeoutSecs = _isQhtpSession
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
    unawaited(BackgroundHold.end());
    _timeoutTimer?.cancel();
    _authToken = null;
    _sessionComplete = false;
    _tls = null;
    _activeManifest = null;
    _itemIdToAbsPathMap = null;
    _pendingIndex = null;
    _isQhtpSession = false;
    _itemChecksums = null;
    _streamedDigests.clear();
    _lazyDigests.clear();
    _lastClientAddress = null;
    _firstClient = Completer<void>();
    for (final approval in _pendingApprovals.values) {
      approval.complete(false);
    }
    _pendingApprovals.clear();
    _declineCooldowns.clear();
    _codeAttempts.clear();
    if (_server != null) {
      await _server!.close(force: force);
      _server = null;
    }
  }
}

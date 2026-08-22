import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_receive_result.dart';

class QhtpProgress {
  final String
      phase; // 'connecting' | 'manifest' | 'transferring' | 'verifying' | 'completed' | 'failed'
  final int itemIndex;
  final int itemCount;
  final String itemId;
  final String itemPath;
  final int itemReceived;
  final int itemSize;
  final int sessionReceived;
  final int sessionTotal;
  final int speedBps;

  const QhtpProgress({
    required this.phase,
    required this.itemIndex,
    required this.itemCount,
    required this.itemId,
    required this.itemPath,
    required this.itemReceived,
    required this.itemSize,
    required this.sessionReceived,
    required this.sessionTotal,
    required this.speedBps,
  });
}

class QhtpReceiverClient {
  final Dio dio;
  final SessionStateStore stateStore;
  CancelToken? _cancelToken;

  QhtpReceiverClient({Dio? dioClient, SessionStateStore? store})
      : dio = dioClient ?? Dio(),
        stateStore = store ?? SessionStateStore();

  void cancel() {
    _cancelToken?.cancel('Transfer cancelled by user');
  }

  String sanitizeSegment(String segment) {
    var clean =
        segment.replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_').trim();
    if (clean.isEmpty || clean.replaceAll('.', '').isEmpty) {
      clean = 'item';
    }
    return _fitToNameLimit(clean);
  }

  /// Shortens a name that no filesystem would accept, keeping its extension.
  ///
  /// Refusing the item instead would mean the user does not get their file at
  /// all because its name was long — the wrong trade. The extension is kept
  /// because it is what decides whether the file opens afterwards, and the
  /// middle is what gets dropped.
  ///
  /// Counted in UTF-8 bytes, and cut on a character boundary so the result is
  /// never mojibake.
  String _fitToNameLimit(String name) {
    const limit = AppConstants.qhtpMaxNameBytes;
    if (utf8.encode(name).length <= limit) return name;

    final extension = p.extension(name);
    // An "extension" longer than the budget is not an extension, it is a name
    // with a dot in it.
    final keptExtension =
        utf8.encode(extension).length <= limit ~/ 4 ? extension : '';
    final stem = name.substring(0, name.length - extension.length);
    final stemBudget = limit - utf8.encode(keptExtension).length;

    final buffer = StringBuffer();
    var used = 0;
    for (final rune in stem.runes) {
      final encoded = utf8.encode(String.fromCharCode(rune)).length;
      if (used + encoded > stemBudget) break;
      buffer.writeCharCode(rune);
      used += encoded;
    }
    final shortened = '$buffer$keptExtension';
    return shortened.isEmpty ? 'item' : shortened;
  }

  String materializePath(String relativePath, String baseDir) {
    final segments = relativePath.split('/');
    final safeSegments = <String>[];

    for (final seg in segments) {
      if (seg == '.' || seg == '..' || seg.isEmpty) continue;
      safeSegments.add(sanitizeSegment(seg));
    }

    final resolvedPath = p.normalize(p.joinAll([baseDir, ...safeSegments]));
    if (!p.isWithin(baseDir, resolvedPath) && resolvedPath != baseDir) {
      throw Exception('Path traversal detected: $relativePath');
    }
    return resolvedPath;
  }

  QhtpReceiveResult deriveReceiveResult(
    QhtpManifest manifest,
    String targetBaseDir,
  ) {
    final topLevelNames = <String>{};

    for (final item in manifest.items) {
      final segments = item.path.split('/').where(
          (segment) => segment.isNotEmpty && segment != '.' && segment != '..');
      final root = segments.isEmpty ? null : sanitizeSegment(segments.first);
      if (root != null) {
        topLevelNames.add(root);
      }
    }

    final sortedTopLevelNames = topLevelNames.toList()..sort();
    if (sortedTopLevelNames.length == 1) {
      final rootName = sortedTopLevelNames.single;
      return QhtpReceiveResult(
        preferredResultPath: p.join(targetBaseDir, rootName),
        displayName: rootName,
      );
    }

    return QhtpReceiveResult(
      preferredResultPath: targetBaseDir,
      displayName: sortedTopLevelNames.isEmpty
          ? 'Received files'
          : '${sortedTopLevelNames.length} items',
    );
  }

  /// Checks a finished `.qs.partial` against the manifest before it is
  /// published under its real name, and returns the digest to record.
  ///
  /// Deletes the partial on any mismatch, so the retry starts from zero rather
  /// than resuming onto bytes already known to be wrong. Throws to signal the
  /// caller's retry loop.
  Future<String?> _verifyPartial({
    required File partial,
    required QhtpItem item,
  }) async {
    final writtenBytes = await partial.length();
    if (item.size > 0 && writtenBytes != item.size) {
      await partial.delete();
      throw Exception(
          'size mismatch for ${item.path}: received $writtenBytes bytes, '
          'manifest declares ${item.size}');
    }

    final expected = item.sha256;
    final digest = await sha256.bind(partial.openRead()).first;
    final actual = 'sha256:$digest';

    if (expected != null && expected.isNotEmpty && actual != expected) {
      await partial.delete();
      throw Exception('checksum mismatch for ${item.path}: '
          'expected $expected, computed $actual');
    }
    return actual;
  }

  Future<int?> _getAvailableDiskSpace(String dirPath) async {
    // The disk_space_2 iOS plugin crashes while registering on iOS 18.4.1.
    // This check is advisory; transfers remain safe because the file is
    // written incrementally and all I/O errors are handled by the caller.
    debugPrint('Disk space preflight skipped for $dirPath.');
    return null;
  }

  Future<Either<Failure, QhtpReceiveResult>> downloadSession({
    required QRPayload payload,
    required String targetBaseDir,
    void Function(QhtpProgress progress)? onProgress,
  }) async {
    _cancelToken = CancelToken();

    try {
      final host = payload.ip;
      final port = payload.port;
      final token = payload.token;
      final sessionId = payload.sessionId ??
          'session_${DateTime.now().millisecondsSinceEpoch}';

      onProgress?.call(const QhtpProgress(
        phase: 'connecting',
        itemIndex: 0,
        itemCount: 0,
        itemId: '',
        itemPath: '',
        itemReceived: 0,
        itemSize: 0,
        sessionReceived: 0,
        sessionTotal: 0,
        speedBps: 0,
      ));

      // Longer connect timeout: iOS may show the Local Network permission
      // dialog on the first LAN request and block until the user answers.
      final options = Options(
        headers: {'Authorization': 'Bearer $token'},
        connectTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
      );

      // 1. GET /v2/session
      final sessionRes =
          await dio.get('http://$host:$port/v2/session', options: options);
      if (sessionRes.statusCode != 200) {
        return Left(NetworkFailure(
            'Failed to connect to QHTP session (status ${sessionRes.statusCode})'));
      }

      final sessionData = sessionRes.data as Map<String, dynamic>;
      final totalBytes = sessionData['totalBytes'] as int? ?? 0;
      final itemCount = sessionData['itemCount'] as int? ?? 0;

      // 2. Preflight Limits & Disk Check
      if (itemCount > AppConstants.qhtpMaxFileCount) {
        return Left(FileFailure(
            'Session file count ($itemCount) exceeds max limit of ${AppConstants.qhtpMaxFileCount}'));
      }
      if (totalBytes > AppConstants.qhtpMaxSessionBytes) {
        return const Left(FileFailure('Session size exceeds max limit of 500 GB'));
      }

      // Keep the transport safe even if another caller supplies the old
      // iOS ~/Downloads path. iOS only permits writing inside the app's
      // sandbox; Documents is exposed to the Files app by Info.plist.
      final resolvedTargetBaseDir = Platform.isIOS
          ? (await getApplicationDocumentsDirectory()).path
          : targetBaseDir;
      final targetDir = Directory(resolvedTargetBaseDir);
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final freeDiskBytes = await _getAvailableDiskSpace(resolvedTargetBaseDir);
      final requiredBytes =
          totalBytes + 64 * 1024 * 1024; // totalBytes + 64MB margin
      if (freeDiskBytes != null && freeDiskBytes < requiredBytes) {
        return Left(FileFailure(
            'Not enough disk space. Required: ${(requiredBytes / (1024 * 1024)).toStringAsFixed(0)} MB'));
      }

      // 3. GET /v2/manifest
      onProgress?.call(QhtpProgress(
        phase: 'manifest',
        itemIndex: 0,
        itemCount: itemCount,
        itemId: '',
        itemPath: '',
        itemReceived: 0,
        itemSize: 0,
        sessionReceived: 0,
        sessionTotal: totalBytes,
        speedBps: 0,
      ));

      final manifestRes =
          await dio.get('http://$host:$port/v2/manifest', options: options);
      if (manifestRes.statusCode != 200) {
        return const Left(NetworkFailure('Failed to fetch session manifest'));
      }

      final manifestMap = manifestRes.data is String
          ? jsonDecode(manifestRes.data as String)
          : manifestRes.data;
      final manifest =
          QhtpManifest.fromJson(manifestMap as Map<String, dynamic>);

      // Load or initialize state store for resume
      final localState = await stateStore.loadState(sessionId) ?? {};

      int sessionReceivedBytes = 0;
      for (final item in manifest.items) {
        final state = localState[item.id];
        if (state != null && state.status == 'completed') {
          sessionReceivedBytes += item.size;
        }
      }

      DateTime lastSpeedUpdate = DateTime.now();
      int lastBytesReceived = sessionReceivedBytes;
      int currentSpeedBps = 0;

      // 4. Transfer each item in order with per-file 3x retry
      for (int i = 0; i < manifest.items.length; i++) {
        if (_cancelToken?.isCancelled ?? false) {
          return const Left(FileFailure('Transfer cancelled by user'));
        }

        final item = manifest.items[i];
        final itemIndex = i + 1;

        var itemState = localState[item.id] ??
            QhtpItemState(
                id: item.id,
                path: item.path,
                size: item.size,
                status: 'pending');

        if (itemState.status == 'completed') {
          continue;
        }

        final finalPath = materializePath(item.path, resolvedTargetBaseDir);
        final partialPath = '$finalPath.qs.partial';

        final parentDir = Directory(p.dirname(finalPath));
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
        }

        // Per-file retry up to 3 attempts
        bool itemSuccess = false;
        String? itemError;

        for (int attempt = 1;
            attempt <= AppConstants.maxRetryAttempts;
            attempt++) {
          if (_cancelToken?.isCancelled ?? false) {
            return const Left(FileFailure('Transfer cancelled by user'));
          }

          IOSink? fileSink;
          try {
            final partialFile = File(partialPath);
            int existingBytes = 0;
            if (await partialFile.exists()) {
              existingBytes = await partialFile.length();
            }

            if (item.size > 0 && existingBytes > item.size) {
              // A previous attempt wrote past the declared end — a 200 answered
              // to a Range request appends a whole second copy. Clamping the
              // counter used to hide that and rename an oversized file as
              // complete; start the item over instead.
              await partialFile.delete();
              existingBytes = 0;
            }

            fileSink = partialFile.openWrite(
              mode: existingBytes > 0 ? FileMode.append : FileMode.write,
            );

            int itemReceivedBytes = existingBytes;

            if (existingBytes < item.size) {
              final downloadOptions = Options(
                headers: {
                  'Authorization': 'Bearer $token',
                  if (existingBytes > 0) 'Range': 'bytes=$existingBytes-',
                },
                responseType: ResponseType.stream,
                sendTimeout: const Duration(seconds: 10),
                receiveTimeout: null, // Unlimited for file body stream
              );

              final fileUrl = 'http://$host:$port/v2/files/${item.id}';
              final response = await dio.get<ResponseBody>(
                fileUrl,
                options: downloadOptions,
                cancelToken: _cancelToken,
              );

              if (existingBytes > 0 && response.statusCode == 200) {
                // 200 means the server ignored the Range header and is sending
                // from byte zero. Appending that to a partial file silently
                // corrupts it, which is how resumed downloads used to break.
                throw Exception(
                    'Server ignored the Range request (200 instead of 206)');
              }
              if (response.statusCode != 200 && response.statusCode != 206) {
                throw Exception(
                    'Server returned status ${response.statusCode}');
              }

              final stream = response.data!.stream;

              await for (final Uint8List chunk in stream) {
                fileSink.add(chunk);
                itemReceivedBytes += chunk.length;
                sessionReceivedBytes += chunk.length;

                final now = DateTime.now();
                final deltaSec =
                    now.difference(lastSpeedUpdate).inMilliseconds / 1000.0;
                if (deltaSec >= 0.5) {
                  final deltaBytes = sessionReceivedBytes - lastBytesReceived;
                  currentSpeedBps = (deltaBytes / deltaSec).round();
                  lastSpeedUpdate = now;
                  lastBytesReceived = sessionReceivedBytes;
                }

                onProgress?.call(QhtpProgress(
                  phase: 'transferring',
                  itemIndex: itemIndex,
                  itemCount: manifest.itemCount,
                  itemId: item.id,
                  itemPath: item.path,
                  itemReceived: itemReceivedBytes,
                  itemSize: item.size,
                  sessionReceived: sessionReceivedBytes,
                  sessionTotal: manifest.totalBytes,
                  speedBps: currentSpeedBps,
                ));
              }
            }

            await fileSink.flush();
            await fileSink.close();
            fileSink = null;

            // 5. Verify, then rename. In that order: the old code renamed
            // first and hashed afterwards without comparing to anything, so a
            // truncated or corrupted file was published as complete.
            onProgress?.call(QhtpProgress(
              phase: 'verifying',
              itemIndex: itemIndex,
              itemCount: manifest.itemCount,
              itemId: item.id,
              itemPath: item.path,
              itemReceived: itemReceivedBytes,
              itemSize: item.size,
              sessionReceived: sessionReceivedBytes,
              sessionTotal: manifest.totalBytes,
              speedBps: currentSpeedBps,
            ));

            final checksumStr = await _verifyPartial(
              partial: partialFile,
              item: item,
            );

            final finalFile = File(finalPath);
            if (await finalFile.exists()) {
              await finalFile.delete();
            }
            await partialFile.rename(finalPath);

            itemState = itemState.copyWith(
              status: 'completed',
              partialBytes: item.size,
              sha256: checksumStr,
              finalPath: finalPath,
            );

            localState[item.id] = itemState;
            await stateStore.saveState(
              sessionId: sessionId,
              host: host,
              port: port,
              token: token,
              baseDir: resolvedTargetBaseDir,
              items: localState,
            );

            itemSuccess = true;
            break; // Success, break retry loop
          } catch (e) {
            itemError = e.toString();
            if (attempt < AppConstants.maxRetryAttempts) {
              await Future.delayed(Duration(seconds: attempt));
            }
          } finally {
            // The sink used to be left open on every failed attempt, leaking a
            // handle per retry and — worse — letting buffered bytes land in the
            // file after the next attempt had already measured its length.
            if (fileSink != null) {
              try {
                await fileSink.flush();
              } catch (_) {}
              try {
                await fileSink.close();
              } catch (_) {}
            }
          }
        }

        if (!itemSuccess) {
          return Left(NetworkFailure(
              'Failed to download ${item.path} after ${AppConstants.maxRetryAttempts} retries: $itemError'));
        }
      }

      // 6. Signal completion to sender
      try {
        await dio.post(
          'http://$host:$port/v2/session/complete',
          data: {
            'sessionId': sessionId,
            'receivedItems': manifest.itemCount,
            'receivedBytes': manifest.totalBytes,
            'failedItems': 0,
          },
          options: options,
        );
      } catch (e) {
        // Complete signal best effort
      }

      await stateStore.deleteState(sessionId);

      onProgress?.call(QhtpProgress(
        phase: 'completed',
        itemIndex: manifest.itemCount,
        itemCount: manifest.itemCount,
        itemId: '',
        itemPath: '',
        itemReceived: 0,
        itemSize: 0,
        sessionReceived: manifest.totalBytes,
        sessionTotal: manifest.totalBytes,
        speedBps: 0,
      ));

      return Right(deriveReceiveResult(manifest, resolvedTargetBaseDir));
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        return const Left(FileFailure('Transfer cancelled'));
      }
      debugPrint('QHTP Client download error: $e');
      final isTimeout = e is DioException &&
          (e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout ||
              e.type == DioExceptionType.connectionError);
      final msg = isTimeout
          ? 'Cannot reach sender (${payload.ip}:${payload.port}). Make sure both your iPhone and Mac are connected to the SAME Wi-Fi network (and not using LTE).'
          : 'QHTP download failed: ${e.toString()}';
      return Left(NetworkFailure(msg));
    }
  }
}

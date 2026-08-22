import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class QhtpItemState {
  final String id;
  final String path;
  final int size;
  final String status; // 'pending', 'partial', 'completed', 'failed'
  final int partialBytes;
  final String? sha256;
  final String? finalPath;

  const QhtpItemState({
    required this.id,
    required this.path,
    required this.size,
    required this.status,
    this.partialBytes = 0,
    this.sha256,
    this.finalPath,
  });

  factory QhtpItemState.fromJson(Map<String, dynamic> json) {
    return QhtpItemState(
      id: json['id'] as String? ?? '',
      path: json['path'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      status: json['status'] as String? ?? 'pending',
      partialBytes: json['partialBytes'] as int? ?? 0,
      sha256: json['sha256'] as String?,
      finalPath: json['finalPath'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'path': path,
      'size': size,
      'status': status,
      'partialBytes': partialBytes,
      if (sha256 != null) 'sha256': sha256,
      if (finalPath != null) 'finalPath': finalPath,
    };
  }

  QhtpItemState copyWith({
    String? status,
    int? partialBytes,
    String? sha256,
    String? finalPath,
  }) {
    return QhtpItemState(
      id: id,
      path: path,
      size: size,
      status: status ?? this.status,
      partialBytes: partialBytes ?? this.partialBytes,
      sha256: sha256 ?? this.sha256,
      finalPath: finalPath ?? this.finalPath,
    );
  }
}

class SessionStateStore {
  /// Where session records live. Injected so the one part of this app that
  /// deletes files can be tested against a scratch directory instead of the
  /// user's own.
  ///
  /// Optional rather than required: production has exactly one answer for it,
  /// and making it required would force every construction site to become
  /// async for no gain. Tests pass a temp directory and get the real
  /// filesystem — worth more than an in-memory stand-in here, because the bugs
  /// this code can have are path bugs.
  final String? _storeDirectoryOverride;

  SessionStateStore({String? storeDirectory})
      : _storeDirectoryOverride = storeDirectory;

  /// Directory path for storing session state files
  Future<String> _getStoreDir() async {
    final root = _storeDirectoryOverride ??
        (await getApplicationSupportDirectory()).path;
    final dir = Directory(p.join(root, 'qhtp_sessions'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Future<File> _getStateFile(String sessionId) async {
    final dir = await _getStoreDir();
    return File(p.join(dir, '$sessionId.json'));
  }

  Future<Map<String, QhtpItemState>?> loadState(String sessionId) async {
    try {
      final file = await _getStateFile(sessionId);
      if (!await file.exists()) return null;

      final jsonStr = await file.readAsString();
      final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final itemsMap = jsonMap['items'] as Map<String, dynamic>? ?? {};

      final Map<String, QhtpItemState> result = {};
      itemsMap.forEach((id, val) {
        result[id] = QhtpItemState.fromJson(val as Map<String, dynamic>);
      });
      return result;
    } catch (e) {
      return null;
    }
  }

  Future<void> saveState({
    required String sessionId,
    required String host,
    required int port,
    required String token,
    required String baseDir,
    required Map<String, QhtpItemState> items,
  }) async {
    try {
      final file = await _getStateFile(sessionId);
      final jsonMap = {
        'protocolVersion': 1,
        'sessionId': sessionId,
        'host': host,
        'port': port,
        'token': token,
        'baseDir': baseDir,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'items': items.map((id, item) => MapEntry(id, item.toJson())),
      };
      await file.writeAsString(jsonEncode(jsonMap));
    } catch (e) {
      // Best effort state save
    }
  }

  Future<void> deleteState(String sessionId) async {
    try {
      final file = await _getStateFile(sessionId);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // Best effort
    }
  }

  /// Deletes abandoned sessions and — the part that actually matters — the
  /// partial downloads they were tracking.
  ///
  /// Removing the bookkeeping alone would be worse than doing nothing: the
  /// `.qs.partial` files live inside the app sandbox, nothing else on the
  /// device knows about them, and the state file was the only record of where
  /// they are. An interrupted 10 GB transfer would leave 10 GB stranded with no
  /// way to find it again short of the user reinstalling the app.
  ///
  /// So the state is read first, its partials are removed, and only then is the
  /// record itself dropped. A state whose files cannot be deleted is left
  /// alone to be retried on the next sweep rather than orphaned.
  ///
  /// Returns the number of bytes reclaimed, for the log.
  Future<int> cleanExpiredStates({
    Duration ttl = const Duration(hours: 24),
  }) async {
    var reclaimed = 0;
    try {
      final dir = Directory(await _getStoreDir());
      if (!await dir.exists()) return 0;
      final cutoff = DateTime.now().subtract(ttl);

      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final stat = await entity.stat();
        if (stat.modified.isAfter(cutoff)) continue;

        reclaimed += await _deletePartialsOf(entity);
        await entity.delete();
      }
    } catch (e) {
      // Best effort: a failed sweep must never stop the app from starting.
      debugPrint('Session cleanup failed: $e');
    }
    if (reclaimed > 0) {
      debugPrint('Session cleanup reclaimed $reclaimed bytes');
    }
    return reclaimed;
  }

  /// Removes the `.qs.partial` files belonging to one expired state file.
  ///
  /// Completed items are deliberately left alone — those are files the user
  /// asked for and already has.
  Future<int> _deletePartialsOf(File stateFile) async {
    var reclaimed = 0;
    try {
      final jsonMap =
          jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      final baseDir = jsonMap['baseDir'] as String?;
      final items = jsonMap['items'] as Map<String, dynamic>? ?? {};
      if (baseDir == null || baseDir.isEmpty) return 0;

      for (final raw in items.values) {
        final item = QhtpItemState.fromJson(raw as Map<String, dynamic>);
        if (item.status == 'completed') continue;

        final finalPath = item.finalPath ??
            p.joinAll([
              baseDir,
              ...item.path.split('/').where((segment) => segment.isNotEmpty),
            ]);
        final partial = File('$finalPath.qs.partial');
        if (!await partial.exists()) continue;

        // Guard against a state file that points outside the directory it
        // claims: this deletes files, so a malformed record must not be able
        // to aim it somewhere else.
        if (!p.isWithin(baseDir, partial.path)) {
          debugPrint('Refusing to delete ${partial.path}: outside $baseDir');
          continue;
        }
        reclaimed += await partial.length();
        await partial.delete();
      }
    } catch (e) {
      debugPrint('Could not clean partials for ${stateFile.path}: $e');
    }
    return reclaimed;
  }
}

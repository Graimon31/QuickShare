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

  /// The file's modification time (milliseconds since the epoch) as it was
  /// when the item was recorded complete. A resume that has no digest to
  /// compare against can still tell that the file was touched since.
  final int? modifiedMs;

  const QhtpItemState({
    required this.id,
    required this.path,
    required this.size,
    required this.status,
    this.partialBytes = 0,
    this.sha256,
    this.finalPath,
    this.modifiedMs,
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
      modifiedMs: json['modifiedMs'] as int?,
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
      if (modifiedMs != null) 'modifiedMs': modifiedMs,
    };
  }

  QhtpItemState copyWith({
    String? status,
    int? partialBytes,
    String? sha256,
    String? finalPath,
    int? modifiedMs,
  }) {
    return QhtpItemState(
      id: id,
      path: path,
      size: size,
      status: status ?? this.status,
      partialBytes: partialBytes ?? this.partialBytes,
      sha256: sha256 ?? this.sha256,
      finalPath: finalPath ?? this.finalPath,
      modifiedMs: modifiedMs ?? this.modifiedMs,
    );
  }
}

/// A saved session as a whole: its items, and the session and destination it
/// was recorded for. [sessionId] and [baseDir] are null when the store that
/// answered did not keep them (a test double).
class SavedSession {
  const SavedSession({required this.items, this.sessionId, this.baseDir});

  final Map<String, QhtpItemState> items;
  final String? sessionId;
  final String? baseDir;
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

  /// `sessionId` reaches this class straight from `sid` in a scanned QR code
  /// or a pasted share link — nothing between the wire and here validates it.
  /// Unsanitized, `../../../../Library/LaunchAgents/x` turns every read,
  /// write and delete below into a path traversal: `File()` does not
  /// interpret `..`, but the filesystem does the moment the path is actually
  /// opened, so a crafted id reads, overwrites or deletes an arbitrary
  /// `.json` file anywhere this process can reach — the whole disk outside
  /// the sandbox, not just this app's own directory.
  ///
  /// An allowlist rather than a blocklist replace: this id is never shown to
  /// anyone, so there is nothing to preserve about its shape, and a
  /// characters-to-strip list is exactly the kind of check one forgotten
  /// separator quietly defeats. The same malicious id always sanitizes to the
  /// same safe string, so resume still finds its own state file again.
  String _sanitizeSessionId(String sessionId) {
    final clean = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final trimmed = clean.length > 200 ? clean.substring(0, 200) : clean;
    return trimmed.isEmpty ? 'session' : trimmed;
  }

  Future<File> _getStateFile(String sessionId) async {
    final dir = await _getStoreDir();
    final file = File(p.join(dir, '${_sanitizeSessionId(sessionId)}.json'));
    // Defense in depth: if sanitization above ever has a gap, this refuses to
    // hand back a path outside the directory it is supposed to be confined
    // to, rather than trusting the allowlist alone.
    if (!p.isWithin(dir, file.path)) {
      throw StateError('Refusing a session state path outside $dir: '
          '${file.path}');
    }
    return file;
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

  /// The record for [sessionId] with the session and destination it carries.
  ///
  /// A resume must not believe a record that was made for something else: the
  /// store is keyed by a *sanitised* id (two ids can share a file), and the
  /// folder the user picks this time need not be the one the files were
  /// received into last time. Built on [loadState] so a store that overrides
  /// only that still resumes.
  Future<SavedSession?> loadSession(String sessionId) async {
    final items = await loadState(sessionId);
    if (items == null) return null;
    String? savedId;
    String? savedBase;
    try {
      final file = await _getStateFile(sessionId);
      if (await file.exists()) {
        final map = jsonDecode(await file.readAsString());
        if (map is Map<String, dynamic>) {
          savedId = map['sessionId'] as String?;
          savedBase = map['baseDir'] as String?;
        }
      }
    } catch (_) {
      // No header is no header; the items stand on their own.
    }
    return SavedSession(items: items, sessionId: savedId, baseDir: savedBase);
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
      // Written beside the record and renamed over it: a crash in the middle
      // of a plain write leaves a truncated file that cannot be parsed, and a
      // record that cannot be read is a resume that forgets every pinned name.
      final scratch = File('${file.path}.tmp');
      await scratch.writeAsString(jsonEncode(jsonMap), flush: true);
      await scratch.rename(file.path);
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

  /// The `.qs.partial` files that a session still on record may resume, as
  /// absolute paths.
  ///
  /// "Still on record" is the same test [cleanExpiredStates] applies: a state
  /// file touched within [ttl]. The QHTP client tells the user that a cut
  /// transfer can be picked up again — after freeing disk space, say — and
  /// this is the list of what that promise covers. Anything that sweeps
  /// partials as debris has to leave these alone.
  ///
  /// A state file that cannot be read pins nothing: the client cannot resume
  /// from it either. Failing to look at the store at all throws, because a
  /// caller that is about to delete files must not take "I could not tell" for
  /// "nothing is pinned".
  Future<Set<String>> pinnedPartials({
    Duration ttl = const Duration(hours: 24),
  }) async {
    final pinned = <String>{};
    final dir = Directory(await _getStoreDir());
    final cutoff = DateTime.now().subtract(ttl);
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final stat = await entity.stat();
      if (!stat.modified.isAfter(cutoff)) continue;
      try {
        pinned.addAll(await _partialPathsOf(entity));
      } catch (e) {
        debugPrint('Could not read ${entity.path} for its partials: $e');
      }
    }
    return pinned;
  }

  /// The `.qs.partial` path of every unfinished item in one state file.
  ///
  /// Completed items are left out — those are files the user asked for and
  /// already has. A path outside the directory the record claims is left out
  /// too: this feeds deletions and exemptions alike, and a malformed record
  /// must not be able to aim either somewhere else.
  Future<List<String>> _partialPathsOf(File stateFile) async {
    final jsonMap =
        jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
    final baseDir = jsonMap['baseDir'] as String?;
    final items = jsonMap['items'] as Map<String, dynamic>? ?? {};
    if (baseDir == null || baseDir.isEmpty) return const [];

    final paths = <String>[];
    for (final raw in items.values) {
      final item = QhtpItemState.fromJson(raw as Map<String, dynamic>);
      if (item.status == 'completed') continue;

      final finalPath = item.finalPath ??
          p.joinAll([
            baseDir,
            ...item.path.split('/').where((segment) => segment.isNotEmpty),
          ]);
      final partial = '$finalPath.qs.partial';
      if (!p.isWithin(baseDir, partial)) {
        debugPrint('Ignoring $partial: outside $baseDir');
        continue;
      }
      paths.add(partial);
    }
    return paths;
  }

  /// Removes the `.qs.partial` files belonging to one expired state file.
  ///
  /// Completed items are deliberately left alone — those are files the user
  /// asked for and already has.
  Future<int> _deletePartialsOf(File stateFile) async {
    var reclaimed = 0;
    try {
      for (final path in await _partialPathsOf(stateFile)) {
        final partial = File(path);
        if (!await partial.exists()) continue;
        reclaimed += await partial.length();
        await partial.delete();
      }
    } catch (e) {
      debugPrint('Could not clean partials for ${stateFile.path}: $e');
    }
    return reclaimed;
  }
}

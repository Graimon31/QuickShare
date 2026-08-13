import 'dart:convert';
import 'dart:io';
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
  /// Directory path for storing session state files
  Future<String> _getStoreDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'qhtp_sessions'));
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

  /// Clean up states older than 24 hours (RESUME_STATE_TTL_MS)
  Future<void> cleanExpiredStates() async {
    try {
      final dirPath = await _getStoreDir();
      final dir = Directory(dirPath);
      final now = DateTime.now().millisecondsSinceEpoch;
      final ttl = 24 * 60 * 60 * 1000; // 24 hours

      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          final stat = await entity.stat();
          if (now - stat.modified.millisecondsSinceEpoch > ttl) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      // Best effort cleanup
    }
  }
}

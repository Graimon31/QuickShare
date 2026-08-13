import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:mime/mime.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';

class FileIndexerException implements Exception {
  final String message;
  FileIndexerException(this.message);
  @override
  String toString() => message;
}

class QhtpIndexerResult {
  final QhtpManifest manifest;
  final Map<String, String> itemIdToAbsPathMap;

  const QhtpIndexerResult({
    required this.manifest,
    required this.itemIdToAbsPathMap,
  });
}

class _RawIndexedItem {
  final String relPath;
  final String absPath;
  final int size;
  final int mtime;
  final String mime;

  _RawIndexedItem({
    required this.relPath,
    required this.absPath,
    required this.size,
    required this.mtime,
    required this.mime,
  });
}

class FileIndexer {
  static const Set<String> _defaultSkipFiles = {
    '.ds_store',
    'thumbs.db',
    'desktop.ini',
  };

  static const Set<String> _defaultSkipDirs = {
    '.git',
    'node_modules',
  };

  /// Index files and directories recursively into a QHTP Indexer Result (manifest + abs path map)
  Future<QhtpIndexerResult> buildResult({
    required String sessionId,
    required List<String> paths,
    bool skipHidden = true,
  }) async {
    final List<_RawIndexedItem> rawItems = [];
    int totalBytes = 0;

    for (final rawPath in paths) {
      final entity = FileSystemEntity.typeSync(rawPath);
      if (entity == FileSystemEntityType.file) {
        final file = File(rawPath);
        if (!await file.exists()) continue;

        final name = p.basename(rawPath);
        if (_shouldSkipFile(name, skipHidden)) continue;

        final size = await file.length();
        _checkFileLimits(size, totalBytes, rawItems.length + 1, name);
        totalBytes += size;

        final stat = await file.stat();
        rawItems.add(_RawIndexedItem(
          relPath: name,
          absPath: file.path,
          size: size,
          mtime: stat.modified.millisecondsSinceEpoch,
          mime: lookupMimeType(rawPath) ?? 'application/octet-stream',
        ));
      } else if (entity == FileSystemEntityType.directory) {
        final dir = Directory(rawPath);
        if (!await dir.exists()) continue;

        final rootName = p.basename(rawPath);
        await _walkDirectory(
          dir: dir,
          rootAbsPath: dir.path,
          prefix: rootName,
          depth: 1,
          items: rawItems,
          skipHidden: skipHidden,
          totalBytesRef: (addedSize) {
            totalBytes += addedSize;
          },
          currentTotalBytes: () => totalBytes,
        );
      }
    }

    if (rawItems.isEmpty) {
      throw FileIndexerException('No valid files found in selection');
    }

    // Sort deterministically by relative path ascending
    rawItems.sort((a, b) => a.relPath.compareTo(b.relPath));

    // Assign zero-padded hex IDs and build mapping
    final List<QhtpItem> indexedItems = [];
    final Map<String, String> absPathMap = {};

    for (int i = 0; i < rawItems.length; i++) {
      final id = (i + 1).toRadixString(16).padLeft(6, '0');
      final raw = rawItems[i];
      indexedItems.add(QhtpItem(
        id: id,
        path: raw.relPath,
        size: raw.size,
        mtime: raw.mtime,
        mime: raw.mime,
      ));
      absPathMap[id] = raw.absPath;
    }

    final manifest = QhtpManifest(
      sessionId: sessionId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      itemCount: indexedItems.length,
      totalBytes: totalBytes,
      items: indexedItems,
    );

    return QhtpIndexerResult(
      manifest: manifest,
      itemIdToAbsPathMap: absPathMap,
    );
  }

  Future<QhtpManifest> buildManifest({
    required String sessionId,
    required List<String> paths,
    bool skipHidden = true,
  }) async {
    final result = await buildResult(
      sessionId: sessionId,
      paths: paths,
      skipHidden: skipHidden,
    );
    return result.manifest;
  }

  Future<void> _walkDirectory({
    required Directory dir,
    required String rootAbsPath,
    required String prefix,
    required int depth,
    required List<_RawIndexedItem> items,
    required bool skipHidden,
    required void Function(int size) totalBytesRef,
    required int Function() currentTotalBytes,
  }) async {
    if (depth > AppConstants.qhtpMaxPathDepth) {
      throw FileIndexerException('Directory depth exceeds limit of ${AppConstants.qhtpMaxPathDepth} levels');
    }

    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      final baseName = p.basename(entity.path);
      final baseNameLower = baseName.toLowerCase();

      if (entity is Link) {
        continue;
      }

      if (entity is Directory) {
        if (_defaultSkipDirs.contains(baseNameLower)) continue;
        if (skipHidden && baseName.startsWith('.')) continue;

        final relDir = p.posix.join(prefix, baseName);
        await _walkDirectory(
          dir: entity,
          rootAbsPath: rootAbsPath,
          prefix: relDir,
          depth: depth + 1,
          items: items,
          skipHidden: skipHidden,
          totalBytesRef: totalBytesRef,
          currentTotalBytes: currentTotalBytes,
        );
      } else if (entity is File) {
        if (_shouldSkipFile(baseName, skipHidden)) continue;

        final relPath = p.posix.join(prefix, baseName);
        _validatePathString(relPath);

        final size = await entity.length();
        _checkFileLimits(size, currentTotalBytes(), items.length + 1, relPath);

        totalBytesRef(size);
        final stat = await entity.stat();

        items.add(_RawIndexedItem(
          relPath: relPath,
          absPath: entity.path,
          size: size,
          mtime: stat.modified.millisecondsSinceEpoch,
          mime: lookupMimeType(entity.path) ?? 'application/octet-stream',
        ));
      }
    }
  }

  bool _shouldSkipFile(String name, bool skipHidden) {
    if (skipHidden && name.startsWith('.')) return true;
    final lower = name.toLowerCase();
    return _defaultSkipFiles.contains(lower);
  }

  void _validatePathString(String relPath) {
    if (relPath.length > AppConstants.qhtpMaxRelPathChars) {
      throw FileIndexerException('Relative path length exceeds limit (${AppConstants.qhtpMaxRelPathChars} chars): $relPath');
    }
    final segments = relPath.split('/');
    for (final seg in segments) {
      if (seg == '.' || seg == '..' || seg.isEmpty) {
        throw FileIndexerException('Invalid path segment "$seg" in path $relPath');
      }
    }
  }

  void _checkFileLimits(int fileSize, int currentTotalBytes, int currentCount, String name) {
    if (fileSize > AppConstants.qhtpMaxFileBytes) {
      throw FileIndexerException('File "$name" (${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB) exceeds max limit of 100 GB');
    }
    if (currentTotalBytes + fileSize > AppConstants.qhtpMaxSessionBytes) {
      throw FileIndexerException('Total session size exceeds max limit of 500 GB');
    }
    if (currentCount > AppConstants.qhtpMaxFileCount) {
      throw FileIndexerException('Total file count exceeds max limit of ${AppConstants.qhtpMaxFileCount} files');
    }
  }
}

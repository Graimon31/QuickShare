import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:mime/mime.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/utils/app_logger.dart';
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
  ///
  /// [includeChecksums]: hashing reads every byte of the selection, so the
  /// caller that needs a QR on screen in under two seconds indexes without
  /// hashes and fills them in later via [computeChecksums].
  Future<QhtpIndexerResult> buildResult({
    required String sessionId,
    required List<String> paths,
    bool skipHidden = true,
    bool includeChecksums = true,
    void Function(int items, int bytes)? onProgress,
  }) async {
    final sw = Stopwatch()..start();
    final List<_RawIndexedItem> rawItems = [];
    int totalBytes = 0;

    // Walking a tree is one directory read after another, and a folder on a
    // phone's file provider, on a network share or on a disk that has to spin
    // up answers each of them slowly. Nothing was reported until the whole
    // walk finished, so a selection that took a minute and a selection that
    // was never going to finish looked identical: one motionless "indexing"
    // screen. Saying how far it has got is what separates them.
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    void report({bool force = false}) {
      if (onProgress == null) return;
      final now = DateTime.now();
      if (!force && now.difference(lastReport) < const Duration(milliseconds: 200)) {
        return;
      }
      lastReport = now;
      onProgress(rawItems.length, totalBytes);
    }

    for (final rawPath in paths) {
      // One stat per selected entry, and an asynchronous one.
      //
      // This used to ask the filesystem four times about the same file --
      // `typeSync`, `exists`, `length`, `stat` -- where a single stat carries
      // the type, the size and the modification time together. On a local SSD
      // nobody could tell; on an external disk that has to spin up, or a
      // network volume, it is four round-trips per file with a selection's
      // worth of them in a row. And the first of the four was the synchronous
      // one, on the isolate that draws the "indexing" screen: the spinner
      // stopped animating for exactly as long as the disk took to answer,
      // which is what "it looks frozen" means.
      final stat = await FileStat.stat(rawPath);
      if (stat.type == FileSystemEntityType.file) {
        // No skip check here on purpose. The hidden/junk filter exists to
        // keep `.DS_Store` and friends out of a folder somebody dragged in
        // wholesale; a file named on its own was named deliberately, and
        // dropping it silently left the caller with an empty selection and no
        // idea why.
        final name = p.basename(rawPath);

        final size = stat.size;
        _checkFileLimits(size, totalBytes, rawItems.length + 1, name);
        totalBytes += size;

        rawItems.add(_RawIndexedItem(
          relPath: name,
          absPath: rawPath,
          size: size,
          mtime: stat.modified.millisecondsSinceEpoch,
          mime: lookupMimeType(rawPath) ?? 'application/octet-stream',
        ));
        report();
      } else if (stat.type == FileSystemEntityType.directory) {
        final dir = Directory(rawPath);

        final rootName = p.basename(rawPath);
        // Named before the walk, not after: when a folder is the thing that
        // never answers, this line is the only record of which one it was.
        AppLogger.info('Walking $rawPath', tag: 'INDEX');
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
          onProgress: report,
        );
      }
    }
    report(force: true);

    if (rawItems.isEmpty) {
      throw FileIndexerException('No valid files found in selection');
    }

    // Sort deterministically by relative path ascending
    rawItems.sort((a, b) => a.relPath.compareTo(b.relPath));

    // Assign zero-padded hex IDs and build mapping
    final List<QhtpItem> indexedItems = [];
    final Map<String, String> absPathMap = {};

    // Hashing reads every byte a second time, so it is worth it for ordinary
    // transfers and ruinous for the 500 GB ones this protocol also allows.
    final withChecksums = includeChecksums &&
        totalBytes <= AppConstants.qhtpChecksumMaxSessionBytes;

    for (int i = 0; i < rawItems.length; i++) {
      final id = (i + 1).toRadixString(16).padLeft(6, '0');
      final raw = rawItems[i];
      indexedItems.add(QhtpItem(
        id: id,
        path: raw.relPath,
        size: raw.size,
        mtime: raw.mtime,
        mime: raw.mime,
        sha256: withChecksums ? await _digestOf(File(raw.absPath)) : null,
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

    // The screen says "indexing" for exactly this long, so the journal has to
    // be able to say how long that was and over how much. Without it, a
    // selection sitting on a sleeping external disk and a genuinely stuck
    // session look identical from the outside — and from the log.
    AppLogger.info(
        'Indexed ${indexedItems.length} item(s), $totalBytes bytes, from '
        '${paths.length} selected entr${paths.length == 1 ? 'y' : 'ies'} '
        'in ${sw.elapsedMilliseconds}ms'
        '${withChecksums ? ' (with inline hashes)' : ''}',
        tag: 'INDEX');

    return QhtpIndexerResult(
      manifest: manifest,
      itemIdToAbsPathMap: absPathMap,
    );
  }

  /// `sha256:<hex>` over the file contents, or null if it could not be read.
  ///
  /// A file that vanishes between indexing and hashing is not worth failing
  /// the whole session over — the receiver will get a 410 for it later and
  /// report that item specifically.
  Future<String?> _digestOf(File file) async {
    try {
      final digest = await sha256.bind(file.openRead()).first;
      return 'sha256:$digest';
    } catch (_) {
      return null;
    }
  }

  /// SHA-256 for every item, each in its own isolate, [concurrency] at a
  /// time, in manifest order.
  ///
  /// Returns a future per item rather than one future for the whole map.
  /// Gating the manifest on the full session's digests put the entire hash
  /// run on the receiver's connect path — seconds of "connecting" for any
  /// session under the checksum budget. Per-item futures let the server
  /// answer the manifest immediately and wait only for the one digest the
  /// receiver is about to verify, which finished long ago: hashing outruns
  /// the transfer by an order of magnitude. Running them in parallel
  /// isolates additionally spreads the work across cores instead of one.
  ///
  /// A file that vanishes between indexing and hashing completes with null —
  /// not worth failing the session over; the receiver gets a 410 for it
  /// later and reports that item specifically.
  static Map<String, Future<String?>> computeChecksums(
    Map<String, String> itemIdToAbsPath, {
    int concurrency = 4,
  }) {
    final completers = <String, Completer<String?>>{
      for (final id in itemIdToAbsPath.keys) id: Completer<String?>(),
    };
    final entries = itemIdToAbsPath.entries.toList(growable: false);
    var nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < entries.length) {
        final entry = entries[nextIndex++];
        String? digest;
        try {
          digest = await _hashInIsolate(entry.value);
        } catch (_) {
          digest = null;
        }
        completers[entry.key]!.complete(digest);
      }
    }

    unawaited(Future.wait([
      for (var i = 0; i < concurrency && i < entries.length; i++) worker(),
    ]));
    return {for (final c in completers.entries) c.key: c.value.future};
  }

  /// `sha256:<hex>` over one file, hashed in a worker isolate.
  ///
  /// For the callers that need a single digest and nothing else — the digest
  /// endpoint answering for an item that was served from a Range request and
  /// so never hashed on its way out.
  static Future<String?> hashFile(String path) => _hashInIsolate(path);

  /// Hashes one file in a worker isolate.
  ///
  /// Lives in its own static scope on purpose: the `Isolate.run` closure may
  /// capture only what an isolate message can carry, and a closure created
  /// inside [computeChecksums] shares a context with that function's
  /// Completers — which are unsendable, and the spawn fails.
  static Future<String?> _hashInIsolate(String path) =>
      Isolate.run(() => _digestOfPath(path));

  /// `sha256:<hex>` over the file at [path], or null if it could not be read.
  ///
  /// A file that vanishes between indexing and hashing is not worth failing
  /// the whole session over — the receiver will get a 410 for it later and
  /// report that item specifically.
  static Future<String?> _digestOfPath(String path) async {
    try {
      final digest = await sha256.bind(File(path).openRead()).first;
      return 'sha256:$digest';
    } catch (_) {
      return null;
    }
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
    void Function()? onProgress,
  }) async {
    if (depth > AppConstants.qhtpMaxPathDepth) {
      throw FileIndexerException(
          'Directory depth exceeds limit of ${AppConstants.qhtpMaxPathDepth} levels');
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
          onProgress: onProgress,
        );
      } else if (entity is File) {
        if (_shouldSkipFile(baseName, skipHidden)) continue;

        final relPath = p.posix.join(prefix, baseName);
        _validatePathString(relPath);

        // Size and mtime from the same stat, for the same reason as above:
        // a folder walk asked twice per file, and a tree is where that adds up.
        final stat = await entity.stat();
        final size = stat.size;
        _checkFileLimits(size, currentTotalBytes(), items.length + 1, relPath);

        totalBytesRef(size);

        items.add(_RawIndexedItem(
          relPath: relPath,
          absPath: entity.path,
          size: size,
          mtime: stat.modified.millisecondsSinceEpoch,
          mime: lookupMimeType(entity.path) ?? 'application/octet-stream',
        ));
        onProgress?.call();
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
      throw FileIndexerException(
          'Relative path length exceeds limit (${AppConstants.qhtpMaxRelPathChars} chars): $relPath');
    }
    final segments = relPath.split('/');
    for (final seg in segments) {
      if (seg == '.' || seg == '..' || seg.isEmpty) {
        throw FileIndexerException(
            'Invalid path segment "$seg" in path $relPath');
      }
    }
  }

  void _checkFileLimits(
      int fileSize, int currentTotalBytes, int currentCount, String name) {
    if (fileSize > AppConstants.qhtpMaxFileBytes) {
      throw FileIndexerException(
          'File "$name" (${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB) exceeds max limit of 100 GB');
    }
    if (currentTotalBytes + fileSize > AppConstants.qhtpMaxSessionBytes) {
      throw FileIndexerException(
          'Total session size exceeds max limit of 500 GB');
    }
    if (currentCount > AppConstants.qhtpMaxFileCount) {
      throw FileIndexerException(
          'Total file count exceeds max limit of ${AppConstants.qhtpMaxFileCount} files');
    }
  }
}

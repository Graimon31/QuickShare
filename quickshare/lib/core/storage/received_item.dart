import 'dart:io';

import 'package:path/path.dart' as p;

/// One item sitting in the transfer cache, waiting to be kept or dropped.
///
/// Pure data: where it goes next is [SaveDestination]'s decision, and whether
/// a photo library would take it is [GalleryFormats]'. This used to carry its
/// own "is it media" verdict, which read as a fact about the file but was
/// really a guess about the gallery — and the two are not the same thing on
/// either phone platform.
class ReceivedItem {
  /// Where it currently is — inside the transfer cache, not shared storage.
  final String cachePath;

  final String name;
  final int size;
  final String mimeType;

  /// Where it ended up once saved, if it has been.
  final String? savedPath;

  /// Whether this is a folder rather than a single file.
  ///
  /// A QHTP session can deliver a whole tree, and a folder is never a gallery
  /// item however many photos are inside it: no photo library takes a
  /// directory, and flattening one into its leaves would scatter a structure
  /// the sender deliberately kept.
  final bool isDirectory;

  const ReceivedItem({
    required this.cachePath,
    required this.name,
    required this.size,
    required this.mimeType,
    this.savedPath,
    this.isDirectory = false,
  });

  bool get isSaved => savedPath != null;

  /// Where the item is right now: its permanent home once saved, the cache
  /// until then.
  ///
  /// Saving moves rather than copies wherever the filesystem allows it, so
  /// [cachePath] stops naming anything the moment a save succeeds — anything
  /// that opens, lists or previews the item has to ask this instead.
  ///
  /// A gallery save is the exception: the photo library keeps its own copy
  /// and hands back no path at all, so those still answer with the cache
  /// path, which is where the file stays until the session is discarded.
  String get currentPath =>
      (savedPath == null || savedPath == 'gallery') ? cachePath : savedPath!;

  ReceivedItem copyWith({String? savedPath}) => ReceivedItem(
        cachePath: cachePath,
        name: name,
        size: size,
        mimeType: mimeType,
        savedPath: savedPath ?? this.savedPath,
        isDirectory: isDirectory,
      );

  static ReceivedItem fromCacheFile(File file, String mimeType) => ReceivedItem(
        cachePath: file.path,
        name: p.basename(file.path),
        size: file.existsSync() ? file.lengthSync() : 0,
        mimeType: mimeType,
      );

  /// Either a file or a folder, whichever [entity] turns out to be.
  ///
  /// Used by the transports that hand back a directory listing rather than a
  /// list of files — QHTP delivers whatever the sender picked, which may be a
  /// folder with a thousand things in it.
  static ReceivedItem fromCacheEntity(FileSystemEntity entity, String mimeType) {
    if (entity is Directory) {
      return ReceivedItem(
        cachePath: entity.path,
        name: p.basename(entity.path),
        size: _treeSize(entity),
        mimeType: 'inode/directory',
        isDirectory: true,
      );
    }
    return fromCacheFile(File(entity.path), mimeType);
  }

  static int _treeSize(Directory directory) {
    var total = 0;
    try {
      for (final entity
          in directory.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += entity.lengthSync();
          } on FileSystemException {
            // Vanished between listing and measuring.
          }
        }
      }
    } on FileSystemException {
      // Unreadable; reporting nothing beats refusing to show the item.
    }
    return total;
  }

  @override
  String toString() => 'ReceivedItem($name, $size bytes'
      '${isDirectory ? ', folder' : ''}'
      '${isSaved ? ', saved' : ', unsaved'})';
}

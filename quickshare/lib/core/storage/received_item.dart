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

  const ReceivedItem({
    required this.cachePath,
    required this.name,
    required this.size,
    required this.mimeType,
    this.savedPath,
  });

  bool get isSaved => savedPath != null;

  ReceivedItem copyWith({String? savedPath}) => ReceivedItem(
        cachePath: cachePath,
        name: name,
        size: size,
        mimeType: mimeType,
        savedPath: savedPath ?? this.savedPath,
      );

  static ReceivedItem fromCacheFile(File file, String mimeType) => ReceivedItem(
        cachePath: file.path,
        name: p.basename(file.path),
        size: file.existsSync() ? file.lengthSync() : 0,
        mimeType: mimeType,
      );

  @override
  String toString() => 'ReceivedItem($name, $size bytes'
      '${isSaved ? ', saved' : ', unsaved'})';
}

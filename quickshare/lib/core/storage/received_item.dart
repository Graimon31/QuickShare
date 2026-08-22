import 'dart:io';

import 'package:path/path.dart' as p;

/// What kind of thing arrived, which decides where it can go next.
enum ReceivedKind {
  /// A photo or a video: on a phone it belongs in the gallery, where the
  /// user's other photos are.
  media,

  /// Anything else: a document, an archive, a binary.
  file,
}

/// One item sitting in the transfer cache, waiting to be kept or dropped.
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

  ReceivedKind get kind =>
      isMediaMimeType(mimeType) || _looksLikeMediaExtension(name)
          ? ReceivedKind.media
          : ReceivedKind.file;

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

  /// Whether a MIME type names something that belongs in a photo library.
  ///
  /// Deliberately narrower than `image/*` — an SVG or a PDF preview is an
  /// image by MIME type but not something any gallery will accept, and a
  /// failed gallery write is worse than an honest "save as file".
  static bool isMediaMimeType(String mimeType) {
    final type = mimeType.toLowerCase();
    if (type.startsWith('video/')) return true;
    if (!type.startsWith('image/')) return false;
    return const {
      'image/jpeg',
      'image/jpg',
      'image/png',
      'image/gif',
      'image/heic',
      'image/heif',
      'image/webp',
      'image/tiff',
      'image/bmp',
      'image/x-adobe-dng',
    }.contains(type);
  }

  /// Fallback for a sender that sent no usable MIME type.
  static bool _looksLikeMediaExtension(String name) {
    const extensions = {
      '.jpg', '.jpeg', '.png', '.gif', '.heic', '.heif', '.webp',
      '.tiff', '.tif', '.bmp', '.dng',
      '.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm', '.3gp', //
    };
    return extensions.contains(p.extension(name).toLowerCase());
  }

  @override
  String toString() => 'ReceivedItem($name, $size bytes, $kind'
      '${isSaved ? ', saved' : ', unsaved'})';
}

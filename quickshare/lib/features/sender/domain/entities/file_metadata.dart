import 'package:equatable/equatable.dart';
import 'package:quickshare/core/utils/byte_format.dart';

class FileMetadata extends Equatable {
  final String name;
  final String path;
  final int size;
  final String mimeType;

  /// Where this file has to land relative to the destination, when it came
  /// out of a folder the sender picked.
  ///
  /// `Trip/Day 1/IMG_0042.HEIC` — POSIX-separated, root folder included, never
  /// absolute. Null for a file picked directly, which is the same thing as
  /// [name]; [relPath] papers over the difference so callers need not.
  final String? relativePath;

  const FileMetadata({
    required this.name,
    required this.path,
    required this.size,
    required this.mimeType,
    this.relativePath,
  });

  /// The path to rebuild on the far side — [name] for anything picked
  /// directly.
  String get relPath => relativePath ?? name;

  String get sizeFormatted => ByteFormat.size(size);

  @override
  List<Object?> get props => [name, path, size, mimeType, relativePath];
}

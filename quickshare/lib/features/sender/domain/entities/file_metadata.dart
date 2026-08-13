import 'package:equatable/equatable.dart';

class FileMetadata extends Equatable {
  final String name;
  final String path;
  final int size;
  final String mimeType;

  const FileMetadata({
    required this.name,
    required this.path,
    required this.size,
    required this.mimeType,
  });

  String get sizeFormatted {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  List<Object?> get props => [name, path, size, mimeType];
}

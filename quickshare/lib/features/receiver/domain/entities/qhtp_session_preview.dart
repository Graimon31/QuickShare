import 'package:equatable/equatable.dart';

class QhtpSessionPreview extends Equatable {
  final int itemCount;
  final int totalBytes;

  const QhtpSessionPreview({
    required this.itemCount,
    required this.totalBytes,
  });

  @override
  List<Object?> get props => [itemCount, totalBytes];
}

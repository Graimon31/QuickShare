import 'package:equatable/equatable.dart';

class QhtpSessionPreview extends Equatable {
  final int itemCount;
  final int totalBytes;
  final String? senderName;

  const QhtpSessionPreview({
    required this.itemCount,
    required this.totalBytes,
    this.senderName,
  });

  @override
  List<Object?> get props => [itemCount, totalBytes, senderName];
}

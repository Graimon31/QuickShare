import 'package:equatable/equatable.dart';

/// The local item a completed QHTP session should present to the receiver.
class QhtpReceiveResult extends Equatable {
  final String preferredResultPath;
  final String displayName;

  /// The top-level entries this session actually created, as absolute paths.
  ///
  /// Only meaningful when the session wrote straight into a folder that was
  /// already the user's — Downloads, or one they picked — where listing the
  /// directory afterwards would report everything else in it too. Reading
  /// them off the transfer's own bookkeeping is the only way to say which of
  /// those hundred files arrived just now.
  ///
  /// Empty for a session staged in the transfer cache: there the whole
  /// directory belongs to this transfer and listing it is exact.
  final List<String> placedPaths;

  const QhtpReceiveResult({
    required this.preferredResultPath,
    required this.displayName,
    this.placedPaths = const [],
  });

  @override
  List<Object> get props => [preferredResultPath, displayName, placedPaths];
}

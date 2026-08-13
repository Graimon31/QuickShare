import 'package:equatable/equatable.dart';

/// The local item a completed QHTP session should present to the receiver.
class QhtpReceiveResult extends Equatable {
  final String preferredResultPath;
  final String displayName;

  const QhtpReceiveResult({
    required this.preferredResultPath,
    required this.displayName,
  });

  @override
  List<Object> get props => [preferredResultPath, displayName];
}

/// Something went wrong on the radio after the receiver had connected.
///
/// The rendezvous has no result of its own to return it through — the
/// receiver connects, says what it is, and then listens while a Wi-Fi link is
/// built — so a problem on the way is reported here, as it happens.
class BleReceiverFailure {
  /// English and technical, for the log and the fallback text.
  final String message;

  /// A `FailureCode`, so the screen can say it in the person's language.
  final String code;

  const BleReceiverFailure(this.message, this.code);

  @override
  String toString() => message;
}

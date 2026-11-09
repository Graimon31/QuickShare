import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:quickshare/core/webrtc/resume/resume_keys.dart';
import 'package:quickshare/core/webrtc/resume/resume_signaling.dart';
import 'package:quickshare/core/signaling/code_mailbox.dart';

/// The receiver's end of one link: where frames come from, and the way back to
/// the sender. Like [SenderLink] on the other side, everything about the
/// network lives behind it.
abstract class ReceiverLink {
  /// Which link this is. The one the QR code started is 1.
  int get generation;

  bool get isOpen;

  /// Says something to the sender. Best effort: a link that cannot take it is
  /// a link that is going.
  void sendText(String frame);

  /// Starts delivering. [onFrame] gets every message the sender puts on the
  /// channel; [onClosed] is called once, when the link is known to be dead,
  /// with a reason fit for the log.
  void bind({
    required void Function(RTCDataChannelMessage message) onFrame,
    required void Function(String reason) onClosed,
  });

  /// Closes the link without a word to the far end.
  Future<void> close();
}

/// A replacement link on its way: the answer to put on the mailbox now, and
/// the link itself once the sender has applied that answer and the channel is
/// open. [abandon] puts the attempt down when it is given up.
class ReceiverLinkAttempt {
  ReceiverLinkAttempt({
    required this.answerSdp,
    required this.ready,
    required this.abandon,
  });

  final Uint8List answerSdp;
  final Future<ReceiverLink> ready;
  final Future<void> Function() abandon;
}

/// Answers an offer for a replacement link. The production one builds a new
/// peer connection; a test hands in one that makes a link of its own.
typedef ReceiverLinkOpener = Future<ReceiverLinkAttempt> Function(
    ResumeOffer offer);

/// What a transport needs to take part in a reconnection: the keys both ends
/// derived from the transfer's seed, and where to meet.
class ResumeSetup {
  const ResumeSetup({
    required this.keys,
    this.mailboxFactory,
  });

  final ResumeKeys keys;

  /// Null: the build's own mailbox, Nostr and the Worker together. A test
  /// hands in one that stays in the process.
  final CodeMailbox Function()? mailboxFactory;
}

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/nostr_answer_channel.dart';
import 'package:quickshare/core/signaling/worker_answer_channel.dart';

/// Raised when the build's rendezvous configuration leaves no way at all to
/// exchange an answer.
///
/// Its own type rather than a StateError because it is a build-configuration
/// mistake, not a runtime failure: no retry, no fallback, nothing to do but
/// fix the `--dart-define`s.
class NoRendezvousChannelConfigured implements Exception {
  final String requested;
  const NoRendezvousChannelConfigured(this.requested);

  @override
  String toString() => 'no rendezvous channel is enabled '
      '(QUICKSHARE_RENDEZVOUS_CHANNELS="$requested"); the worker channel also '
      'needs QUICKSHARE_WORKER_URL to be set';
}

/// Builds the answer channel both peers use, honouring the build's
/// [AppConstants.rendezvousChannels] selection.
///
/// Sender and receiver have to agree on this list — they meet on a topic, not
/// on a channel — so it lives here rather than being spelled out at each call
/// site, where the two copies had already started to differ in what they
/// checked before adding the Worker.
///
/// [acceptPayload] is the listening side's way of saying what an answer looks
/// like — the sender can try to open it, the channel cannot — so the Worker's
/// mailbox, where anyone can leave anything, never reports a payload that is
/// not the answer as the answer.
AnswerChannel buildRendezvousChannel({PayloadAcceptor? acceptPayload}) {
  final channels = <AnswerChannel>[
    if (AppConstants.nostrRendezvousEnabled) NostrAnswerChannel(),
    if (AppConstants.workerRendezvousEnabled)
      WorkerAnswerChannel(
        baseUrl: AppConstants.workerBaseUrl,
        acceptPayload: acceptPayload,
      ),
  ];

  if (channels.isEmpty) {
    throw const NoRendezvousChannelConfigured(AppConstants.rendezvousChannels);
  }
  return RacingAnswerChannel(channels);
}

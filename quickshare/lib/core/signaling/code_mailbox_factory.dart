import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/signaling/code_mailbox.dart';
import 'package:quickshare/core/signaling/nostr_code_mailbox.dart';
import 'package:quickshare/core/signaling/rendezvous_channels.dart';
import 'package:quickshare/core/signaling/worker_code_mailbox.dart';

/// Builds the mailbox both ends of an internet code meet in, honouring the
/// build's [AppConstants.rendezvousChannels] selection — the same list the
/// sealed answer uses, so one `--dart-define` isolates one channel for both.
///
/// Throws [NoRendezvousChannelConfigured] when the build leaves no channel.
CodeMailbox buildCodeMailbox() {
  final channels = <CodeMailbox>[
    if (AppConstants.nostrRendezvousEnabled) NostrCodeMailbox(),
    if (AppConstants.workerRendezvousEnabled)
      WorkerCodeMailbox(baseUrl: AppConstants.workerBaseUrl),
  ];
  if (channels.isEmpty) {
    throw const NoRendezvousChannelConfigured(AppConstants.rendezvousChannels);
  }
  return RacingCodeMailbox(channels);
}

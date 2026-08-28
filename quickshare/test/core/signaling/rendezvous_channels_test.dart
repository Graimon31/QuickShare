// The channel selection is driven by compile-time `--dart-define`s, so a test
// process can only observe the defaults it was built with. What is worth
// pinning down is the parsing and the misconfiguration guard.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/rendezvous_channels.dart';

void main() {
  group('rendezvous channel selection', () {
    test('defaults to Nostr enabled, so an unconfigured build still works', () {
      expect(AppConstants.nostrRendezvousEnabled, isTrue);
    });

    test('the worker channel needs a URL, and the default build has one', () {
      // 'worker' is in the default channel list and the production Worker
      // URL is baked into AppConstants, so a default build really can reach
      // it. A build that deliberately blanks QUICKSHARE_WORKER_URL still
      // falls back to Nostr alone.
      expect(AppConstants.rendezvousChannels, contains('worker'));
      expect(AppConstants.workerBaseUrl, isNotEmpty);
      expect(AppConstants.workerRendezvousEnabled, isTrue);
    });

    test('builds a usable channel under the default configuration', () {
      final channel = buildRendezvousChannel();
      addTearDown(channel.close);
      expect(channel, isA<RacingAnswerChannel>());
      // Both halves are live: Nostr relays and the Worker mailbox race,
      // whichever delivers the sealed answer first wins.
      expect(channel.name, contains('nostr'));
      expect(channel.name, contains('worker'));
    });

    test('a misconfiguration message names both defines to check', () {
      const error = NoRendezvousChannelConfigured('worker');
      expect(error.toString(), contains('QUICKSHARE_RENDEZVOUS_CHANNELS'));
      expect(error.toString(), contains('QUICKSHARE_WORKER_URL'));
    });
  });
}

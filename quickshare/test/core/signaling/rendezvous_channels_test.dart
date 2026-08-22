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

    test('the worker channel stays off until a Worker URL is configured', () {
      // 'worker' is in the default channel list, but without
      // QUICKSHARE_WORKER_URL there is nothing to talk to. Naming a channel
      // must not be enough to enable it.
      expect(AppConstants.rendezvousChannels, contains('worker'));
      expect(AppConstants.workerBaseUrl, isEmpty);
      expect(AppConstants.workerRendezvousEnabled, isFalse);
    });

    test('builds a usable channel under the default configuration', () {
      final channel = buildRendezvousChannel();
      addTearDown(channel.close);
      expect(channel, isA<RacingAnswerChannel>());
      // Nostr only: the Worker half is inert without a URL.
      expect(channel.name, contains('nostr'));
      expect(channel.name, isNot(contains('worker')));
    });

    test('a misconfiguration message names both defines to check', () {
      const error = NoRendezvousChannelConfigured('worker');
      expect(error.toString(), contains('QUICKSHARE_RENDEZVOUS_CHANNELS'));
      expect(error.toString(), contains('QUICKSHARE_WORKER_URL'));
    });
  });
}

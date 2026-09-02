import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_info_plus_platform_interface/method_channel_network_info.dart';
import 'package:network_info_plus_platform_interface/network_info_plus_platform_interface.dart';
import 'package:quickshare/core/network/network_info_service.dart';

/// A platform side that takes the call and never answers — the shape of the
/// failure this guards against, where the sender sat on "indexing" forever
/// with no work happening anywhere in the process.
class _SilentNetworkInfo extends NetworkInfoPlatform {
  @override
  Future<String?> getWifiIP() => Completer<String?>().future;
}

void main() {
  test('a Wi-Fi address lookup that never answers does not hang the session',
      () async {
    NetworkInfoPlatform.instance = _SilentNetworkInfo();
    addTearDown(() => NetworkInfoPlatform.instance = MethodChannelNetworkInfo());

    final sw = Stopwatch()..start();
    final ip = await NetworkInfoService()
        .getLocalIpAddress()
        .timeout(const Duration(seconds: 10));

    // The interface list is the fallback and it is local, so the whole call
    // costs the plugin's budget and little else. What matters is that it
    // *returns*: waiting on the plugin used to be unbounded.
    expect(sw.elapsed, lessThan(const Duration(seconds: 8)));

    // On a machine with a network the fallback finds one of its own
    // addresses; on one without, a null answer is the correct one. Either
    // way the answer arrives.
    if (ip != null) {
      expect(InternetAddress.tryParse(ip), isNotNull);
    }
  });
}

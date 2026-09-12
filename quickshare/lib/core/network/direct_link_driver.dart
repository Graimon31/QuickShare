import 'dart:async';
import 'dart:io';

import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/network/session_code.dart';

/// The coordinator's platform half, built on the services the app already
/// has: [LocalHotspotService] for raising and joining the network, and the
/// peer-link bridge's Wi-Fi switches on the platforms that expose one.
class LocalHotspotDriver implements DirectLinkDriver {
  final LocalHotspotService _hotspot;
  final PeerLinkService _peerLink;

  LocalHotspotDriver({LocalHotspotService? hotspot, PeerLinkService? peerLink})
      : _hotspot = hotspot ?? LocalHotspotService(),
        _peerLink = peerLink ?? const PeerLinkService();

  @override
  bool get canHost => _hotspot.canHost;

  @override
  Future<HotspotCredentials> host(SessionCode code) async {
    final credentials = await _hotspot.startHosting(code: code);
    // The coordinator's contract: no address, no network — whatever the
    // platform callback claimed. The interface takes a moment to pick its
    // address up, which is what startHosting already waits out.
    if (credentials.hostAddress == null) {
      await _hotspot.stopHosting();
      throw const HotspotException(
          'the network came up but never got an address');
    }
    return credentials;
  }

  @override
  Future<void> joinNetwork(HotspotCredentials credentials) async {
    await _hotspot.join(credentials);
    if (!Platform.isWindows) return;
    // WlanConnect returns when the connection *starts*, not when it lands.
    // Confirm the association — the coordinator's retry is the fix when it
    // did not.
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      if (await _hotspot.currentSsid() == credentials.ssid) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    throw HotspotException('never associated with ${credentials.ssid}');
  }

  @override
  Future<bool> ensureWifiReady() async {
    if (!PeerLinkService.isSupported) {
      // Android and the desktops expose no switch an app can flip: hosting
      // and joining fail with the reason said out loud, and the coordinator's
      // ladder climbs from there.
      return true;
    }
    if (await _peerLink.wifiReady) return true;
    await _peerLink.enableWifi();
    if (await _peerLink.wifiReady) return true;
    // iOS lets no app flip the switch — the settings page is the switch, and
    // the person standing in front of it is the fix.
    await _peerLink.openWifiSettings();
    return _peerLink.wifiReady;
  }

  @override
  Future<void> stopHosting() => _hotspot.stopHosting();

  @override
  Future<void> leaveNetwork() => _hotspot.leaveNetwork();

  @override
  bool get canPeerLink => _peerLink.supported;

  @override
  Future<void> hostPeerLink(String serviceName, int localPort) =>
      _peerLink.host(serviceName: serviceName, localPort: localPort);

  @override
  Future<int> joinPeerLink(String serviceName) =>
      // Bounded well inside the receiver's negotiation budget: the link is
      // either there within a few seconds or the sender never raised one.
      _peerLink.join(
          serviceName: serviceName, timeout: const Duration(seconds: 10));

  @override
  Future<void> stopPeerLink() async {
    try {
      await _peerLink.stop();
    } catch (_) {
      // Never throws, by contract: this runs on the way out of a rung that
      // already failed, and a second failure there tells nobody anything.
    }
  }
}

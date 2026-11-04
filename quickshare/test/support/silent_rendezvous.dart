import 'package:quickshare/core/network/lan_discovery.dart';

/// An advertiser that says nothing to anyone.
///
/// Widget tests of the offer screens build a real `SenderBloc`, whose default
/// advertiser asks the platform's mDNS responder to register a service. There
/// is no responder in a headless test, and a platform call that never returns
/// leaves the timer that bounds it pending when the widget tree is disposed.
/// What those tests are about is the screen, not the announcement, so they
/// hand the bloc this instead. What the real one puts on the air is pinned in
/// `test/core/network/lan_discovery_test.dart`.
class SilentRendezvousAdvertiser implements RendezvousAdvertiser {
  @override
  Future<void> advertise({required int port, required String hint}) async {}

  @override
  Future<void> stop() async {}
}

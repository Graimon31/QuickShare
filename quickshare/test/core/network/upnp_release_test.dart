import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/network/upnp_port_forwarder.dart';

void main() {
  group('UpnpPortForwarder mapping bookkeeping', () {
    test('a fresh forwarder has nothing to release', () {
      expect(UpnpPortForwarder().hasActiveMappings, isFalse);
    });

    test('releaseAll on a fresh forwarder is a no-op, not an error', () async {
      // Called unconditionally from stopSharing(), including on the serverless
      // path that never asks the router for anything.
      expect(await UpnpPortForwarder().releaseAll(), isZero);
    });

    test('releasing twice does not double-report', () async {
      final forwarder = UpnpPortForwarder();
      expect(await forwarder.releaseAll(), isZero);
      expect(await forwarder.releaseAll(), isZero);
      expect(forwarder.hasActiveMappings, isFalse);
    });
  });
}

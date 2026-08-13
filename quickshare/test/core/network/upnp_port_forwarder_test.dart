import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/network/upnp_port_forwarder.dart';

void main() {
  group('UpnpPortForwarder', () {
    test('PortMappingResult formatting and properties work correctly', () {
      const result = PortMappingResult(
        success: true,
        method: 'upnp',
        publicIp: '203.0.113.195',
        externalPort: 3000,
      );

      expect(result.success, isTrue);
      expect(result.method, equals('upnp'));
      expect(result.publicIp, equals('203.0.113.195'));
      expect(result.externalPort, equals(3000));
      expect(result.toString(), contains('203.0.113.195'));
    });

    test('forwardPort returns graceful failure when no UPnP router responds in test environment', () async {
      final forwarder = UpnpPortForwarder();
      final result = await forwarder.forwardPort(
        internalPort: 9999,
        timeout: const Duration(milliseconds: 100),
      );

      expect(result.success, isFalse);
      expect(result.error, isNotNull);
    });
  });
}

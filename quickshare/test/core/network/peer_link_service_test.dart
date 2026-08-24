import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/peer_link_service.dart';

void main() {
  group('serviceNameFor', () {
    test('both ends derive the same name from the token they share', () {
      // Nothing about the link goes in the QR code — this is why. The sender
      // advertises under a name the receiver can work out for itself from the
      // session token it already scanned.
      const token = 'a1b2c3d4-e5f6-7890-abcd-ef0123456789';
      expect(
        PeerLinkService.serviceNameFor(token),
        equals(PeerLinkService.serviceNameFor(token)),
      );
    });

    test('different sessions do not collide', () {
      expect(
        PeerLinkService.serviceNameFor('11111111-2222-3333-4444-555555555555'),
        isNot(equals(
            PeerLinkService.serviceNameFor('99999999-8888-7777-6666-555555555555'))),
      );
    });

    test('the name is legal for Bonjour', () {
      // An instance name is capped at 63 bytes, and the dashes in a UUID are
      // not worth carrying into it.
      final name =
          PeerLinkService.serviceNameFor('a1b2c3d4-e5f6-7890-abcd-ef0123456789');
      expect(name, equals('dd-a1b2c3d4e5f67890'));
      expect(name.length, lessThan(63));
      expect(RegExp(r'^[A-Za-z0-9-]+$').hasMatch(name), isTrue);
    });

    test('a short or odd token still produces something usable', () {
      expect(PeerLinkService.serviceNameFor('abc'), equals('dd-abc'));
      expect(PeerLinkService.serviceNameFor('...'), equals('dd-'));
    });
  });
}

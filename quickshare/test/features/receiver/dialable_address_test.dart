// Which addresses the receiver is willing to collect from.
//
// This rule had no test at all, and it silently broke every transfer over a
// USB cable: macOS and iOS both self-assign a 169.254 address on the link the
// cable makes, the sender's invitation therefore arrived from one, and the
// check refused it as "not private enough" — which is backwards, since a
// link-local address is one that cannot leave the wire it came in on. Accepted
// invitations died with "Invalid IP" and no screen ever appeared.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/features/receiver/data/client/http_file_downloader.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/repositories/receiver_repository_impl.dart';

void main() {
  late ReceiverRepositoryImpl repository;

  setUp(() {
    repository = ReceiverRepositoryImpl(
      downloader: HttpFileDownloader(),
      decoder: QRPayloadDecoder(),
      inProcess: true,
    );
  });

  group('addresses worth dialling', () {
    test('a link-local IPv4 address, which is what a USB cable gives us', () {
      // The regression this file exists for. 169.254.251.142 is the address
      // macOS gave itself on the interface the iPhone's cable created, and it
      // is the address every accepted invitation arrived from.
      expect(repository.validatePrivateIp('169.254.251.142'), isTrue);
    });

    test('a link-local IPv6 address, for the same reason', () {
      expect(repository.validatePrivateIp('fe80::1458:c0ad:3de4:a3f3'), isTrue);
    });

    test('the ordinary private ranges a router hands out', () {
      for (final ip in ['192.168.3.5', '10.0.0.4', '172.16.9.1']) {
        expect(repository.validatePrivateIp(ip), isTrue, reason: ip);
      }
    });

    test('loopback, which is where a local test server lives', () {
      expect(repository.validatePrivateIp('127.0.0.1'), isTrue);
      expect(repository.validatePrivateIp('localhost'), isTrue);
      expect(repository.validatePrivateIp('::1'), isTrue);
    });

    test('a public address, because the internet mode relays through one', () {
      // Refusing these would break the relay path, which is the one case where
      // a public address is exactly what the sender meant to hand over.
      expect(repository.validatePrivateIp('93.184.216.34'), isTrue);
    });
  });

  group('addresses that name no single machine', () {
    test('a multicast group is not a peer', () {
      expect(repository.validatePrivateIp('224.0.0.171'), isFalse);
      expect(repository.validatePrivateIp('ff02::fb'), isFalse);
    });

    test('anything that is not an address at all', () {
      for (final junk in ['', 'not-an-ip', '999.1.1.1', 'example.com']) {
        expect(repository.validatePrivateIp(junk), isFalse, reason: '"$junk"');
      }
    });
  });
}

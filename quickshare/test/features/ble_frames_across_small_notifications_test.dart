// A negotiation frame is longer than a notification, and still arrives whole.
//
// The `link` frame that carries sealed credentials is 203 bytes. The `serve`
// frame with every field is 225. A notification holds the ATT MTU less three:
// 182 on an iPhone (it takes 185 and no other number), 244 on an Android phone
// that asked for 247, 20 on a connection nobody negotiated. So the frame that
// tells an iPhone where to join is longer than the iPhone can be sent in one
// piece, and the platforms do not refuse the one that is too long — they cut it
// to the limit and say nothing.
//
// These run the real sender and the real receiver on a simulated link that does
// exactly that, and send the real frames through it.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:quickshare/core/crypto/link_secret.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/transfer/ble_gatt.dart';
import 'package:quickshare/core/transfer/ble_session.dart';
import 'package:quickshare/features/receiver/data/transports/ble_receiver_failure.dart';
import 'package:quickshare/features/receiver/data/transports/universal_ble_receiver_transport.dart';
import 'package:quickshare/features/sender/data/transports/bluetooth_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

import '../support/linked_ble.dart';

/// What an Android receiver or an iPhone receiver negotiates, and what a
/// connection that was never asked is left with.
const _links = {
  'a connection nobody negotiated (20)': 20,
  'an iPhone (182)': 182,
  'an Android phone that asked for 247 (244)': 244,
  'a large one (512)': 512,
};

const _file =
    FileMetadata(name: 'a', path: '/tmp/a', size: 1, mimeType: 'text/plain');

void main() {
  late LinkedBlePeripheral radio;
  late LinkedBleCentral central;
  late BluetoothTransferTransport sender;
  late UniversalBleReceiverTransport receiver;
  late List<DirectLinkDirective> directives;
  late List<LinkServeInfo> serves;
  late List<BleReceiverFailure> failures;

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await sender.stopSharing();
    await receiver.dispose();
    UniversalBlePeripheral.setInstance(UniversalBlePeripheralUnsupported());
  });

  /// A sender on [platform], advertising, and a receiver connected to it over a
  /// link that carries [limit] bytes a notification.
  Future<void> connect(TargetPlatform platform, int limit,
      {bool reportsLimit = true}) async {
    debugDefaultTargetPlatformOverride = platform;
    central = LinkedBleCentral();
    radio = LinkedBlePeripheral(central,
        radioLimit: limit, reportsLimit: reportsLimit);
    central.server = radio;
    UniversalBlePeripheral.setInstance(radio);
    UniversalBle.setInstance(central);

    final session = BleSession.generate();
    sender = BluetoothTransferTransport();
    await sender.initialize();
    await sender.startSharing(_file, session.token, locator: session.locator);

    receiver = UniversalBleReceiverTransport();
    directives = [];
    serves = [];
    failures = [];
    receiver.linkDirectives.listen(directives.add);
    receiver.serveInfos.listen(serves.add);
    receiver.failures.listen(failures.add);
    await receiver.connect('peer', token: session.token);
    // The phone is subscribed to data and has asked to start: the sender knows
    // who it is talking to.
    radio.subscribe('peer', BleGatt.data);
    await Future<void>.delayed(Duration.zero);
  }

  /// The frame that tells a receiver which network to join: the sealed pair
  /// and the sender's key.
  Future<DirectLinkDirective> hostingDirective() async {
    final host = await LinkSecret.generate();
    final guest = await LinkSecret.generate();
    return DirectLinkDirective.hostBySender(
      sealedCredentials: await host.seal(
          ssid: 'DirectDrop-K3M9Q2TV',
          passphrase: 'X7K29DMQ41ZTRW5N',
          sessionId: 'K3M9Q2TV',
          peerPublicKey: guest.publicKey),
      senderPublicKey: host.publicKey,
    );
  }

  const everyField = LinkServeInfo(
    ip: '192.168.137.1',
    port: 54321,
    token: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
    tlsFingerprint: 'ppyVDnOklxV6jThfz6nwYkm7r_rGePi0X5ULmV_k2qY',
    fileName: 'Vacation photos',
    fileSize: 123456789,
    itemCount: 12,
    senderName: "Farman's PC",
    lanIp: '192.168.1.10',
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final link in _links.entries) {
      group('${platform.name} sending over ${link.key}', () {
        test('the hosting directive arrives whole', () async {
          await connect(platform, link.value);
          final sent = await hostingDirective();

          await sender.sendLinkFrame({'link': sent.toJson()});
          await Future<void>.delayed(Duration.zero);

          expect(failures, isEmpty);
          expect(directives, hasLength(1));
          expect(directives.single.sealedCredentials, sent.sealedCredentials);
          expect(directives.single.senderPublicKey, sent.senderPublicKey);
          expect(directives.single.receiverHosts, isFalse);
        });

        test('the serve frame arrives whole, with every field', () async {
          await connect(platform, link.value);

          await sender.sendLinkFrame({'serve': everyField.toJson()});
          await Future<void>.delayed(Duration.zero);

          expect(failures, isEmpty);
          expect(serves, hasLength(1));
          expect(jsonEncode(serves.single.toJson()),
              jsonEncode(everyField.toJson()),
              reason: 'nothing optional was dropped to make it fit');
        });

        test('one after the other, in order, none mixed with another',
            () async {
          await connect(platform, link.value);
          final sent = await hostingDirective();

          await sender.sendLinkFrame({'link': sent.toJson()});
          await sender.sendLinkFrame({'serve': everyField.toJson()});
          await sender.sendLinkFrame({
            'link': const DirectLinkDirective.hostByReceiver(
                    senderPublicKey: 'a-key')
                .toJson()
          });
          await Future<void>.delayed(Duration.zero);

          expect(failures, isEmpty);
          expect(directives.map((d) => d.receiverHosts), [false, true]);
          expect(serves, hasLength(1));
          expect(serves.single.fileName, 'Vacation photos');
        });
      });
    }
  }

  group('when the platform cannot say what the connection carries', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      test('${platform.name} sends in parts that fit the smallest connection '
          'there is', () async {
        // The link really carries 20. The sender is told nothing, so it has to
        // assume the least a connection ever carries and not the most.
        await connect(platform, 20, reportsLimit: false);
        final sent = await hostingDirective();

        await sender.sendLinkFrame({'link': sent.toJson()});
        await sender.sendLinkFrame({'serve': everyField.toJson()});
        await Future<void>.delayed(Duration.zero);

        expect(failures, isEmpty);
        expect(directives.single.sealedCredentials, sent.sealedCredentials);
        expect(serves.single.fileName, 'Vacation photos');
      });
    }
  });
}

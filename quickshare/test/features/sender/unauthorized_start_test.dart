// A START with no token is refused to the peer, not only to ourselves.
//
// DD-20. The session was torn down and the person sending was told why — and
// the GATT write that caused it was answered with success. A receiver too old
// to pair securely therefore believed its transfer had begun, and sat waiting
// on bytes that were never coming, while this side had already given up.
//
// Apple's bridges have always answered `insufficientAuthentication` here.
// Android and Linux did not, and this pins all three to the same answer.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/transfer/ble_control_protocol.dart';

void main() {
  const token = 'the-session-token';

  group('what counts as an unauthorized start', () {
    test('a bare START is one', () {
      expect(BleControlProtocol.isUnauthorizedStart('START', token), isTrue);
    });

    test('so is one carrying the wrong token', () {
      expect(
        BleControlProtocol.isUnauthorizedStart('START:not-the-token', token),
        isTrue,
      );
    });

    test('the right one is not', () {
      expect(
        BleControlProtocol.isUnauthorizedStart(
            BleControlProtocol.start(token), token),
        isFalse,
      );
      expect(
        BleControlProtocol.isStart(BleControlProtocol.start(token), token),
        isTrue,
      );
    });

    test('and neither are the other commands on the characteristic', () {
      // They share one write path, and mistaking any of them for a refused
      // start would answer an ATT error to a perfectly ordinary frame.
      for (final command in [
        BleControlProtocol.capabilities(),
        BleControlProtocol.hello('iPhone'),
        BleControlProtocol.keyExchange('a-public-key'),
        BleControlProtocol.apOffer('c2VhbGVkLWJsb2I'),
      ]) {
        expect(BleControlProtocol.isUnauthorizedStart(command, token), isFalse,
            reason: command);
      }
    });
  });

  group('the answer the peer gets', () {
    test('is insufficient authentication, which is what happened', () {
      // 0x05. The write was understood and rejected for want of a
      // credential — not malformed, not unsupported. Every bridge answers
      // this same value, so the constant lives in one place and the Swift
      // sides mirror it.
      expect(BleControlProtocol.attInsufficientAuthentication, equals(0x05));
    });

    test('and the sender is told something it can act on', () {
      // "Bluetooth transfer failed" sends somebody hunting a radio problem
      // that is not there.
      expect(BleControlProtocol.staleReceiverMessage, isNotEmpty);
      expect(BleControlProtocol.staleReceiverMessage.toLowerCase(),
          contains('update'));
    });
  });
}

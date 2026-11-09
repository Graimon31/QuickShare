import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/transfer/ble_code_pairing.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

const code = SessionCode('1234567890');
const wrong = SessionCode('1234567891');
const token = 'secret-session-token-abcdef';
final payload =
    const BluetoothQrPayload(token: token, locator: 'random123').encode();

Future<({String id, String command, Spake2Keys keys})> exchange(
    BleCodePairingSender sender,
    {SessionCode guess = code,
    String peer = 'peer-a'}) async {
  final id = BleCodePairing.newId();
  final a = await BleCodePairing.begin(guess);
  final first =
      BleCodePairing.command({'id': id, 'pA': CodePake.encode(a.share)});
  final answer = await sender.handle(peer, first);
  expect(answer, isNotNull);
  expect(jsonEncode(answer), isNot(contains(token)));
  expect(jsonEncode(answer), isNot(contains(payload)));
  final keys = await BleCodePairing.complete(
      a, CodePake.decode(answer!['pB'], length: Spake2.shareLength)!, id);
  if (guess == code) {
    expect(
        keys.verifies(Spake2Role.b,
            CodePake.decode(answer['cB'], length: CodePake.tagLength)!),
        isTrue);
  } else {
    expect(
        keys.verifies(Spake2Role.b,
            CodePake.decode(answer['cB'], length: CodePake.tagLength)!),
        isFalse);
  }
  return (
    id: id,
    command: BleCodePairing.command(
        {'id': id, 'cA': CodePake.encode(keys.confirmationA)}),
    keys: keys
  );
}

void main() {
  test('real proof releases only sealed QR, once, to the same peer', () async {
    final sender = BleCodePairingSender(code, payload);
    final run = await exchange(sender);
    expect(await sender.handle('another-peer', run.command), isNull);
    final result = await sender.handle('peer-a', run.command);
    expect(result, isNotNull);
    expect(jsonEncode(result), isNot(contains(token)));
    expect(jsonEncode(result), isNot(contains(payload)));
    expect(await BleCodePairing.open(run.keys, run.id, result!['sealed']),
        payload);
    expect(await sender.handle('peer-a', run.command), isNull);
    sender.dispose();
  });

  test('wrong code never proves sender or releases the token', () async {
    final sender = BleCodePairingSender(code, payload);
    final run = await exchange(sender, guess: wrong);
    expect(await sender.handle('peer-a', run.command), isNull);
    sender.dispose();
  });

  test('AEAD rejects altered ciphertext, wrong context and invalid QR',
      () async {
    final sender = BleCodePairingSender(code, payload);
    final run = await exchange(sender);
    final reply = (await sender.handle('peer-a', run.command))!;
    final sealed = reply['sealed'] as String;
    final bytes = base64Url.decode(base64Url.normalize(sealed));
    bytes[bytes.length ~/ 2] ^= 1;
    expect(await BleCodePairing.open(run.keys, run.id, CodePake.encode(bytes)),
        isNull);
    expect(await BleCodePairing.open(run.keys, BleCodePairing.newId(), sealed),
        isNull);
    final badQr = await BleCodePairing.seal(run.keys, run.id, 'not a QR');
    expect(await BleCodePairing.open(run.keys, run.id, badQr), isNull);
    sender.dispose();
  });

  test('expiry and dispose discard pending proofs', () async {
    var now = DateTime.utc(2026);
    final sender = BleCodePairingSender(code, payload, now: () => now);
    final expired = await exchange(sender);
    now = now.add(const Duration(seconds: 15));
    expect(await sender.handle('peer-a', expired.command), isNull);
    final disposed = await exchange(sender);
    sender.dispose();
    expect(await sender.handle('peer-a', disposed.command), isNull);
  });

  test('per-minute limit holds across peers, then expires', () async {
    var now = DateTime.utc(2026);
    final sender = BleCodePairingSender(code, payload, now: () => now);
    final a = await BleCodePairing.begin(code);
    String start() => BleCodePairing.command(
        {'id': BleCodePairing.newId(), 'pA': CodePake.encode(a.share)});
    for (var n = 0; n < 12; n++) {
      final command = start();
      final response = await sender.handle('peer-$n', command);
      expect(response, isNotNull, reason: 'attempt $n');
      await sender.handle('peer-$n',
          BleCodePairing.command({'id': response!['id'], 'cA': 'bad'}));
    }
    expect(await sender.handle('new-peer', start()), isNull);
    now = now.add(const Duration(minutes: 1));
    expect(await sender.handle('new-peer', start()), isNotNull);
    sender.dispose();
  });

  test('lifetime limit remains after the rolling window resets', () async {
    var now = DateTime.utc(2026);
    final sender = BleCodePairingSender(code, payload, now: () => now);
    final a = await BleCodePairing.begin(code);
    String start() => BleCodePairing.command(
        {'id': BleCodePairing.newId(), 'pA': CodePake.encode(a.share)});
    for (var n = 0; n < 48; n++) {
      if (n > 0 && n % 12 == 0) now = now.add(const Duration(minutes: 1));
      final peer = 'peer-$n';
      final reply = await sender.handle(peer, start());
      expect(reply, isNotNull, reason: 'attempt $n');
      await sender.handle(
          peer, BleCodePairing.command({'id': reply!['id'], 'cA': 'bad'}));
    }
    now = now.add(const Duration(minutes: 1));
    expect(await sender.handle('new-peer', start()), isNull);
    sender.dispose();
  });

  test('only four concurrent proofs can remain pending; expiry frees them',
      () async {
    var now = DateTime.utc(2026);
    final sender = BleCodePairingSender(code, payload, now: () => now);
    final a = await BleCodePairing.begin(code);
    String start() => BleCodePairing.command(
        {'id': BleCodePairing.newId(), 'pA': CodePake.encode(a.share)});
    final replies = await Future.wait(
        List.generate(6, (n) => sender.handle('peer-$n', start())));
    expect(replies.whereType<Map>().length, lessThanOrEqualTo(4));
    expect(await sender.handle('fifth', start()), isNull);
    now = now.add(const Duration(seconds: 15));
    expect(await sender.handle('after-expiry', start()), isNotNull);
    sender.dispose();
  });

  test('parse rejects oversized and malformed commands', () {
    final id = BleCodePairing.newId();
    expect(BleCodePairing.parse(BleCodePairing.command({'id': id})), isNotNull);
    expect(
        BleCodePairing.parse(BleCodePairing.command({'id': id, 'x': 'é' * 90})),
        isNull);
    expect(BleCodePairing.parse('PAIR:{bad'), isNull);
    expect(BleCodePairing.parse('HELLO:{}'), isNull);
  });
}

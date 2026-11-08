import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:quickshare/core/crypto/hkdf.dart';
import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

/// Password-authenticated BLE rendezvous. The digits never go on the radio;
/// neither the advertised locator nor the transfer token derives from them.
/// Each fresh SPAKE2 run permits one online guess, bounded by the sender.
class BleCodePairing {
  static const prefix = 'PAIR:';
  static final _cipher = Chacha20.poly1305Aead();

  static String newId() => CodePake.encode(
      List<int>.generate(12, (_) => Random.secure().nextInt(256)));

  static List<int> _context(String id) =>
      utf8.encode('directdrop/ble-code/v1/$id');

  static SecretKey _key(Spake2Keys keys) => SecretKey(hkdfSha256(keys.ke,
      info: utf8.encode('directdrop/ble-code/v1/offer-key'), length: 32));

  static Future<Spake2> begin(SessionCode code) => CodePake.begin(code);

  static Future<Spake2Keys> complete(
          Spake2 begun, List<int> share, String id) =>
      Isolate.run(() => begun.finish(share,
          identityA: utf8.encode('directdrop/ble-receiver'),
          identityB: utf8.encode('directdrop/ble-sender'),
          aad: _context(id)));

  static Future<PakeReply> respond(
          SessionCode code, List<int> share, String id) =>
      Isolate.run(() {
        final begun =
            Spake2.start(role: Spake2Role.b, w: CodePake.passwordScalar(code));
        final keys = begun.finish(share,
            identityA: utf8.encode('directdrop/ble-receiver'),
            identityB: utf8.encode('directdrop/ble-sender'),
            aad: _context(id));
        return PakeReply(begun.share, keys);
      });

  static String command(Map<String, Object?> message) =>
      '$prefix${jsonEncode(message)}';

  static Map<String, dynamic>? parse(String command) {
    if (!command.startsWith(prefix) || utf8.encode(command).length > 180) {
      return null;
    }
    try {
      final json = jsonDecode(command.substring(prefix.length));
      if (json is! Map<String, dynamic> ||
          CodePake.decode(json['id'], length: 12) == null) {
        return null;
      }
      return json;
    } catch (_) {
      return null;
    }
  }

  static Future<String> seal(Spake2Keys keys, String id, String payload) async {
    final box = await _cipher.encrypt(utf8.encode(payload),
        secretKey: _key(keys), aad: _context(id));
    return CodePake.encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<String?> open(
      Spake2Keys keys, String id, Object? sealed) async {
    if (sealed is! String || sealed.length > 3500) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(sealed));
      if (bytes.length < 29) return null;
      final clear = await _cipher.decrypt(
          SecretBox(bytes.sublist(12, bytes.length - 16),
              nonce: bytes.sublist(0, 12),
              mac: Mac(bytes.sublist(bytes.length - 16))),
          secretKey: _key(keys),
          aad: _context(id));
      final payload = utf8.decode(clear);
      return BluetoothQrPayload.tryDecode(payload) == null ? null : payload;
    } catch (_) {
      return null;
    }
  }
}

/// One sender offer. Limits are global across central identifiers so changing
/// a radio address cannot bypass them. Discarded on rotation/cancellation.
class BleCodePairingSender {
  BleCodePairingSender(this.code, this.payload, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final SessionCode code;
  final String payload;
  final DateTime Function() _now;
  final _pending = <String, ({PakeReply reply, DateTime expires})>{};
  final _attempts = <DateTime>[];
  final _computing = <String>{};
  var _total = 0;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _pending.clear();
    _computing.clear();
  }

  Future<Map<String, Object?>?> handle(String peer, String command) async {
    if (_disposed) return null;
    final message = BleCodePairing.parse(command);
    if (message == null) return null;
    final id = message['id'] as String;
    final key = '$peer/$id';
    final now = _now();
    _pending.removeWhere((_, value) => !value.expires.isAfter(now));
    if (message['pA'] != null) {
      final share = CodePake.decode(message['pA'], length: Spake2.shareLength);
      if (share == null) return null;
      _attempts.removeWhere((at) => now.difference(at).inMinutes >= 1);
      if (_total >= 48 ||
          _attempts.length >= 12 ||
          _pending.length + _computing.length >= 4 ||
          _pending.containsKey(key) ||
          _computing.contains(key)) {
        return null;
      }
      _total++;
      _attempts.add(now);
      // Reserve before leaving this isolate; concurrent writes cannot exceed
      // the pending cap, and an old run cannot overwrite a newer one.
      _computing.add(key);
      final PakeReply reply;
      try {
        reply = await BleCodePairing.respond(code, share, id);
      } on Spake2Exception {
        return null;
      } finally {
        _computing.remove(key);
      }
      if (_disposed || !now.add(const Duration(seconds: 15)).isAfter(_now())) {
        return null;
      }
      if (_pending.length >= 4 || _pending.containsKey(key)) return null;
      _pending[key] =
          (reply: reply, expires: now.add(const Duration(seconds: 15)));
      return {
        'id': id,
        'pB': CodePake.encode(reply.share),
        'cB': CodePake.encode(reply.keys.confirmationB),
      };
    }
    final pending = _pending.remove(key);
    final tag = CodePake.decode(message['cA'], length: CodePake.tagLength);
    if (pending == null ||
        tag == null ||
        !pending.reply.keys.verifies(Spake2Role.a, tag)) {
      return null;
    }
    final sealed = await BleCodePairing.seal(pending.reply.keys, id, payload);
    return _disposed ? null : {'id': id, 'sealed': sealed};
  }
}

import 'dart:convert';

/// QR payload used to bootstrap a Bluetooth transfer.
///
/// The QR code does not carry the file. It carries a short-lived session
/// token so the receiver can select the matching BLE advertiser automatically.
class BluetoothQrPayload {
  static const prefix = 'quickshare-bt:v1:';
  static const serviceUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';

  final String token;

  /// The public half of the session code, when the session has one.
  ///
  /// What the sender puts in its advertised name, so the receiver can pick it
  /// out of several without the token ever going over the air. Empty for a
  /// session from an older build, which advertised a slice of the token
  /// instead — the receiver falls back to matching on that.
  final String publicId;

  const BluetoothQrPayload({required this.token, this.publicId = ''});

  String encode() {
    final json = jsonEncode(<String, dynamic>{
      'v': 1,
      'token': token,
      if (publicId.isNotEmpty) 'cid': publicId,
      'service': serviceUuid,
    });
    return '$prefix${base64Url.encode(utf8.encode(json))}';
  }

  static BluetoothQrPayload? tryDecode(String raw) {
    if (!raw.startsWith(prefix)) return null;
    try {
      final encoded = raw.substring(prefix.length);
      final decoded =
          utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
      final json = jsonDecode(decoded);
      if (json is! Map || json['v'] != 1 || json['service'] != serviceUuid) {
        return null;
      }
      final token = json['token'];
      if (token is! String || token.isEmpty || token.length > 128) return null;
      final cid = json['cid'];
      return BluetoothQrPayload(
        token: token,
        publicId: cid is String && cid.length <= 32 ? cid : '',
      );
    } catch (_) {
      return null;
    }
  }
}

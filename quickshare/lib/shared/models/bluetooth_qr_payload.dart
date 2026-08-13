import 'dart:convert';

/// QR payload used to bootstrap a Bluetooth transfer.
///
/// The QR code does not carry the file. It carries a short-lived session
/// token so the receiver can select the matching BLE advertiser automatically.
class BluetoothQrPayload {
  static const prefix = 'quickshare-bt:v1:';
  static const serviceUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';

  final String token;

  const BluetoothQrPayload({required this.token});

  String encode() {
    final json = jsonEncode(<String, dynamic>{
      'v': 1,
      'token': token,
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
      if (json is! Map || json['v'] != 1 || json['service'] != serviceUuid)
        return null;
      final token = json['token'];
      if (token is! String || token.isEmpty || token.length > 128) return null;
      return BluetoothQrPayload(token: token);
    } catch (_) {
      return null;
    }
  }
}

import 'dart:convert';

/// QR payload used to bootstrap a Bluetooth transfer.
///
/// The QR code does not carry the file. It carries a short-lived session
/// token, and a locator so the receiver can select the matching BLE advertiser
/// automatically. Both are random, drawn for this session, and tied to no
/// code: the QR is the only place the pair is handed over.
class BluetoothQrPayload {
  static const prefix = 'quickshare-bt:v1:';
  static const serviceUuid = 'E9C1F384-1D30-4B77-8B8B-9E1A7D5F6B10';

  final String token;

  /// The session's random locator.
  ///
  /// What the sender puts in its advertised name, so the receiver can pick it
  /// out of several without the token ever going over the air — and what the
  /// two devices bind the sealed link credentials to, a value both hold without
  /// anything having to be sent. It is not the session code or derived from it:
  /// this field used to be `SessionCode.publicId`, a hash of the ten digits that
  /// anyone who read it off the air could search for them, and the receiver had
  /// to get the digits from the sender to work out the same value. Empty for a
  /// session from an older build, which advertised a slice of the token
  /// instead — the receiver falls back to matching on that, and refuses to go
  /// on to negotiate a link with it.
  ///
  /// Still written under `cid`, the key every build since the field was added
  /// has used: an older receiver that scans this QR then looks for the right
  /// name, finds the sender and is told to update, rather than searching for a
  /// sender that never turns up.
  final String locator;
  final String fileName;
  final int fileSize;
  final int itemCount;
  final String senderName;

  const BluetoothQrPayload({
    required this.token,
    this.locator = '',
    this.fileName = '',
    this.fileSize = 0,
    this.itemCount = 0,
    this.senderName = '',
  });

  String encode() {
    final json = jsonEncode(<String, dynamic>{
      'v': 1,
      'token': token,
      if (locator.isNotEmpty) 'cid': locator,
      'service': serviceUuid,
      if (fileName.isNotEmpty) 'name': fileName,
      if (fileSize > 0) 'size': fileSize,
      if (itemCount > 0) 'count': itemCount,
      if (senderName.isNotEmpty) 'sender': senderName,
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
      final name = json['name'] as String? ?? '';
      final size = (json['size'] as num?)?.toInt() ?? 0;
      final count = (json['count'] as num?)?.toInt() ?? 0;
      final sender = json['sender'] as String? ?? '';
      return BluetoothQrPayload(
        token: token,
        locator: cid is String && cid.length <= 32 ? cid : '',
        fileName: name,
        fileSize: size,
        itemCount: count,
        senderName: sender,
      );
    } catch (_) {
      return null;
    }
  }
}

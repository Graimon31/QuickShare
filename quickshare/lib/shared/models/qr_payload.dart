import 'dart:convert';
import 'dart:io';
import 'package:equatable/equatable.dart';
import 'package:quickshare/core/constants/app_constants.dart';

class QRPayload extends Equatable {
  final int version;
  final String ip;
  final int port;
  final String token;
  final String fileName;
  final int fileSize;
  final String checksum;
  final String? sessionId;
  final String? mode;
  final String? sdpOffer;

  /// Number of files in a QHTP multi-file session (0 when unknown / single-file).
  final int itemCount;

  const QRPayload({
    required this.version,
    required this.ip,
    required this.port,
    required this.token,
    this.fileName = '',
    this.fileSize = 0,
    this.checksum = '',
    this.sessionId,
    this.mode,
    this.sdpOffer,
    this.itemCount = 0,
  });

  bool get isQhtp =>
      version == AppConstants.qhtpPayloadVersion ||
      (sessionId != null && sessionId!.isNotEmpty);

  factory QRPayload.fromJson(Map<String, dynamic> json) {
    final v = json['v'] as int? ?? AppConstants.qrPayloadVersion;
    if (v == 2 || json.containsKey('sid')) {
      return QRPayload(
        version: v,
        ip: json['ip'] as String,
        port: json['p'] as int,
        token: json['t'] as String,
        sessionId: json['sid'] as String?,
        mode: json['mode'] as String? ?? 'http-lan',
        sdpOffer: json['sdp'] as String?,
        // Optional metadata so the phone can show folder size before LAN
        // preview HTTP succeeds (or when it fails entirely).
        fileName: json['fn'] as String? ?? '',
        fileSize: json['fs'] as int? ?? 0,
        itemCount: json['ic'] as int? ?? 0,
      );
    }
    return QRPayload(
      version: v,
      ip: json['ip'] as String,
      port: json['p'] as int,
      token: json['t'] as String,
      fileName: json['fn'] as String? ?? '',
      fileSize: json['fs'] as int? ?? 0,
      checksum: json['cs'] as String? ?? '',
      sdpOffer: json['sdp'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    if (isQhtp) {
      return {
        'v': 2,
        'ip': ip,
        'p': port,
        't': token,
        'sid': sessionId ?? '',
        'mode': mode ?? 'http-lan',
        if (sdpOffer != null && sdpOffer!.isNotEmpty) 'sdp': sdpOffer,
        if (fileName.isNotEmpty) 'fn': fileName,
        if (fileSize > 0) 'fs': fileSize,
        if (itemCount > 0) 'ic': itemCount,
      };
    }
    return {
      'v': version,
      'ip': ip,
      'p': port,
      't': token,
      'fn': fileName,
      'fs': fileSize,
      'cs': checksum,
      if (sdpOffer != null && sdpOffer!.isNotEmpty) 'sdp': sdpOffer,
    };
  }

  /// A single zlib pass over the whole JSON. Compressing the SDP separately
  /// and then base64-ing the JSON around it encoded already-compressed bytes
  /// twice, inflating the payload ~33% past the 2953-byte QR byte-mode ceiling.
  String encode() {
    final bytes = utf8.encode(jsonEncode(toJson()));
    return base64Url.encode(zlib.encode(bytes)).replaceAll('=', '');
  }

  static QRPayload decode(String encoded) {
    try {
      // Scanners sometimes wrap payloads with whitespace, newlines, or
      // zero-width chars. Also tolerate standard base64 (+/) vs base64url (-_).
      String normalized = encoded
          .trim()
          .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF\r\n\s]'), '')
          .replaceAll('-', '+')
          .replaceAll('_', '/');
      // Prefer base64Url.normalize on the original url-safe form.
      final urlSafe =
          encoded.trim().replaceAll(RegExp(r'[\u200B-\u200D\uFEFF\r\n\s]'), '');
      late final List<int> bytes;
      try {
        bytes = base64Url.decode(base64Url.normalize(urlSafe));
      } catch (_) {
        while (normalized.length % 4 != 0) {
          normalized += '=';
        }
        bytes = base64.decode(normalized);
      }
      String jsonString;
      try {
        jsonString = utf8.decode(zlib.decode(bytes));
      } catch (_) {
        // Payloads from builds that predate the single-compression format.
        jsonString = utf8.decode(bytes);
      }
      final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
      final payload = QRPayload.fromJson(jsonMap);
      if (payload.version != 1 && payload.version != 2) {
        throw FormatException(
            'Unsupported QR version: ${payload.version}. Expected 1 or 2.');
      }
      return payload;
    } catch (e) {
      throw FormatException('Invalid QR payload encoding', e);
    }
  }

  bool get isValid =>
      version > 0 &&
      ip.isNotEmpty &&
      (mode == 'webrtc-sdp' ||
          (sdpOffer != null && sdpOffer!.isNotEmpty) ||
          port > 0) &&
      token.isNotEmpty &&
      (isQhtp
          ? (sessionId != null && sessionId!.isNotEmpty)
          : (fileName.isNotEmpty && fileSize >= 0));

  @override
  List<Object?> get props => [
        version,
        ip,
        port,
        token,
        fileName,
        fileSize,
        checksum,
        sessionId,
        mode,
        itemCount,
      ];
}

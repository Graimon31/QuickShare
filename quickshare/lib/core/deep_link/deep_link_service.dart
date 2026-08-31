import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'package:quickshare/core/constants/app_constants.dart';

/// A `directdrop://join?p=…` share link, with optional display metadata.
///
/// The QR itself is [qrPayload]. Serverless (`QS1…`) QR codes do not carry a
/// file name or size — those go in `n` / `s` / `c` so the receiver can show
/// what is coming before the DataChannel opens.
class ShareLinkContents {
  final String qrPayload;
  final String? name;
  final int? bytes;
  final int? itemCount;

  const ShareLinkContents({
    required this.qrPayload,
    this.name,
    this.bytes,
    this.itemCount,
  });
}

/// Listens for `directdrop://join?p=…` share links and hands the receiver the
/// QR payload they carry — the same bytes a camera would have read.
class DeepLinkService {
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;

  final _sharePayloads = StreamController<ShareLinkContents>.broadcast();

  /// QR payloads extracted from `directdrop://join?p=…` share links.
  ///
  /// The `p` query carries the same bytes that went into the sender QR —
  /// a serverless `QS1…` string or a compressed QHTP locator — so the
  /// receiver can open a link instead of pointing a camera at the screen.
  Stream<ShareLinkContents> get sharePayloads => _sharePayloads.stream;

  DeepLinkService({AppLinks? appLinks}) : _appLinks = appLinks ?? AppLinks();

  /// Query key for a share link that carries the QR payload itself.
  static const String payloadQuery = 'p';
  static const String nameQuery = 'n';
  static const String sizeQuery = 's';
  static const String countQuery = 'c';

  /// Wraps the QR payload in a `directdrop://join?p=…` link.
  ///
  /// [name], [bytes] and [itemCount] are optional preview fields. They are
  /// required for serverless (`QS1`) shares, which otherwise have no file
  /// name or size until the DataChannel opens.
  static String buildPayloadLink(
    String qrPayload, {
    String? name,
    int? bytes,
    int? itemCount,
  }) {
    final q = <String, String>{
      payloadQuery: qrPayload.trim(),
    };
    final trimmedName = name?.trim();
    if (trimmedName != null && trimmedName.isNotEmpty) {
      q[nameQuery] = trimmedName;
    }
    if (bytes != null && bytes > 0) q[sizeQuery] = '$bytes';
    if (itemCount != null && itemCount > 0) q[countQuery] = '$itemCount';
    return Uri(
      scheme: AppConstants.deepLinkScheme,
      host: AppConstants.deepLinkHost,
      queryParameters: q,
    ).toString();
  }

  /// Full share-link parse, including preview metadata.
  static ShareLinkContents? parseShareLinkFromUri(Uri uri) {
    final payload = parseSharePayloadFromUri(uri);
    if (payload == null) return null;
    final name = uri.queryParameters[nameQuery]?.trim();
    final bytes = int.tryParse(uri.queryParameters[sizeQuery] ?? '');
    final count = int.tryParse(uri.queryParameters[countQuery] ?? '');
    return ShareLinkContents(
      qrPayload: payload,
      name: (name != null && name.isNotEmpty) ? name : null,
      bytes: (bytes != null && bytes > 0) ? bytes : null,
      itemCount: (count != null && count > 0) ? count : null,
    );
  }

  /// Parses a pasted string: a payload share link, or null if it is not one.
  static ShareLinkContents? parseShareLink(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme.isEmpty) return null;
    return parseShareLinkFromUri(uri);
  }

  /// The QR payload inside a payload share link, or null if this URI is
  /// something else (a foreign scheme, empty).
  static String? parseSharePayloadFromUri(Uri uri) {
    if (uri.scheme.toLowerCase() != AppConstants.deepLinkScheme) return null;
    final raw = uri.queryParameters[payloadQuery];
    if (raw == null) return null;
    final payload = raw.trim();
    return payload.isEmpty ? null : payload;
  }

  /// If [text] is a payload share link, return the inner QR bytes; otherwise
  /// return the trimmed original. Safe to run on every paste and every scan.
  static String unwrapToQrPayload(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme.isEmpty) return trimmed;
    return parseSharePayloadFromUri(uri) ?? trimmed;
  }

  Future<void> init() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        _dispatch(initial);
      }
    } catch (e) {
      debugPrint('DeepLinkService: initial link check failed: $e');
    }

    _sub = _appLinks.uriLinkStream.listen(
      _dispatch,
      onError: (e) => debugPrint('DeepLinkService: link stream error: $e'),
    );
  }

  void _dispatch(Uri uri) {
    final share = parseShareLinkFromUri(uri);
    if (share != null) _sharePayloads.add(share);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _sharePayloads.close();
  }
}

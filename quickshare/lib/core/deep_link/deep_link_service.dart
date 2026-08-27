import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'package:quickshare/core/constants/app_constants.dart';

/// Parsed Internet-share invite (room + optional peer-reachable signaling URL).
class InternetInvite {
  final String roomCode;

  /// WebSocket URL the *receiver* should dial (may differ from sender's localhost).
  final String? signalingUrl;

  const InternetInvite({required this.roomCode, this.signalingUrl});
}

/// A `directdrop://join?p=…` share link, with optional display metadata.
///
/// The QR itself is [qrPayload]. Internet/serverless QR codes (`QS1…`) do not
/// carry a file name or size — those go in `n` / `s` / `c` so the receiver
/// can show what is coming before the DataChannel opens.
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

/// Listens for `directdrop://join?room=CODE` links and exposes the room codes.
///
/// Internet shares may also carry `sig=` (URL-encoded ws/wss endpoint) so the
/// phone can reach the Mac's signaling server without guessing localhost.
class DeepLinkService {
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;

  final _roomCodes = StreamController<String>.broadcast();
  final _invites = StreamController<InternetInvite>.broadcast();
  final _sharePayloads = StreamController<ShareLinkContents>.broadcast();

  /// Room codes parsed from incoming share links (legacy).
  Stream<String> get roomCodes => _roomCodes.stream;

  /// Full invites including optional signaling URL.
  Stream<InternetInvite> get invites => _invites.stream;

  /// QR payloads extracted from `directdrop://join?p=…` share links.
  ///
  /// The `p` query carries the same bytes that went into the sender QR —
  /// a serverless `QS1…` string or a compressed QHTP locator — so the
  /// receiver can open a link instead of pointing a camera at the screen.
  Stream<ShareLinkContents> get sharePayloads => _sharePayloads.stream;

  DeepLinkService({AppLinks? appLinks}) : _appLinks = appLinks ?? AppLinks();

  /// Extracts the room code from a share link, or null if it isn't one.
  static String? parseRoomCode(Uri uri) {
    return parseInternetInviteFromUri(uri)?.roomCode;
  }

  /// Parses `directdrop://join?room=CODE&sig=ws%3A%2F%2F…`.
  static InternetInvite? parseInternetInviteFromUri(Uri uri) {
    if (uri.scheme.toLowerCase() != AppConstants.deepLinkScheme) return null;

    final fromQuery = uri.queryParameters['room'];
    final candidate = (fromQuery != null && fromQuery.isNotEmpty)
        ? fromQuery
        : (uri.pathSegments.isNotEmpty ? uri.pathSegments.last : null);

    if (candidate == null) return null;
    final code = candidate.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{6}$').hasMatch(code)) return null;

    final rawSig = uri.queryParameters['sig']?.trim();
    String? signalingUrl;
    if (rawSig != null && rawSig.isNotEmpty) {
      final decoded = Uri.decodeComponent(rawSig);
      final sigUri = Uri.tryParse(decoded);
      if (sigUri != null &&
          (sigUri.scheme == 'ws' || sigUri.scheme == 'wss') &&
          sigUri.host.isNotEmpty) {
        signalingUrl = decoded;
      }
    }

    return InternetInvite(roomCode: code, signalingUrl: signalingUrl);
  }

  /// Parses a pasted full link or bare six-character room code.
  static String? parseFromText(String text) {
    return parseInternetInvite(text)?.roomCode;
  }

  /// Full invite parse for Internet receive (room + optional `sig=`).
  static InternetInvite? parseInternetInvite(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.scheme.isNotEmpty) {
      final fromUri = parseInternetInviteFromUri(uri);
      if (fromUri != null) return fromUri;
    }

    final bare = trimmed.toUpperCase();
    if (RegExp(r'^[A-Z0-9]{6}$').hasMatch(bare)) {
      return InternetInvite(roomCode: bare);
    }
    return null;
  }

  /// Builds a share link the receiver can open or paste.
  static String buildShareLink({
    required String roomCode,
    String? signalingUrlForPeer,
  }) {
    final code = roomCode.trim().toUpperCase();
    const base = '${AppConstants.deepLinkScheme}://${AppConstants.deepLinkHost}';
    if (signalingUrlForPeer == null || signalingUrlForPeer.isEmpty) {
      return '$base?room=$code';
    }
    return '$base?room=$code&sig=${Uri.encodeComponent(signalingUrlForPeer)}';
  }

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
  /// something else (a room invite, a foreign scheme, empty).
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
    if (share != null) {
      _sharePayloads.add(share);
      return;
    }
    final invite = parseInternetInviteFromUri(uri);
    if (invite != null) {
      _roomCodes.add(invite.roomCode);
      _invites.add(invite);
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _roomCodes.close();
    await _invites.close();
    await _sharePayloads.close();
  }
}

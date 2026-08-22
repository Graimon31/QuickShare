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

/// Listens for `directdrop://join?room=CODE` links and exposes the room codes.
///
/// Internet shares may also carry `sig=` (URL-encoded ws/wss endpoint) so the
/// phone can reach the Mac's signaling server without guessing localhost.
class DeepLinkService {
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;

  final _roomCodes = StreamController<String>.broadcast();
  final _invites = StreamController<InternetInvite>.broadcast();

  /// Room codes parsed from incoming share links (legacy).
  Stream<String> get roomCodes => _roomCodes.stream;

  /// Full invites including optional signaling URL.
  Stream<InternetInvite> get invites => _invites.stream;

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

  Future<void> init() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        final invite = parseInternetInviteFromUri(initial);
        if (invite != null) {
          _roomCodes.add(invite.roomCode);
          _invites.add(invite);
        }
      }
    } catch (e) {
      debugPrint('DeepLinkService: initial link check failed: $e');
    }

    _sub = _appLinks.uriLinkStream.listen(
      (uri) {
        final invite = parseInternetInviteFromUri(uri);
        if (invite != null) {
          _roomCodes.add(invite.roomCode);
          _invites.add(invite);
        }
      },
      onError: (e) => debugPrint('DeepLinkService: link stream error: $e'),
    );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _roomCodes.close();
    await _invites.close();
  }
}

class AppConstants {
  static const int serverPortMin = 8000;
  static const int serverPortMax = 9000;
  static const int sessionTimeoutSeconds = 300; // 5 min
  static const int maxRetryAttempts = 3;
  static const int connectionTimeoutMs = 3000;
  static const int qrPayloadVersion = 1;
  static const String appName = 'QuickShare';
  
  /// Signaling server endpoint for the *sender process* (may be localhost).
  /// The share link embeds a peer-reachable rewrite (LAN IP) via `sig=`.
  /// Public Internet / LTE: use a reachable host, e.g.:
  ///   --dart-define=QUICKSHARE_SIGNALING_URL=wss://share.example.com
  static const String signalingServerUrl = String.fromEnvironment(
    'QUICKSHARE_SIGNALING_URL',
    defaultValue: 'ws://localhost:3000',
  );

  /// TURN server URL for symmetric NAT traversal.
  /// Example: --dart-define=QUICKSHARE_TURN_URL=turn:turn.example.com:3478
  static const String turnServerUrl = String.fromEnvironment(
    'QUICKSHARE_TURN_URL',
    defaultValue: 'turn:openrelay.metered.ca:80',
  );
  static const String turnUsername = String.fromEnvironment(
    'QUICKSHARE_TURN_USER',
    defaultValue: 'openrelaymodule',
  );
  static const String turnCredential = String.fromEnvironment(
    'QUICKSHARE_TURN_PASS',
    defaultValue: 'openrelaymodule',
  );

  /// Custom URL scheme used for share links between QuickShare apps.
  /// A share link looks like: quickshare://join?room=A1B2C3
  static const String deepLinkScheme = 'quickshare';
  static const String deepLinkHost = 'join';

  static const int webRtcChunkSizeBytes = 16384;
  static const int webRtcMaxBufferedAmount = 262144; // 256 KB datachannel backpressure
  static const int maxFileSizeBytes = 2 * 1024 * 1024 * 1024; // 2 GB limit
  static const int qhtpSessionTimeoutSeconds = 1800; // 30 min for heavy transfers
  static const int qhtpPayloadVersion = 2;
  static const int qhtpMaxFileBytes = 100 * 1024 * 1024 * 1024; // 100 GB
  static const int qhtpMaxSessionBytes = 500 * 1024 * 1024 * 1024; // 500 GB
  static const int qhtpMaxFileCount = 100000;
  static const int qhtpMaxPathDepth = 32;
  static const int qhtpMaxRelPathChars = 512;
  static const int qhtpManifestMaxBytes = 32 * 1024 * 1024; // 32 MB

  const AppConstants._();
}



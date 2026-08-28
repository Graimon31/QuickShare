import 'package:quickshare/core/webrtc/ice_servers.dart';

class AppConstants {
  static const int serverPortMin = 8000;
  static const int serverPortMax = 9000;
  static const int sessionTimeoutSeconds = 300; // 5 min
  static const int maxRetryAttempts = 3;
  static const int connectionTimeoutMs = 3000;
  static const int qrPayloadVersion = 1;
  static const String appName = 'DirectDrop';
  
  /// Signaling server endpoint for the *sender process* (may be localhost).
  /// The share link embeds a peer-reachable rewrite (LAN IP) via `sig=`.
  /// Public Internet / LTE: use a reachable host, e.g.:
  ///   --dart-define=QUICKSHARE_SIGNALING_URL=wss://share.example.com
  static const String signalingServerUrl = String.fromEnvironment(
    'QUICKSHARE_SIGNALING_URL',
    defaultValue: 'ws://localhost:3000',
  );

  /// STUN servers used to discover the public mapping, in the order ICE
  /// should try them.
  ///
  /// A pool rather than a single host, and not because any one of these is
  /// dead: measurements from the target network disagree with each other
  /// depending on whether a VPN is up. `stun.l.google.com` timed out with the
  /// tunnel down and answered in 244 ms with a split-tunnel VPN active, while
  /// the Russian hosts behave the other way round. No single STUN server is
  /// reliable across the user population, so gather from several and let ICE
  /// pick.
  static const List<String> stunServers = [
    'stun:stun.cloudflare.com:3478',
    'stun:stun.sipnet.ru:3478',
    'stun:stun.fitauto.ru:3478',
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
  ];

  /// How long ICE gathering may run before the offer is frozen.
  ///
  /// This used to be one second, which quietly broke every session that needed
  /// a relay. In serverless mode the offer is baked into a QR code and there is
  /// no trickle path afterwards, so a candidate that shows up late is not late
  /// — it is lost. A TURN allocation over TLS on this network needed 557-1040 ms
  /// just to complete its handshake, so a one-second cap threw the relay
  /// candidate away most of the time, and with it every transfer behind a VPN
  /// or a symmetric NAT.
  ///
  /// Gathering still returns as soon as it finishes, or as soon as a relay
  /// candidate exists; this is only the ceiling.
  static const Duration iceGatheringMaxWait = Duration(seconds: 6);

  /// TURN server URL for symmetric NAT traversal.
  /// Example: --dart-define=QUICKSHARE_TURN_URL=turn:turn.example.com:3478
  ///
  /// The previous default, `turn:openrelay.metered.ca:80`, no longer resolves
  /// at all — 1.1.1.1 and 8.8.8.8 both return NXDOMAIN for that name while
  /// `metered.ca` itself resolves, so the host is gone rather than blocked.
  /// Every build shipped with it had no relay path whatsoever, which is the
  /// difference between "P2P sometimes fails" and "P2P fails with no fallback".
  ///
  /// `standard.relay.metered.ca` is the successor name and does answer TURN
  /// (it issues a proper 401 challenge). Whether the old open credentials below
  /// are still honoured there is NOT verified — supply your own with
  /// `--dart-define` if relay candidates never appear in the logs.
  static const String turnServerUrl = String.fromEnvironment(
    'QUICKSHARE_TURN_URL',
    defaultValue: 'turn:standard.relay.metered.ca:80',
  );
  /// Comma-separated extra TURN hosts, e.g.
  /// `--dart-define=QUICKSHARE_TURN_HOSTS=turn:a.example.com,turn:b.example.com`
  ///
  /// Each entry is expanded by [IceServers.expandTransports] into TCP/443,
  /// TLS/443, TCP/80 and UDP variants, in that order. A pool rather than one
  /// host because the single baked-in default is exactly what broke: when it
  /// disappeared there was nothing behind it.
  static const String turnServerHosts = String.fromEnvironment(
    'QUICKSHARE_TURN_HOSTS',
    defaultValue: '',
  );

  static const String turnUsername = String.fromEnvironment(
    'QUICKSHARE_TURN_USER',
    defaultValue: 'openrelaymodule',
  );
  static const String turnCredential = String.fromEnvironment(
    'QUICKSHARE_TURN_PASS',
    defaultValue: 'openrelaymodule',
  );

  /// Every TURN transport to offer ICE, best first.
  ///
  /// Credentials are deliberately not here: they arrive through
  /// `QUICKSHARE_TURN_USER` / `QUICKSHARE_TURN_PASS` at build time, so a
  /// private account can be wired in from CI without a code change.
  static List<String> get turnServerUrls {
    final hosts = <String>[
      if (turnServerUrl.trim().isNotEmpty) turnServerUrl,
      ...turnServerHosts.split(',').where((h) => h.trim().isNotEmpty),
    ];
    return [
      for (final host in hosts) ...IceServers.expandTransports(host),
    ];
  }

  /// Ceiling on a session that would have to travel through a TURN relay.
  ///
  /// A direct path costs nothing and carries no limit — send 500 GB over it.
  /// A relayed path rides on the project's own Cloudflare Calls allocation
  /// (free tier is measured in hundreds of GB a month, not megabytes), so the
  /// ceiling now matches the largest file the WebRTC path can carry at all.
  /// TCP-over-TLS relaying realistically runs at 1-3 MB/s — a gigabyte means
  /// ten minutes — but that is a slow transfer, not a failed one.
  ///
  /// Override with `--dart-define=QUICKSHARE_RELAY_LIMIT=<bytes>`; 0 means no
  /// limit.
  static const int maxRelayTransferBytes = int.fromEnvironment(
    'QUICKSHARE_RELAY_LIMIT',
    defaultValue: 2 * 1024 * 1024 * 1024, // 2 GB, same as maxFileSizeBytes
  );

  /// Base URL of the DirectDrop Cloudflare Worker (rendezvous reserve channel
  /// + short-lived TURN credentials), e.g.
  /// `--dart-define=QUICKSHARE_WORKER_URL=https://directdrop-worker.<account>.workers.dev`
  ///
  /// Defaults to the deployed production Worker. Without it a build has only
  /// the static Metered credentials above — which answer with no relay
  /// candidate at all — so every internet transfer between two NATted peers
  /// (which is to say, most of them) had no fallback when the direct path
  /// failed: Windows↔iOS could not connect at all, and Windows↔macOS died
  /// ~4 MB in when the marginal srflx pair went silent.
  static const String workerBaseUrl = String.fromEnvironment(
    'QUICKSHARE_WORKER_URL',
    defaultValue: 'https://directdrop-worker.directdrop-worker.workers.dev',
  );

  /// Which rendezvous channels may carry the sealed SDP answer, comma
  /// separated. Both by default; they race and the first delivery wins.
  ///
  /// Exists to isolate one channel during a field test — proving the Worker
  /// path actually works is impossible while Nostr can quietly answer first
  /// and make a broken Worker look healthy:
  ///   `--dart-define=QUICKSHARE_RENDEZVOUS_CHANNELS=worker`
  static const String rendezvousChannels = String.fromEnvironment(
    'QUICKSHARE_RENDEZVOUS_CHANNELS',
    defaultValue: 'nostr,worker',
  );

  static bool get nostrRendezvousEnabled => _rendezvousEnabled('nostr');

  /// The Worker channel also needs [workerBaseUrl] set; naming it here without
  /// a deployed Worker enables nothing.
  static bool get workerRendezvousEnabled =>
      _rendezvousEnabled('worker') && workerBaseUrl.trim().isNotEmpty;

  static bool _rendezvousEnabled(String channel) => rendezvousChannels
      .split(',')
      .map((c) => c.trim().toLowerCase())
      .contains(channel);

  /// Custom URL scheme used for share links between DirectDrop apps.
  /// A share link looks like: directdrop://join?room=A1B2C3
  static const String deepLinkScheme = 'directdrop';
  static const String deepLinkHost = 'join';

  /// How much payload goes into one DataChannel message, and how much may be
  /// queued before the send loop waits.
  ///
  /// Both were measured rather than guessed, on a loopback connection where
  /// the network cannot be the limit (integration_test/throughput_benchmark.dart,
  /// 128 MB, disk reading three orders of magnitude faster than any of these):
  ///
  ///   chunk    window    throughput
  ///   16 KB    256 KB     4.8 MB/s   <- what shipped
  ///   64 KB    256 KB     5.9 MB/s
  ///   16 KB      4 MB    17.4 MB/s
  ///   64 KB      4 MB    26.4 MB/s   <- here
  ///   64 KB      8 MB    27.8 MB/s
  ///
  /// The window is what mattered; the chunk size is worth a further 50% on top
  /// of it. Going to 8 MB buys another 5% and is not taken: libwebrtc kills the
  /// channel at a 16 MiB SCTP send buffer — which this app has already hit once
  /// — and `_queuedBytes` is a local estimate that the platform event corrects
  /// only afterwards, so the real queue can run ahead of it. 4 MB keeps four
  /// times that headroom.
  ///
  /// 64 KB messages are inside the 256 KB libwebrtc negotiates, and both ends
  /// of a transfer are this same app.
  static const int webRtcChunkSizeBytes = 65536;
  static const int webRtcMaxBufferedAmount = 4194304; // 4 MB
  static const int maxFileSizeBytes = 2 * 1024 * 1024 * 1024; // 2 GB limit
  static const int qhtpSessionTimeoutSeconds = 1800; // 30 min for heavy transfers
  static const int qhtpPayloadVersion = 2;
  static const int qhtpMaxFileBytes = 100 * 1024 * 1024 * 1024; // 100 GB
  static const int qhtpMaxSessionBytes = 500 * 1024 * 1024 * 1024; // 500 GB
  static const int qhtpMaxFileCount = 100000;
  static const int qhtpMaxPathDepth = 32;
  static const int qhtpMaxRelPathChars = 512;

  /// Longest single path segment, in **bytes** rather than characters.
  ///
  /// Filesystems count bytes: ext4, APFS and NTFS all cap a name at 255, and a
  /// Cyrillic or emoji name reaches that in half as many characters. Measuring
  /// in characters would let a legal-looking name fail at create() with
  /// ENAMETOOLONG, which the receiver would report as a failed transfer.
  static const int qhtpMaxNameBytes = 255;
  static const int qhtpManifestMaxBytes = 32 * 1024 * 1024; // 32 MB

  /// Above this total session size the indexer stops computing per-item
  /// SHA-256 digests.
  ///
  /// Hashing costs a full read of every byte before the QR code can appear.
  /// At a few hundred MB/s that is seconds for a couple of gigabytes and the
  /// better part of an hour for a 500 GB session, which would look like the
  /// app had hung. Sessions above the threshold are still protected against
  /// truncation by the byte-count check on the receiver.
  static const int qhtpChecksumMaxSessionBytes = 2 * 1024 * 1024 * 1024; // 2 GB

  const AppConstants._();
}



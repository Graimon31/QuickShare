# DirectDrop

Peer-to-peer file transfer between macOS, iOS, Android, Windows and Linux, with
no account, no cloud storage and no server of ours anywhere in the path. One
device shows a QR code, the other scans it, and the bytes go directly between
them.

> Renamed from QuickShare in August 2026. "Quick Share" is the name Google and
> Samsung use for their built-in system feature, and shipping under it would be
> a trademark conflict rather than a naming preference.

---

## What it does

| Transport | When it is used | Speed |
|---|---|---|
| **QHTP over Wi-Fi/LAN** | Both devices on one network | Line rate |
| **Serverless WebRTC** | Different networks, over the internet | Depends on the path |
| **Local hotspot** | No shared network and the internet path is blocked | Line rate |
| **Bluetooth LE** | Small files, no network at all | Tens of KB/s |

Folders are transferred whole, with their structure. Interrupted transfers
resume from the exact byte. Every received file is verified before it is
published under its real name.

---

## How a transfer actually works

### QHTP over the local network

The sender indexes the selection into a manifest, starts an HTTP server on the
first free port in 8000–9000, and shows a QR code carrying its address, a
one-time bearer token and the session id. The receiver fetches the manifest and
pulls items in order.

Per item: `GET /v2/files/<id>` with `Range` for resume, written to
`<name>.qs.partial`, three retries, then **verified and only then renamed**.
Verification checks the byte count always, and a SHA-256 digest when the
manifest carries one — the indexer computes digests for sessions up to 2 GB and
skips them above that, because hashing 500 GB before the QR appears would look
like a hang.

### Serverless WebRTC over the internet

Both peers are usually behind NAT that will not accept an unsolicited packet,
and the desktop has no camera, so there is no reverse visual channel. The offer
therefore travels one way — in the QR code — and the answer comes back out of
band:

```
desktop                                        phone
  │ createOffer, gather ICE                      │
  │ CompactSdp: 8 KB SDP -> ~200 bytes           │
  │ QR = "QS1" + seed(16B) + offer               │
  │ subscribe to topic = HKDF(seed)  ────────┐   │
  │                                          │   │ scan
  │                                          │   │ createAnswer
  │                                          │   │ seal with ChaCha20-Poly1305,
  │                                          │   │ key = HKDF(seed), AAD = SHA-256(offer)
  │                                          │   │ publish to the same topic
  │ <──── sealed answer ─── Nostr relays ────┘   │
  │ open, setRemoteDescription                   │
  └───────── DataChannel, file in chunks ────────┘
```

The relays are ordinary public Nostr relays reached over WSS on 443, so the
rendezvous is indistinguishable from an HTTPS session. They carry ~200 bytes of
ciphertext once and keep nothing: events use the ephemeral kind 20000, which
relays forward to current subscribers and never store. Relays do not gossip
between themselves, so both sides fan out across the whole list.

Nothing of ours is involved, and the relay operator sees neither the ICE
credentials, nor the candidate addresses, nor the fingerprint.

### Local hotspot

When there is no shared network and the internet path is blocked — a VPN
holding the default route, or a symmetric NAT — the sender raises a local-only
hotspot and serves the transfer over it. Two QR codes in sequence: a standard
`WIFI:` payload the other phone's system camera understands (no app needed for
that step), then the ordinary transfer locator.

The host is always Android or a desktop. iOS has no API to create a network
from inside an app; it can only join one, which it does through
`NEHotspotConfiguration`. iPhone-to-iPhone needs Personal Hotspot turned on by
hand.

---

## Honest limits

- **The rendezvous depends on infrastructure nobody promises to keep running.**
  Public relays can disappear. Fan-out across several makes that unlikely, not
  impossible. A guarantee would need a server, and there deliberately is none.
- **Relayed transfers are capped at 50 MB** (`QUICKSHARE_RELAY_LIMIT`). When
  ICE can only find a relay path, the bytes cross somebody else's TURN server
  at their expense and roughly 1–3 MB/s. The app checks the selected candidate
  pair after the channel opens and, before sending anything, offers the local
  network instead.
- **Bluetooth moves ~182 bytes per GATT notification.** It is for small files.
- **iOS cannot receive in the background over WebRTC.** Keep the screen on.
- **LAN traffic is plain HTTP.** The bearer token is in the QR code and the
  bytes are not encrypted on the local network. Proper fix is a self-signed
  certificate pinned through the QR code; not done yet.

---

## Building

```bash
flutter pub get
flutter test
flutter analyze
```

```bash
flutter build apk --release --split-per-abi   # 40 MB arm64, vs 102 MB universal
flutter build appbundle --release             # what Play wants
flutter build macos --release
flutter build ios --no-codesign
```

R8 is deliberately off. The release APK is 94% native `.so` libraries across
three ABIs and 2% dex, so minification moved the total from 101.9 MB to
102.1 MB while adding a failure mode that only appears at runtime. Size is
solved by shipping one ABI per device. `android/app/proguard-rules.pro` is kept
for whenever someone can validate it on a real device.

### Android release signing

Signing material comes from environment variables (CI) or `android/key.properties`
(local), in that order. With neither, the release build is **unsigned** rather
than falling back to the debug certificate. Copy `android/key.properties.example`
and fill it in; the file is gitignored.

### Configuration

| dart-define | Default | Purpose |
|---|---|---|
| `QUICKSHARE_TURN_URL` | `turn:standard.relay.metered.ca:80` | Base TURN host, expanded into TCP/443, TLS/443, TCP/80 and UDP |
| `QUICKSHARE_TURN_HOSTS` | — | Extra TURN hosts, comma separated |
| `QUICKSHARE_TURN_USER` / `_PASS` | `openrelaymodule` | TURN credentials. **Not verified as working** — supply your own |
| `QUICKSHARE_RELAY_LIMIT` | `52428800` | Relay transfer ceiling in bytes; `0` disables |

STUN is a pool rather than one host: measurements from the target network
disagree with each other depending on whether a VPN is up, so no single server
is reliable across the user population.

---

## Layout

```
lib/
├── core/
│   ├── crypto/      bip340.dart — Schnorr signatures, for Nostr events only
│   ├── network/     local_hotspot_service.dart, peer_link_service.dart,
│   │                session_tls_identity.dart
│   ├── signaling/   answer_channel.dart, nostr_answer_channel.dart,
│   │                sealed_envelope.dart, serverless_qr.dart
│   ├── webrtc/      compact_sdp.dart, ice_gathering.dart, ice_servers.dart
│   └── router/, theme/, di/, errors/, permissions/, utils/
├── features/
│   ├── sender/      indexer, local_http_server, transports, sender_bloc
│   └── receiver/    qhtp_receiver_client, transports, session store, receiver_bloc
└── shared/          models, widgets
```

---

## Licence

MIT.

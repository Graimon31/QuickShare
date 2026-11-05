# DirectDrop

Peer-to-peer file transfer between macOS, iOS, Android, Windows and Linux, with
no account and no cloud storage: your files go from one device to the other and
are never stored on a server. One device shows a QR code and a ten-digit code;
the other scans the QR (a phone) or types the digits (a computer), and the bytes
go directly between them. There is no list of devices to pick from: a
connection is made with a code, or not at all. The few things that are not the two
devices themselves — public Nostr relays, a small Cloudflare Worker and TURN
relays — are listed, with what happens when each is missing, under
[Infrastructure](#what-needs-public-infrastructure).

> Renamed from QuickShare in August 2026. "Quick Share" is the name Google and
> Samsung use for their built-in system feature, and shipping under it would be
> a trademark conflict rather than a naming preference.

---

## Download

Release builds live on the
[Releases page](https://github.com/Graimon31/QuickShare/releases); checksums in
`SHA256SUMS` beside them.

| Platform | File | First-run notes |
|---|---|---|
| **Windows** | `DirectDrop-windows-setup.exe` | SmartScreen warns (the build is not code-signed): "More info" → "Run anyway". `DirectDrop-windows-portable.zip` is the no-install alternative. |
| **macOS** | `DirectDrop-macos.dmg` | Drag DirectDrop to Applications. Not notarized: right-click → Open on first launch, or `xattr -dr com.apple.quarantine /Applications/DirectDrop.app`. |
| **Linux** | `DirectDrop-linux-x64.tar.gz` | Extract and run `./directdrop`. Needs GTK 3; x86-64 only. |
| **Android** | `DirectDrop-android-arm64-v8a.apk` | Right for virtually every phone since 2017; `armeabi-v7a` covers old 32-bit devices, `x86_64` emulators and Chromebooks. Allow the installing app once. |
| **iOS** | — | No public build: any channel needs a paid Apple Developer account. Until then `tools/deploy_ios.sh` puts a development build on a device the developer's Mac can see. |

---

## What it does

| Transport | When it is used | Speed |
|---|---|---|
| **QHTP over Wi-Fi/LAN** | Both devices on one network | Bounded by Dart's TLS stack, not the link: 72 MB/s receiving over loopback in `benchmark/README.md` (2021 M1 Pro); a real link is slower |
| **Serverless WebRTC** | Different networks, over the internet | Depends on the path; 27 MB/s over loopback (`docs/specs/2026-09-23-performance-review.md`). A relayed route is the slowest |
| **Direct Wi-Fi link** | No shared network: one device raises a hotspot, or two Apple devices use Apple's peer-to-peer Wi-Fi | The same QHTP protocol over whatever link comes up; not benchmarked |
| **Bluetooth LE** | No network at all; the receiver scans the sender's QR code, so it is a phone. Sends from macOS, iOS, Android, Windows and Linux (see [Bluetooth](#bluetooth) for what has been tried on devices) | Bluetooth only finds the other device and sets up a direct Wi-Fi link; the file crosses that link, not Bluetooth |

Folders are transferred whole, with their structure. A transfer over QHTP —
local network, hotspot, peer-to-peer link, and a Bluetooth-started link — resumes
from the exact byte after an interruption; a WebRTC transfer has no resume and
starts again. QHTP verifies each file before it is published under its real
name (byte count always, SHA-256 when a digest is available), and the WebRTC
receiver checks the byte count of each item. See
[On the receiving disk](#on-the-receiving-disk).

### The home screen

Two ways to send, and receiving as an action of its own:

- **Over the internet** opens the file screen for the serverless WebRTC
  transfer. It works from any network.
- **AirDrop** is not a transport. Tapping it opens two buttons under it, and
  tapping it again closes them. **Local network transfer** is QHTP over
  Wi-Fi/LAN: both devices must be on the same network. **AirDrop alternative**
  is the Bluetooth-started direct Wi-Fi link (see [Bluetooth](#bluetooth)): it
  needs no shared network, and the receiving end is a phone. Nothing here
  speaks Apple's AirDrop protocol; the name says what kind of transfer to
  expect (device to device, close together), not what it is compatible with.
- **Receive File** sits below both and chooses no transport: the sender's QR
  code or ten digits decide the path, so it opens the digit entry on a computer
  and the scanner on a phone.

The way to send is therefore chosen on the home screen, and the file screen
(`/send?mode=internet`, `wifi` or `bluetooth`) only asks what to send. A
transport that cannot run (Bluetooth off, no local network, no connection at
all) is refused at its button, before any file has been chosen. The file screen
checks again before its file dialog opens and before any session is started,
which is the only check a dropped file gets. An
address without a recognisable `mode` goes back to the home screen. On a
computer a file can be dropped on the **Over the internet** card, which sends
it over the internet, or on the **AirDrop** card and its buttons, which send it
over the local network.

---

## How a transfer actually works

### QHTP over the local network

The sender indexes the selection into a manifest, starts an **HTTPS** server on
the first free port in 8000–9000, and shows a QR code carrying its address, a
per-session bearer token, the session id and `tf` — the SHA-256 fingerprint of
the certificate the server uses. That certificate is generated fresh for every
session (ECDSA P-256, self-signed, valid for one day) and is trusted for exactly
one reason: it is the one the QR promised. The receiver pins the fingerprint,
checks no chain and no hostname, and refuses a code that has none rather than
falling back to an unencrypted connection. It then fetches the manifest and pulls items in
order.

Per item: `GET /v2/files/<id>` with `Range` for resume, written to
`<name>.qs.partial`, three retries, then **verified and only then renamed**.
Verification checks the byte count always, and a SHA-256 digest when one is
available: the sender hashes the bytes as it serves them and offers each item's
digest at `GET /v2/files/<id>/digest`. The manifest itself carries digests inline
only for sessions up to 2 GB, because hashing 500 GB before the QR appears would
look like a hang.

The other way to start the same session on the local network is the code:

- **Code entry.** The sender shows a ten-digit code; the receiver types it. Only
  once all ten digits are in does the receiver look for candidate senders on the
  local network, and it runs SPAKE2 (P-256) with each, with the code as the
  password and the certificate fingerprint it was actually served as the
  sender's identity. The code is never sent. Only a device that holds the code
  and the private key of the certificate it presented produces a confirmation
  that verifies; the session is then pinned to that proven fingerprint, and the
  sender's person is asked to approve. No sender, a wrong code, an expired code
  and a different network all look the same to the receiver — one "not found"
  answer.
- **What is on the network, and when.** A device that is not showing an offer
  says nothing at all, and a receiver never says anything. While a Wi-Fi offer is
  on a sender's screen it announces itself over mDNS (`_directdrop._tcp`) with
  a random instance name, its port, a protocol version and one byte of the
  code's hash (`ch`) — no device name, no address, no fingerprint, no token. The
  byte only lets a receiver who already has the code skip most of the machines
  in range; it proves nothing, and the code is still proved to the device it is
  dialled on. The announcement stops when the offer does. A receiver browses
  only after a whole code has been typed, and what it hears is never shown.

### Codes change every 5 minutes

Whatever a sender shows — the digits and the QR — is replaced
every 5 minutes (`AppConstants.sessionCodeLifetime`) for as long as the screen
stays up, with the time left counted down beside it. The old code and QR stop
working at that moment.

- **Wi-Fi.** A new code and a new bearer token, a new QR, a new mDNS name and
  hint; the server, its port, its certificate and the indexed files stay. A
  proof of the old code that was begun and not finished is dropped. A token that
  has authenticated a request, or was handed to a receiver the sender's person
  approved, stays valid until the session ends, so a transfer in progress — and
  its resume a minute later — is not cut off. A QR that was never used simply
  stops working.
- **Not in the middle of something.** Rotation waits while an approval dialog is
  open and happens right after it is answered, and it stops for good once a
  transfer has started. After the machine slept or the app was in the
  background, the deadline is checked against the wall clock on return, so a
  stale code is replaced at once; on a phone the server is also asked whether it
  still answers, and the offer starts over if the system took it away.
- **Internet.** An offer nobody has answered is replaced by a fresh one (new
  seed, new rendezvous topic, new QR, a new ten-digit code and with it a new
  request topic) and the old peer connection and subscriptions are closed; the
  old code is answered by nobody from that moment. It waits while a dialog is
  open and for 60 seconds after a receiver was let in; if no answer comes in
  that time it is replaced as usual. Once an answer has arrived it is left
  alone, and the code stops answering anyone else.
- **Bluetooth.** The advertisement is restarted under a new locator and a new
  token. It is left alone while a receiver is connected or connecting.
- **Hotspot.** The transfer QR is replaced; the network and the Wi-Fi code that
  joins it last as long as the hotspot does.

### Serverless WebRTC over the internet

Both peers are usually behind NAT that will not accept an unsolicited packet,
and the desktop has no camera, so there is no reverse visual channel. The offer
therefore travels one way — in the QR code — and the answer comes back out of
band:

```
desktop                                        phone
  │ createOffer, gather ICE                      │
  │ CompactSdp: 6-8 KB SDP -> ~100-250 bytes     │
  │ QR = "QS1" + seed(16B) + offer               │
  │ subscribe to topic = HKDF(seed)  ────────┐   │
  │                                          │   │ scan
  │                                          │   │ createAnswer
  │                                          │   │ seal with ChaCha20-Poly1305,
  │                                          │   │ key = HKDF(seed), AAD = SHA-256(offer)
  │                                          │   │ publish to the same topic
  │ <──── sealed answer ─ Nostr relays / Worker ─┘
  │ open, setRemoteDescription                   │
  └───────── DataChannel, file in chunks ────────┘
```

### Finding an internet sender by its code

An internet offer shows a ten-digit code beside its QR, the same way a Wi-Fi
offer does, and a computer — which has no camera — types it. The receiver's one
code screen looks for the code on the local network and over the internet **at
the same time**, because the code does not say which kind of offer it belongs
to. Whichever search proves the code first wins and the other is stopped and
released; a receiver tells its name to at most one of them. A code is made fresh
for the internet offer and has nothing to do with any local-network code.

The mailbox is public, so the code is never put into anything the public can
test. What a relay or the Worker sees is, in order:

```
receiver                                              sender (listening on T)
  n (16 B), replyTopic;  subscribe replyTopic
  {v, n, pA, reply, ts}  ── T ───────────────────────►  SPAKE2 with its code
                                                        subscribe confirmTopic
  ◄───────────────────────────────  {pB, cB} ── reply ──
  check cB: wrong → ignore, keep listening
  subscribe payloadTopic
  AEAD{cA, name} ─ confirmTopic ─────────────────────►  check cA
                                                        a person is asked
  ◄──────── AEAD{offer} or AEAD{declined} ─ payloadTopic
```

- **`T`, the request topic, reveals 12 bits of the code and nothing more.** It
  is HKDF of 12 bits of a domain-separated hash of the code, spelled like every
  other topic (22 characters). At most 4096 topics exist, so many unrelated
  sessions share each one; a topic cannot tell two codes with the same 12 bits
  apart. Ten billion codes hashed into a topic would be searched in seconds, so
  no topic carries more. The sender announces no `publicId` and no `ch` for an
  internet offer, anywhere.
- **The proof is SPAKE2 (P-256), as for the local network**, with the code as
  the password and both identities carrying the domain
  `directdrop-internet-code-v1` and the request's nonce `n`. `pA`, `pB` and the
  confirmations are what the public sees; none of them can be tested against a
  guessed code without the other end's private scalar, so a guess costs one
  online run. A point that is not on the curve is refused.
- **Everything after the proof is sealed.** HKDF over `Ke` and `n` gives the
  ChaCha20-Poly1305 key and the two topics only a holder of the code can name
  (`confirmTopic`, `payloadTopic`). The receiver's name and the offer travel
  only inside AEAD messages whose associated data names the message kind and
  `n`, so one cannot be replayed as another or into another run.
- **Nothing is handed over until a person says yes.** After the sender checks
  `cA` it shows the same approval dialog as on the local network, with the name
  the receiver gave — text from the public mailbox, shown as data with control
  and direction characters removed. 90 seconds, or it is a refusal; the
  receiver then sees "Declined". On yes, the sender publishes the offer — the
  string its QR holds — and the receiver goes on exactly as after a scan: the
  usual preview, then the usual sealed answer keyed by the seed in that offer.
- **Each side listens before it provokes a reply**, because Nostr keeps nothing
  for a subscriber that was late; the Nostr channel waits for the relay's
  `EOSE` before it calls a subscription live. Both channels carry every
  message; the first copy wins, repeats are dropped, and a failure or a `429`
  on one never stops the other. If both are down the receiver says it cannot
  reach the internet service rather than that the code is wrong.
- **What the sender will not do.** It drops a request older (or later) than 2
  minutes, one whose nonce it has seen (the Worker keeps the last value for 30
  minutes), anything over its size bounds before parsing, and anything that is
  not exactly the format. It runs at most one SPAKE2 a second and 30 for a
  code; after that it answers nobody until the code is replaced, and says so in
  its log. A wrong confirmation gives nothing back. Only one dialog is open per
  code; a second receiver is refused.
- **Timeouts, each its own:** the receiver gives up looking after 20 seconds,
  waits up to 95 seconds for the person, and takes a silent sender after proof
  for "could not reach that device"; the sender waits 30 seconds for a
  confirmation after replying. On the Worker the sender reads each room every 5
  seconds, not the 2 the sealed answer uses, because this one stays open for
  minutes.
- **What a relay or the Worker operator learns:** that an address looked for a
  topic of 12 bits at some time, the receiver's `pA`, and later the sizes and
  times of sealed messages. Not the code, the name, the file name or the offer.
  A receiver does this for **any** code it is typed, including one belonging to
  a sender on its own network, so the 12 bits of a local code are visible to
  those operators too (see Known limitations).

**What has been checked.** Unit and widget tests run the real sender, the real
search and the real cryptography over an in-memory mailbox that loses a message
for a subscriber that was late, repeats, delays and reorders messages, drops one
of two channels and forges messages. The Nostr and Worker channels are tested
against local stand-ins for a relay and for `/r/:roomId`, not against the
services themselves. `integration_test/code_internet_e2e_test.dart` moves a file
over a real WebRTC connection after a code was typed (macOS, not part of CI), and
`integration_test/live_code_rendezvous_check.dart` runs the exchange against the
real relays and the real Worker and prints the delay of each step; it is run by
hand and no result of it is recorded in this repository. Nothing has been run
between two physical devices.

`QS1` is seed plus offer. `QS2` additionally carries the file name (clipped to
80 bytes), the size and the item count, so the receiver can show what is coming
before the DataChannel opens. They travel in the QR code; when the offer is
found by its code they also cross the mailbox, but only inside the sealed
hand-over above, never in the clear.

The answer is published to two kinds of drop point **at the same time**, and
whichever delivers first wins; the other copy is dropped as a duplicate:

- **Nostr relays** — five public relays by default, reached over WSS on 443, so
  the rendezvous is indistinguishable from an HTTPS session. Events use the
  ephemeral kind 20000, which relays forward to current subscribers and never
  store. Relays do not gossip between themselves, so both sides fan out across
  the whole list.
- **The DirectDrop Worker's mailbox** (`POST`/`GET /r/<topic>`) — a blind
  key-value slot that holds the sealed blob for 30 minutes. The sender polls it
  every two seconds. The Worker cannot tell the answer from anything else
  stored there; the sender ignores a payload that does not open under its seed.

Either channel is enough on its own. The payload is the compacted answer plus 28
bytes of nonce and tag, sealed under a key the relay or the Worker never sees,
so neither learns the ICE credentials, the candidate addresses or the DTLS
fingerprint. They do see, as any server does, that an address connected and
roughly when.

### Direct Wi-Fi link (hotspot and peer-to-peer)

When there is no shared network — or the internet path is blocked, a VPN holding
the default route or a symmetric NAT being the usual causes — the sender's
fallback screen offers to create a network. Android, Windows and Linux can host
one (on Linux the adapter has to support it); macOS and iOS cannot, though both
can join one (macOS through CoreWLAN, iOS through `NEHotspotConfiguration`).
Two codes in sequence: a standard `WIFI:` payload the other phone's system
camera understands (no app needed for that step), then the ordinary transfer
locator. Over this route iPhone-to-iPhone needs Personal Hotspot turned on by
hand.

Between two Apple devices that can neither host nor be hosted, a Bluetooth-
started session falls through to Apple's peer-to-peer Wi-Fi link instead (the
radio AirDrop uses). It is exposed as a loopback port, so the receiver pulls
from `127.0.0.1` and the transfer cannot tell what carried it.

### Bluetooth

Bluetooth is the rendezvous and nothing more, and **no file ever crosses it**:
the decision is that a file does not travel over plain Bluetooth at all. The
sender shows a QR code and advertises; the receiver scans the code, connects to
the sender it names, and over a GATT service the two agree which of them raises
a Wi-Fi network (the sender if it can, otherwise the receiver; two Apple devices
use the peer-to-peer link above). The receiver then pulls the files from the
sender over ordinary QHTP/HTTPS on that network. A sender running this version
puts no file bytes on Bluetooth and refuses a receiver too old to build the
link, telling the person to update it; a receiver running this version does the
same to an older sender that still pushes bytes, and writes nothing it sends.
With Wi-Fi switched off the session stops with "Wi-Fi is turned off. The
transfer builds a direct Wi-Fi link between the devices, so it cannot start
without it."

**Bluetooth is joined by the QR code and by nothing else, which makes the
receiver a phone.** Neither side lists devices: a receiver does not advertise
itself to be picked, and a sender does not scan for or show the devices around
it. Scanning needs a camera, so a phone receives over Bluetooth and a computer
does not. A computer receives with the code, on the local network or over the
internet, and it can still *send* over Bluetooth to a phone. The Bluetooth
screen shows the QR and nothing to type: there is nowhere to type a code into a
Bluetooth session.

#### What each sender puts on the air

| Sender | Implementation | Advertised |
|---|---|---|
| macOS, iOS | CoreBluetooth bridge (Swift) | Service UUID and the name `QuickShare-` plus the session's eight-character locator |
| Linux | BlueZ over D-Bus | The same |
| Android | `universal_ble` peripheral mode | **The service UUID only** |
| Windows | `universal_ble` peripheral mode (`GattServiceProvider`) | **The service UUID only** |

Android and Windows advertise no name. A legacy Bluetooth packet holds 31 bytes;
the flags take three, a 128-bit service UUID takes 18, and the name would take
21 more, which Android refuses with `ADVERTISE_FAILED_DATA_TOO_LARGE`. The
plugin can move the UUID into the scan response so that the name fits, but both
receivers scan with the UUID as the filter, and a filter that has to look inside
a scan response is one more way not to be found; setting a name also renames the
phone's own Bluetooth name while the advertisement lasts. Windows cannot set a
name at all. A receiver accepts a sender with no `QuickShare-` name, because the
service UUID shows it is a DirectDrop sender and the `START:<token>` write after
the connection is what shows it is the one the QR named; a sender that does
advertise a `QuickShare-` name has to carry the scanned session's locator.

**The locator and the token are random, and nothing on the air is derived from a
session code.** Both are drawn from a cryptographic source for each session —
that is, each time the QR changes — and they are tied to nothing: not to each
other, not to the code that names the Wi-Fi network, not to the network's name.
They reach the receiver in the QR and nowhere else. The link directive carries no
digits, the sealed credentials are bound to the locator the QR holds, and the
Bonjour name of an Apple peer-to-peer link is made from it too. Until protocol
generation 5 the advertised name was a hash of the code, which anyone in range
could search for the code in seconds (the code is about 33 bits); the directive
carried the digits themselves; and the token was a hash of them.
With two Android or Windows senders in range, a receiver connects to whichever
it hears first — and the one it was not meant for refuses the wrong token. The
Android and Windows senders register their GATT service once per process and
only start and stop the advertisement, because `universal_ble` on Android keeps
the first characteristic objects it builds and never drops them.

A sender that asks the platform to advertise waits for the platform to say it
is advertising, and reports Bluetooth being off, a refused permission, an adapter
that cannot act as a sender, or the platform's own reason for a failed
advertisement — and not answering within ten seconds — as an error on the
sender's screen.

Android needs the Bluetooth permission (`BLUETOOTH_ADVERTISE` on Android 12 and
later, declared in `AndroidManifest.xml`); Windows needs an adapter that
supports the peripheral role, which not every adapter does.

**What has and has not been tried.** The Apple senders are the path that has
been used on devices. The Android and Windows senders are complete in code and
tested against a simulated radio (`test/features/sender/ble_sender_*`), which
checks what is asked of the platform and how the sender answers, and does not
prove that a particular phone or adapter will advertise it or that an iPhone
will find it. They have not been run between two real devices. Two things in
particular wait for that: whether the hosting directive an Android or Windows
sender writes (about 220 bytes) fits in one notification to an iPhone, which
negotiates a 182-byte payload — a frame that does not fit is refused with an
error, and the optional fields of the serve frame are dropped to make it fit,
but the directive cannot be shrunk — and whether a given receiver finds an
advertisement that carries no name.

---

## What works with no configuration

A build with no `--dart-define` at all does these without any internet and
without any third party in the path: local-network transfer by QR code and by
code entry; the hotspot; Apple's peer-to-peer link;
and the Bluetooth-started link. They need only the two devices and, for the
Wi-Fi ones, a radio that is on.

## What needs public infrastructure

Only the **internet (WebRTC) transport** does. This section and the next
describe the code in this repository; the Worker side (`cloudflare-worker/`)
applies once that code is deployed, and nothing here says what the production
deployment runs at any moment.

| Dependency | What it is for | If it is unavailable |
|---|---|---|
| **STUN pool** — five public hosts (Cloudflare, two Russian, two Google) | Learning each side's public address | No server-reflexive candidates. Gathering gives up waiting after 6 s and goes ahead with what it has: a path that needs none (the same network) can still work; one that needs a public address cannot |
| **Nostr relays** — five public relays | One of the two ways the sealed answer returns, and one of the two ways a typed code finds an internet sender | The Worker mailbox carries it |
| **The Worker mailbox** (`/r/<topic>`) | The other way both go | The Nostr relays carry it |
| **Both of the above** | — | The sender stops before it shows a QR code and a code that would lead nowhere: "Could not start the transfer over the internet." (the log adds "No public rendezvous channel could be reached. Check the internet connection and try again."). A receiver who types a code then sees "Could not reach the internet service, and no sender was found on the local network…" instead of "not found" |
| **The Worker's `POST /turn`** | Short-lived (30 minute) TURN credentials from Cloudflare Calls TURN, and from Metered when the Worker is configured with it | No relay credentials. The session goes ahead with STUN only — or with a private TURN account if the build was given one (see Configuration). A direct path is unaffected. If the direct path then fails (a VPN, a symmetric NAT) the connection ends with a specific message, below |
| **A TURN provider** | Carrying the bytes when no direct path exists | The Worker answers `provider_error` and the same "relay could not be reached" message appears |

When ICE gives up, the message says why there was no relay, rather than one
sentence for every cause:

| What happened to the relay | What the person is told |
|---|---|
| The Worker is limiting requests (`429`, or its limiter is down) | "…the relay service is limiting requests right now. Try again in about a minute." |
| The Worker or the provider could not be reached, timed out or answered nonsense | "…the relay service could not be reached. Check the internet connection." |
| The relay is switched off, not configured at the Worker, or the build names no Worker | "…the relay is switched off or not configured in this build." |
| A relay was available and it still failed | "Could not connect even though a relay was available. Something between the devices is blocking the connection — a VPN or a firewall, for example." |

On the sender the same reason appears on the "No direct route to the other
device" screen, which says nothing was sent and offers the local network or a
network of its own. The credentials request waits at most five seconds. A
credential is good for 30 minutes; during a long transfer the app asks for new
ones about five minutes before expiry and hands them to the live connection, so
a long relayed transfer can outlive the first set.

### The Worker

The app ships with a Worker address compiled in (`QUICKSHARE_WORKER_URL`; see
Configuration). Using the Worker needs no account and no sign-up. What it holds
and sees:

- `POST /turn` hands out relay credentials. It sees the requester's IP address,
  as any web server does.
- `/r/<topic>` stores a blob of at most 8 KB for 30 minutes, under a topic id:
  derived from the seed in the QR code for the sealed answer, and for finding a
  sender by its code a request topic (shared by everyone whose code has the same
  12 bits), a random reply topic, and two topics only the two ends can derive.
  The code exchange's first two messages are not secret (a SPAKE2 share and a
  nonce); everything after is sealed. It never holds file bytes, and it cannot
  read what is sealed. One room holds one value and the last write wins, so two
  receivers asking for codes that share a request topic at the same moment can
  overwrite each other; the one that loses finds nothing and tries again.
- The Worker's own log lines carry the route, the limit that was hit and the
  status — not client addresses, topic ids or credentials.
- File bytes never touch it. A relayed transfer's bytes pass a TURN provider as
  DTLS ciphertext, and the provider bills the project for them, which is what
  the relay cap below is for.

`QUICKSHARE_WORKER_URL=` (empty) opts out of the Worker entirely: the answer
travels by Nostr only and the relay comes from build-time TURN settings or not
at all.

---

## Encryption, per transport

| Transport | What protects the bytes | What vouches for the other end |
|---|---|---|
| **QHTP** (LAN, hotspot, peer link, Bluetooth-started link) | HTTPS with the per-session P-256 certificate, plus a bearer token on every route except `/v2/health`, `/v2/pake/start` and `/v2/invite/request` | The pinned certificate fingerprint. Where it comes from decides how far that goes — see the next table |
| **Code entry, local** | The same HTTPS | SPAKE2 with the code as the password, bound to the certificate fingerprint actually served; the code is not sent |
| **Code entry, internet** | ChaCha20-Poly1305 under a key from the SPAKE2 `Ke`, for the receiver's name and the offer; then DTLS as above | SPAKE2 with the code as the password, bound to a per-run nonce, through a public mailbox that is trusted with none of it |
| **WebRTC** | DTLS on the DataChannel. DirectDrop adds no second layer of its own to the file | The DTLS fingerprint of the offer travels in the QR code; the answer, which carries the other fingerprint, is sealed under a key derived from the seed in the QR code, with the offer's SHA-256 as associated data so an answer cannot be replayed into a later session |
| **Bluetooth** | Nothing, at the Bluetooth layer: the GATT service is not bonded and its characteristics are not encrypted. The hotspot credentials an Android or desktop host offers are sealed (X25519 key exchange, ChaCha20-Poly1305). The file does not cross Bluetooth | See Known limitations |

The fingerprint a QHTP receiver pins is only as trustworthy as the channel that
delivered it:

| Where the fingerprint came from | How it was delivered | Against what |
|---|---|---|
| The QR code | Through the camera | Strong: it is what the person is looking at |
| Code entry | Proven through SPAKE2 | Strong, up to the guessing limits below |
| Code entry, internet | An offer sealed under the proof's key, from a sender that passed it | The same strength as code entry: a guess is one online run, counted by the sender |
| A Bluetooth-started link | An unencrypted GATT frame | Passive listeners at best |

---

## Limits and abuse protection

**The Worker.** Both routes are public and are capped per 60 seconds with
Cloudflare's rate-limiting bindings (`cloudflare-worker/wrangler.toml`):

| Route | Per client IP | All clients together (per Cloudflare location) |
|---|---|---|
| `POST /turn` | 20 | 300 |
| `POST /r/<topic>` | 10 | 60 |
| `GET /r/<topic>` | 120 | — |

Over a limit the Worker answers **429** with `Retry-After: 60`. If its limiter is
missing or failing, `/turn` answers 503 (`limiter_unavailable`) and issues
nothing, while `/r` carries on; if the key-value store refuses a call (its daily
quota is spent) `/r` answers 503 with `Retry-After`. The app takes the header at
its word, capped at five minutes: a mailbox poll waits as told and keeps
polling, publishing makes three attempts, and the credential refresher waits a
minute when none is named and keeps going for about ten waits. A throttled relay
shows as "limiting requests right now. Try again in about a minute", above. These
limits apply once this version of the Worker is deployed.

**Guessing the code.** On the sender, the first round of the code exchange is one
guess for whoever sent it. It is limited to 5 a minute per address and 30 a
minute for the whole session; past that the sender answers **429**
(`RATE_LIMITED`, with no `Retry-After` header on this route). At most 16
exchanges can be open at once, each for 30 seconds, after which it answers 503
(`BUSY`). A person has 90 seconds to approve a request that proved the code. The
code is ten digits, a little over 33 bits.

**Guessing the code over the internet.** Each request to the sender is one
guess for whoever made it. The sender answers at most one a second and 30 per
code, at most 8 exchanges wait for a confirmation at once (30 seconds each), and
a request older than 2 minutes or with a nonce it has seen is dropped without
being counted. After the 30th the code answers nobody until it is replaced, at
most 5 minutes later. That also means anyone who knows a code's request topic
— 12 bits, so 4096 values — can use up its 30 attempts and lock the real receiver
out for the rest of the code's life; the sender sees nothing but a burnt
budget. A sender's Worker use is two writes per exchange (10 a minute per IP
allowed), and reads 12 a minute per open topic.

**Relayed transfers.** A TURN relay is used only when ICE finds no direct path.
Once the connection is up, and before sending anything, the sender asks which
candidate pair was selected. If it is relayed — or cannot be told apart from
relayed, because the statistics came back empty — and the whole session is
larger than the cap, **nothing is sent** and the sender gets "Too large for this
connection" with the local network as the way out. The cap is **2 GB**
(`QUICKSHARE_RELAY_LIMIT`, in bytes; `0` removes it); a direct path has no such
limit and is bounded only by the protocol (100 GB per file, 500 GB per session,
100,000 files). Relayed traffic is slow; no figure for it has been measured here.

---

## On the receiving disk

- **Space is checked before the first byte.** The receiver needs the bytes still
  to come plus a 64 MiB margin; on a resume only what is left counts. Too little
  and the transfer is refused with both sizes — "Not enough free space: X
  needed, Y available". macOS, iOS and Android ask the platform, Linux runs `df`,
  Windows calls `GetDiskFreeSpaceExW`.
- **"Unknown" is neither enough nor short.** Where no probe exists, or it fails or
  times out, the check is skipped, the transfer goes ahead, and the log says that
  no check happened. If the disk fills anyway, the operating system's error is
  recognised and reported as "The disk filled up while saving" rather than as a
  generic failure.
- **A link is never followed.** Inside the destination folder no write goes
  through a symbolic link — including one that points back inside it — or through
  a plain file where a folder must be. The transfer stops with "The save folder
  has a shortcut (a symbolic link) where a file or folder should be, so nothing
  was written there." The folder the user chose may itself be, or sit under, a
  link (`/tmp` is one on macOS) and is resolved once.
- **Nothing existing is replaced.** A name that is taken, even by a dangling
  link, becomes `name (1).ext`. In flight a file is `<name>.qs.partial`, created
  exclusively; it is flushed to disk, renamed, and the directory flushed, before
  it is reported as received. A folder is staged whole and renamed in one step.
- **Resume re-checks what it is about to trust.** Before any byte is counted as
  received or skipped, each item the saved state calls complete is looked at on
  disk. Same size and the SHA-256 the sender gives (or the one recorded) matches:
  kept. If there is nothing to compare with, size and an unchanged modification
  time keep it, and the log says it is unverified. Gone: received again under
  its old name. Changed, not a regular file, or behind a link: received again
  beside it, never deleted or overwritten — it may be the user's own edit. A
  saved state is used only for the session and destination folder it was made
  for.

---

## Compatibility

- **Code entry needs the same generation on both devices.** A sender of this
  version answers a request that carries the code itself with **426**
  (`UPDATE_REQUIRED`) and does not read it; a receiver of this version that finds
  only senders without the new exchange reports that an update is required. New
  and old versions cannot use code entry together — update both.
- **The local network is HTTPS.** A receiver refuses a QR code without a
  fingerprint: "This code is from an older version that sends files unencrypted.
  Update the sending device." An older receiver connects without TLS and cannot
  talk to a current sender.
- **Bluetooth-started transfers need protocol generation 5 on both ends.** A
  sender of this version tells a receiver below it to update, at once, instead of
  sending it anything (that receiver sees the connection drop). A receiver of this
  version refuses a sender whose first frame still carries the code's digits —
  every generation-4 sender — and a sender that still pushes a file over
  Bluetooth, says so, and writes none of it. Neither case waits out the
  negotiation: both devices end with an error naming the update.
- **An older build that advertises itself to be picked is not listed by this
  version.** Nothing lists devices any more; scan the sender's QR instead.

---

## Honest limits

- **The internet transport depends on infrastructure nobody promises to keep
  running.** Public Nostr relays can disappear; the Worker is one more
  dependency, run by this project on a free tier with the limits above. Racing
  both makes a total outage unlikely, not impossible, and the local-network
  transports do not depend on any of it.
- **Relayed transfers are capped at 2 GB** (`QUICKSHARE_RELAY_LIMIT`), for the
  reason given above; the app offers the local network instead.
- **iOS cannot receive in the background over WebRTC.** Keep the screen on.
- **A WebRTC transfer cannot resume.** Only QHTP can.
- **The symbolic-link checks are checks of a path, made just before it is used.**
  Dart has no `openat` and no `O_NOFOLLOW`, so someone who can already write into
  the destination folder and wins a race measured in microseconds could redirect
  one operation. Partials are created exclusively and the whole chain is checked
  again before the final rename, which makes a stale or accidental link, and every
  ordinary trick by a sender, harmless — not an attacker who controls the folder.

### Known limitations (security)

Open, understood and not fixed. They are written down here so nobody has to
discover them.

1. **Names derived from the short code can be reversed offline.** The hotspot
   passphrase and the identifiers below derive from the ten-digit code by
   unsalted hashes, and the code has about 33 bits. One of them is still broadcast
   to anyone in radio range: the hotspot SSID where it is requested from the code
   (`DirectDrop-` plus six characters; Android may name its own network instead).
   Six characters are 30 bits, so reading one leaves about ten codes out of ten
   billion (a scan of all of them for six random codes left 9, 9, 11, 12, 12 and
   14), and the passphrase follows from each. Whoever sees it can try them in a
   minute and join the network. What they reach is a throwaway
   network with no internet on it: the transfer is behind the pinned certificate
   and a token that, for a Bluetooth session, is random and not derived from the
   code. The local-network announcement carries a one-byte hint that narrows
   nothing down, and the Bluetooth advertisement, the link directive and the
   peer-to-peer link's Bonjour name no longer carry anything derived from the code
   (see [Bluetooth](#bluetooth)).
2. **A Bonjour browser can still see that an offer exists.** While a Wi-Fi offer
   is on a sender's screen, anyone on the same network running a Bonjour browser
   sees an anonymous `_directdrop._tcp` service with a random name, a port and
   one byte of the code's hash. It carries no device name, address, fingerprint
   or token, and it disappears with the offer, but its existence is not hidden.
3. **Bluetooth frames are not encrypted.** Nothing at the Bluetooth layer
   encrypts or bonds them, on any sender — Android and Windows included. The
   `START:<token>` write, the link frame and the serve frame (token, certificate
   fingerprint, file name and size) cross as plain text; only the hotspot
   credentials are sealed. That seal holds against a passive listener. A device
   that substitutes its own key during the exchange is not addressed — what it
   would reach is the credentials of a throwaway network with no internet. Someone
   who can read the connection reads the session token, which is what authorises
   the pull: it is random, lasts as long as the QR does, and is of no use without
   also being on the same Wi-Fi network, but it is readable. It is not derived
   from the code, so it does not lead to it.
4. **A computer cannot receive over Bluetooth.** Devices no longer see each
   other: a receiver does not advertise its name and a Bluetooth sender shows no
   list. A Bluetooth session is joined by scanning its QR, which takes a camera,
   so it reaches phones. Typing the session's code does not join it — code entry
   looks for local-network and internet senders, not Bluetooth ones — so a
   computer receives with a code over Wi-Fi or over the internet. This is
   deliberate.
5. **The code is short.** What protects it is that the exchange is online-only
   (a captured SPAKE2 run gives nothing to test guesses against) and rate-limited
   as above. Limitation 1 is the way around that, which is why it matters.
6. **Typing a code tells the public mailbox 12 bits of it, whoever the sender
   is.** The receiver looks on the local network and over the internet at once
   and cannot know in advance which; the internet half publishes the request
   topic (12 bits of a hash of the code) and a SPAKE2 share. For a sender on the
   same network that is 12 bits the relay operators should not have had. They are
   independent of the 8-bit hint a local offer announces on the network, so
   someone who saw both the network announcement and the mailbox would know about
   20 bits of a code that has 33; the local server's rate limits still stand
   between that and the rest.
7. **An internet code can be burnt by anyone who knows its topic.** See the
   guessing limits above: a lock-out for the rest of the code's 5 minutes, not a
   way in.
8. **The mailbox can lose, repeat and reorder messages, and the Worker keeps
   one value per room.** The protocol never depends on one message arriving, and
   every step has a timeout and its own message, but a receiver whose request
   was overwritten sees "not found" after 20 seconds and has to try again.

---

## Building

```bash
flutter pub get
flutter test
flutter analyze
```

```bash
flutter build apk --release --split-per-abi   # 37.6 MB arm64, vs 102.1 MB universal
flutter build appbundle --release             # what Play wants
flutter build macos --release
flutter build windows --release
flutter build linux --release
flutter build ios --no-codesign
```

R8 is deliberately off. The release APK is 94% native `.so` libraries across
three ABIs and 2% dex, so minification moved the total from 101.9 MB to
102.1 MB while adding a failure mode that only appears at runtime. Size is
solved by shipping one ABI per device. `android/app/proguard-rules.pro` is kept
for whenever someone can validate it on a real device.

### Android release signing

Signing material comes from environment variables (CI) or `android/key.properties`
(local), in that order: `QUICKSHARE_KEYSTORE`, `QUICKSHARE_KEYSTORE_PASSWORD`,
`QUICKSHARE_KEY_ALIAS` and `QUICKSHARE_KEY_PASSWORD`, or `storeFile`,
`storePassword`, `keyAlias` and `keyPassword` in the file. Copy
`android/key.properties.example` and fill it in; the file is gitignored.

With neither, a release build **fails** ("No release signing configured")
rather than shipping unsigned or falling back to the debug certificate. Setting
`ALLOW_UNSIGNED_RELEASE=1` builds an unsigned release on purpose; CI does that
only for pull requests, which cannot read the signing secrets. A tag build in CI
fails without the keystore. Debug builds are unaffected.

### Configuration

Every `--dart-define` the app reads. A test (`test/docs/readme_claims_test.dart`)
fails if this table and the code drift apart.

| dart-define | Default | Purpose |
|---|---|---|
| `QUICKSHARE_WORKER_URL` | `https://directdrop-worker.directdrop-worker.workers.dev` | The Worker: relay credentials (`POST /turn`, public — no secret) and the reserve rendezvous mailbox. Empty turns the Worker off entirely |
| `QUICKSHARE_RENDEZVOUS_CHANNELS` | `nostr,worker` | Which channels may carry the sealed answer. They race and the first delivery wins. Both devices must name a channel in common; used to isolate one channel in a field test. The `worker` channel also needs a Worker URL |
| `QUICKSHARE_TURN_URL` | — | One TURN host, expanded into TCP/443, TLS/443, TCP/80 and UDP. Used only when the Worker supplies no relay |
| `QUICKSHARE_TURN_HOSTS` | — | Extra TURN hosts, comma separated, expanded the same way |
| `QUICKSHARE_TURN_USER` | — | Username for the TURN hosts above. No default: a release binary carries no public credentials |
| `QUICKSHARE_TURN_PASS` | — | Password for the TURN hosts above. No default; without both user and password the hosts are ignored |
| `QUICKSHARE_RELAY_LIMIT` | `2147483648` | Relay transfer ceiling in bytes (2 GB); `0` disables |
| `QUICKSHARE_FORCE_RELAY` | `false` | **Debug builds only.** Gather relay candidates and nothing else (`iceTransportPolicy: relay`), for the hand-run NET-02-B check in `integration_test/live_turn_relay_check.dart`. Ignored in profile and release |

A private TURN account in the three TURN defines is a fallback: it is used when
the Worker cannot be reached or supplies no relay, and not alongside the
Worker's.

STUN is a pool rather than one host: measurements from the target network
disagree with each other depending on whether a VPN is up, so no single server
is reliable across the user population.

---

## Layout

```
lib/
├── core/
│   ├── crypto/      bip340.dart (Schnorr, Nostr events only), hkdf.dart,
│   │                spake2.dart (code entry), link_secret.dart (sealed hotspot
│   │                credentials)
│   ├── network/     lan_discovery.dart, session_tls_identity.dart,
│   │                code_pake.dart, session_code.dart, local_hotspot_service.dart,
│   │                peer_link_service.dart, direct_link_coordinator.dart,
│   │                internet_code.dart, internet_code_sender.dart
│   ├── signaling/   answer_channel.dart, nostr_answer_channel.dart,
│   │                worker_answer_channel.dart, rendezvous_channels.dart,
│   │                sealed_envelope.dart, serverless_qr.dart,
│   │                code_mailbox.dart, nostr_code_mailbox.dart,
│   │                worker_code_mailbox.dart, code_mailbox_factory.dart
│   ├── storage/     safe_path.dart, durable_file.dart, disk_space.dart
│   ├── webrtc/      compact_sdp.dart, ice_gathering.dart, ice_servers.dart,
│   │                turn_credential_service.dart, turn_credential_refresher.dart
│   └── router/, theme/, di/, errors/, permissions/, utils/
├── features/
│   ├── sender/      indexer, local_http_server, transports, sender_bloc
│   └── receiver/    qhtp_receiver_client, code_lookup, code_session_resolver,
│                    internet_code_search, transports, session store,
│                    receiver_bloc
└── shared/          models, widgets
```

The Worker lives in [`../cloudflare-worker`](../cloudflare-worker/README.md).

---

## Licence

MIT.

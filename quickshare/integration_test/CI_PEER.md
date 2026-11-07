# Remote peer check: send by code from this Mac, receive on a GitHub runner

Checks the internet path by digit code between two machines that really are on
different networks, with nobody holding a phone. The sender is this Mac (under
the VPN it always has on, which makes its NAT behave as a symmetric one, so the
bytes are expected to go through TURN). The receiver is a GitHub-hosted macOS
runner.

Everything between them is real: the code exchange and the sealed answer go
through the real Nostr relays and the real DirectDrop Worker, the TURN
credentials come from the Worker, and both ends are the app's own classes.
Nothing is replaced in memory.

```
 this Mac                                      GitHub runner (macos-latest)
 ci_peer_sender.dart                           ci_peer_receiver.dart
   offers a random file under a code             types the code, announces CI_PEER_NAME
   accepts ONE receiver, by name                 takes the file
   writes the result                             checks size and SHA-256, writes the result
```

## The order

**1. On the Mac, start the sender and leave it running**

```sh
cd ~/Desktop/Share/quickshare
NAME=ci-peer-$(openssl rand -hex 3)        # the one receiver name it will accept
caffeinate -dimsu flutter test integration_test/ci_peer_sender.dart -d macos \
    --reporter=expanded \
    --dart-define=CI_PEER_EXPECT_NAME=$NAME \
    2>&1 | tee /tmp/ci_peer_sender.log
```

It builds, makes a random 50 MiB file, and prints one line when the code
answers requests:

```
CI_PEER_CODE=0123456789
```

then `CI_PEER_OUT=<path>` and `CI_PEER_JSON={...}`. It waits up to 40 minutes
for the receiver, counted from that line.

`caffeinate` keeps the Mac awake; leave the app window it opens visible and do
not close the lid. Do not turn the VPN off.

**2. Push a branch with `ci-peer/peer.json`** (from the repository root, in a
second terminal, as soon as the code is printed)

```sh
cd ~/Desktop/Share
git switch -c ci-peer/run-1                  # from the branch these files are on
mkdir -p ci-peer
grep -m1 '^CI_PEER_JSON=' /tmp/ci_peer_sender.log | cut -d= -f2- | jq . > ci-peer/peer.json
cat ci-peer/peer.json                        # {code, name, bytes, sha256}
git add ci-peer/peer.json
git commit -m "ci-peer: run 1"
git push -u origin ci-peer/run-1
```

The push starts `.github/workflows/ci_peer.yml`. It runs on a push to
`ci-peer/**` and on nothing else. Add `"forceRelay": true` to `peer.json` to
make the receiver gather relay candidates only (and start the sender with
`--dart-define=QUICKSHARE_FORCE_RELAY=true` for the same on its side).

**3. Look**

* Mac terminal, at the end: `CI_PEER ---- sender result ----` with the status,
  the path and the speed. The same as JSON in `CI_PEER_RESULT_JSON=...` and in
  the file `CI_PEER_OUT=` named.
* GitHub, Actions, "Remote peer check (receive over the internet)", the run
  for `ci-peer/run-1`: the run page shows the receiver's table, and the
  artifact `ci-peer-receiver-log-<n>` holds its whole log.

What each says:

| line | meaning |
|---|---|
| `status: success` (receiver) | size and SHA-256 matched what the sender made |
| `status: success` (sender) | the transport finished sending; whether the bytes arrived whole is the receiver's word |
| `ice_path` | `relayed` (through TURN), `peerToPeer` (srflx or prflx) or `direct` (host) |
| `ice_pair` | the candidate type on each end of the chosen pair, `local=relay remote=srflx`; `local` is the machine that prints it, so the two sides print the pair mirrored, and what one sees as `remote=prflx` the other may call `host` |
| `relay_policy` | `relay` when `QUICKSHARE_FORCE_RELAY` took effect, otherwise `all` |
| `find_attempts` (receiver) | how many times the code was typed before a sender answered |
| `refused` (sender) | names that asked and were not the expected one |

## Rules of the check

* **One code, one run.** The sender serves one receiver and stops. To run again,
  start the sender again (a new code) and push `ci-peer/run-2`. "Re-run all
  jobs" in Actions reuses the old code and fails.
* **The code does not change** for the whole wait. The app changes it every five
  minutes; this does not. What it does rebuild every five minutes, as the app
  does, is the offer (peer connection, relay candidates, sealed answer drop),
  under the same code. An offer held forty minutes would test credentials
  running out, not the app. `CI_PEER_OFFER_REFRESH_SECONDS` changes that
  (default 300).
* **The name is no password.** The code and the name are in a public
  repository. The sender accepts only the one name it was started with, only
  once, and the file is random bytes: this keeps out the device that was not
  meant, not the one that read the repository. Delete the branch afterwards
  (`git push origin --delete ci-peer/run-1`).
* After any integration run on macOS: `flutter build macos --debug`. The run
  replaces the app bundle with its own.

## Settings (`--dart-define`)

| define | side | default |
|---|---|---|
| `CI_PEER_EXPECT_NAME` | sender | required: the one name accepted |
| `CI_PEER_BYTES` | sender | 50 MiB (52428800) |
| `CI_PEER_OUT` | sender | `ci_peer_<code>.json` in the app's temporary folder; the path is printed. The macOS app is sandboxed: a path outside its container is refused (`~/Downloads` is allowed), and then the JSON is only on stdout |
| `CI_PEER_WAIT_MINUTES` | sender | 40, for the receiver to be accepted and to answer |
| `CI_PEER_TRANSFER_MINUTES` | both | 20, for the transfer once connected |
| `CI_PEER_OFFER_REFRESH_SECONDS` | sender | 300 |
| `CI_PEER_CODE`, `CI_PEER_NAME`, `CI_PEER_BYTES`, `CI_PEER_SHA256` | receiver | required; the workflow takes them from `peer.json` |
| `CI_PEER_FIND_ATTEMPTS` | receiver | 5 searches before giving up |
| `QUICKSHARE_FORCE_RELAY=true` | both | off; relay candidates only (debug builds) |

## Running the two halves on one machine

Two `flutter test -d macos` runs from one directory cannot be run at once (one
build directory, one app bundle). Run the receiver from a copy of the project:

```sh
rsync -a --exclude build --exclude .dart_tool ~/Desktop/Share/quickshare/ /tmp/qs-receiver/
cd /tmp/qs-receiver && flutter pub get
flutter test integration_test/ci_peer_receiver.dart -d macos --reporter=expanded \
    --dart-define=CI_PEER_CODE=... --dart-define=CI_PEER_NAME=... \
    --dart-define=CI_PEER_BYTES=... --dart-define=CI_PEER_SHA256=...
```

That checks the code, the name, the services and the bytes, but not that the
networks differ.

## Swapping the sides later

The workflow reads `peer.json` and the Dart halves are built from two pieces in
`ci_peer_support.dart` that know nothing about which machine they are on:
`CiPeerOfferHost` (offers a file under a code to one named receiver) and
`ciPeerReceive` (types the code and verifies what arrives). The runner sending
and a Mac receiving is two more thin `main`s over the same pieces, and a
workflow that publishes the code instead of reading it. None of that is built.

# Remote peer check: transfer by code between this Mac and a GitHub runner

Checks the internet path by digit code between two machines that really are on
different networks, with nobody holding a phone. One end is this Mac (under the
VPN it always has on, which makes its NAT behave as a symmetric one, so the
bytes are expected to go through TURN). The other is a GitHub-hosted macOS
runner. It works in both directions:

| direction | who sends | who receives | who picks the code and the file |
|---|---|---|---|
| `to-runner` (the default) | this Mac | the runner | the Mac's sender: a random code, a random file |
| `to-mac` | the runner | this Mac | the Mac, before anything starts: a random code, a seed that stands for the file |

Everything between them is real: the code exchange and the sealed answer go
through the real Nostr relays and the real DirectDrop Worker, the TURN
credentials come from the Worker, and both ends are the app's own classes.
Nothing is replaced in memory.

The same two programs do both directions, given different defines:

* `ci_peer_sender.dart` offers a file under a code to one named receiver. It
  makes up the code and the file, or, when it is given `CI_PEER_CODE` and
  `CI_PEER_SEED`, offers *that* file under *that* code.
* `ci_peer_receiver.dart` types the code, finds the sender, takes the file and
  compares it byte for byte. It is told the file's SHA-256 (`CI_PEER_SHA256`),
  or is given the seed (`CI_PEER_SEED`) and works the hash out itself.

## Direction `to-mac`: the runner sends, this Mac receives

```sh
cd ~/Desktop/Share
quickshare/integration_test/ci_peer_to_mac.sh              # push, then receive here
quickshare/integration_test/ci_peer_to_mac.sh --dry-run    # everything but the push
```

Commit first: the runner builds the commit you are on and this Mac runs the
files in the working tree, so the script refuses to go on if they differ under
`quickshare/` or `.github/` (`--allow-dirty` goes on anyway). Keep the VPN on,
the Mac awake (the script runs `caffeinate`) and the app window it opens
visible.

What it does:

1. Draws a code, a seed and a name (`mac-1a2b3c`) at random.
2. Makes a git worktree in a temporary folder on a new branch `ci-peer/<name>`,
   cut from the commit you are on, with one new file, `ci-peer/peer.json`:

   ```json
   {
     "direction": "to-mac",
     "code": "0123456789",
     "name": "mac-1a2b3c",
     "bytes": 52428800,
     "seed": "<64 hex digits>",
     "forceRelay": false
   }
   ```
3. Pushes the branch. That starts `.github/workflows/ci_peer.yml`, which checks
   every field, builds the app (ten to fifteen minutes) and runs the sender with
   what `peer.json` says: it writes the file the seed stands for, offers it under
   the code, accepts the one name, once, and waits up to forty minutes.
4. At once, here, runs the receiver. It searches for the code the way the app's
   code screen does (the local network and the internet together) and, when a
   search finds nothing, types the code again after ten seconds, for up to forty
   minutes: the runner's sender is not up yet, and the relays may be out of
   reach for a minute behind the VPN. When it finds the sender it announces the
   name, takes the file into a temporary folder, works out the expected size and
   SHA-256 from the seed, compares, and deletes the folder.
5. Prints the result, rebuilds the app (`flutter build macos --debug`; an
   integration run replaces the app bundle with its own) and prints the command
   that deletes the branch.

The result is the receiver's block on this Mac's terminal and in
`ci_peer_to_mac_<name>.log` in `$TMPDIR` (the script prints the path), and the sender's table on the Actions run page
(the artifact `ci-peer-log-<n>` holds the runner's whole log).

Options: `--bytes N` (default 50 MiB, at most 2 GiB), `--force-relay` (relay
candidates only, on both ends), `--find-minutes M` (default 40), `--remote NAME`,
`--no-rebuild`, `--allow-dirty`, `--dry-run`. `--dry-run` analyses the two
programs, makes the worktree and the commit and shows what would be pushed, then
removes both; it does not touch the network and starts nothing. A real run
analyses first too, so that a program that does not compile is found before the
push and not after the runner has spent ten minutes building.

By hand, the receiver alone (this is what the script runs):

```sh
cd ~/Desktop/Share/quickshare
caffeinate -dimsu flutter test integration_test/ci_peer_receiver.dart -d macos \
    --reporter=expanded \
    --dart-define=CI_PEER_CODE=0123456789 \
    --dart-define=CI_PEER_NAME=mac-1a2b3c \
    --dart-define=CI_PEER_BYTES=52428800 \
    --dart-define=CI_PEER_SEED=<64 hex digits> \
    --dart-define=CI_PEER_FIND_MINUTES=40
```

## Direction `to-runner`: this Mac sends, the runner receives

```
 this Mac                                      GitHub runner (macos-latest)
 ci_peer_sender.dart                           ci_peer_receiver.dart
   offers a random file under a code             types the code, announces CI_PEER_NAME
   accepts ONE receiver, by name                 takes the file
   writes the result                             checks size and SHA-256, writes the result
```

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

There is no `direction` in that file, so it is `to-runner`. The push starts
`.github/workflows/ci_peer.yml`. It runs on a push to `ci-peer/**` and on nothing
else. Add `"forceRelay": true` to `peer.json` to make the runner gather relay
candidates only (and start the sender with `--dart-define=QUICKSHARE_FORCE_RELAY=true`
for the same on its side).

**3. Look**

* Mac terminal, at the end: `CI_PEER ---- sender result ----` with the status,
  the path and the speed. The same as JSON in `CI_PEER_RESULT_JSON=...` and in
  the file `CI_PEER_OUT=` named.
* GitHub, Actions, "Remote peer check (over the internet)", the run for
  `ci-peer/run-1`: the run page shows the receiver's table, and the artifact
  `ci-peer-log-<n>` holds its whole log.

## What the output says

| line | meaning |
|---|---|
| `status: success` (receiver) | size and SHA-256 matched what the sender made (`to-runner`: what `peer.json` says; `to-mac`: what the seed says) |
| `status: success` (sender) | the transport finished sending; whether the bytes arrived whole is the receiver's word |
| `ice_path` | `relayed` (through TURN), `peerToPeer` (srflx or prflx) or `direct` (host) |
| `ice_pair` | the candidate type on each end of the chosen pair, `local=relay remote=srflx`; `local` is the machine that prints it, so the two sides print the pair mirrored, and what one sees as `remote=prflx` the other may call `host` |
| `relay_policy` | `relay` when `QUICKSHARE_FORCE_RELAY` took effect, otherwise `all` |
| `find_attempts` (receiver) | how many times the code was typed before a sender answered |
| `find_seconds` (receiver) | from the receiver starting to the sender's offer arriving: in `to-mac`, mostly the runner's build |
| `refused` (sender) | names that asked and were not the expected one |

## Rules of the check

* **One code, one run.** The sender serves one receiver and stops. To run again,
  draw a new code (the script does; for `to-runner` start the sender again and
  push `ci-peer/run-2`). "Re-run all jobs" in Actions reuses the old code and
  fails.
* **The code does not change** for the whole wait. The app changes it every five
  minutes; this does not. What it does rebuild every five minutes, as the app
  does, is the offer (peer connection, relay candidates, sealed answer drop),
  under the same code. An offer held forty minutes would test credentials
  running out, not the app. `CI_PEER_OFFER_REFRESH_SECONDS` changes that
  (default 300).
* **The name is no password.** The code, the seed and the name are in a public
  repository. The sender accepts only the one name it was given, only once, and
  the file is bytes that are worth nothing: this keeps out the device that was
  not meant, not the one that read the repository. Delete the branch afterwards
  (`git push origin --delete ci-peer/<name>`; the script prints the line).
* **A transfer that breaks halfway is a failure.** If the relay stops carrying
  bytes (ICE goes `Disconnected`, ten seconds later `Failed`), both ends report
  a failure with the path it was on (`ice_path: relayed`) and nothing is
  retried: only the *search* is retried, because that is the part that
  legitimately has to wait for the other machine. Run again with a new code.
* **The file** is, in `to-runner`, random bytes; in `to-mac`, the bytes of
  `SHA-256("directdrop-ci-peer-file-v1" || seed || i)` for `i = 0, 1, 2, ...`
  (`i` as eight bytes, big-endian), 32 bytes at a time, cut at `bytes`. Anyone
  can recompute it from `peer.json`, which is why a seed is enough to know the
  hash.
* **Where the checks are.** The workflow checks every field of `peer.json` against
  what it may look like before any is used, and reads only what the direction
  needs: `code`, `name`, `bytes`, `forceRelay`, and `sha256` (`to-runner`) or
  `seed` (`to-mac`, with `bytes` at most 2 GiB). `test/platform/ci_peer_workflow_test.dart`
  runs that script on good and hostile files.
* After any integration run on macOS: `flutter build macos --debug`. The run
  replaces the app bundle with its own (the script does it for you).

## Settings (`--dart-define`)

| define | side | default |
|---|---|---|
| `CI_PEER_EXPECT_NAME` | sender | required: the one name accepted |
| `CI_PEER_CODE`, `CI_PEER_SEED` | sender | both or neither. Given, the sender offers that file under that code (`to-mac`), and `CI_PEER_BYTES` is required too. Neither: it makes up a code and a random file (`to-runner`) |
| `CI_PEER_BYTES` | sender | 50 MiB (52428800) when it makes up the file; required when it is given |
| `CI_PEER_OUT` | sender | `ci_peer_<code>.json` in the app's temporary folder; the path is printed. The macOS app is sandboxed: a path outside its container is refused (`~/Downloads` is allowed), and then the JSON is only on stdout. Not used when the code is given |
| `CI_PEER_WAIT_MINUTES` | sender | 40, for the receiver to be accepted and to answer |
| `CI_PEER_TRANSFER_MINUTES` | both | 20, for the transfer once connected |
| `CI_PEER_OFFER_REFRESH_SECONDS` | sender | 300 |
| `CI_PEER_CODE`, `CI_PEER_NAME`, `CI_PEER_BYTES`, and `CI_PEER_SHA256` or `CI_PEER_SEED` | receiver | required (the hash or the seed, not both); the workflow takes them from `peer.json` |
| `CI_PEER_FIND_ATTEMPTS` | receiver | 5 searches before giving up |
| `CI_PEER_FIND_MINUTES` | receiver | not set: `CI_PEER_FIND_ATTEMPTS` searches. Set, or given a seed (then 40): search for that long, retyping the code ten seconds after each search that found nothing or broke |
| `QUICKSHARE_FORCE_RELAY=true` | both | off; relay candidates only (debug builds) |

## Running the two halves on one machine

Two `flutter test -d macos` runs from one directory cannot be run at once (one
build directory, one app bundle). Run one half from a copy of the project:

```sh
rsync -a --exclude build --exclude .dart_tool ~/Desktop/Share/quickshare/ /tmp/qs-copy/
cd /tmp/qs-copy && flutter pub get
flutter test integration_test/ci_peer_sender.dart -d macos --reporter=expanded \
    --dart-define=CI_PEER_CODE=... --dart-define=CI_PEER_SEED=... \
    --dart-define=CI_PEER_BYTES=... --dart-define=CI_PEER_EXPECT_NAME=...
```

with the receiver as above in the original folder (add
`--dart-define=QUICKSHARE_FORCE_RELAY=true` to both to make the bytes go through
TURN, since two programs on one Mac would otherwise find each other directly).
That checks the code, the name, the services and the bytes, but not that the
networks differ.

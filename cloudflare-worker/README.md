# DirectDrop Worker

One Cloudflare Worker, two unrelated jobs (see comment at the top of
`src/index.js` for why they're bundled):

- `POST /turn` — short-lived (30 min) TURN credentials for Cloudflare Calls
  TURN and Metered OpenRelay, per ТЗ v2.0 §3. Either provider may be left
  unconfigured: one whose secrets are missing is skipped (and named in the
  response's `skipped` field) rather than attempted and reported as an error.
- `POST /r/:roomId` / `GET /r/:roomId` — a blind KV mailbox for an encrypted
  SDP blob, TTL 30 min, per ТЗ v2.0 §4. This is the **reserve** rendezvous
  channel — the primary path stays the Nostr relays already implemented in
  `quickshare/lib/core/signaling/nostr_answer_channel.dart`.

Nothing here ever sees plaintext file data, file keys, or (for `/r/:roomId`)
even knows what it's storing.

**Deployed at** `https://directdrop-worker.directdrop-worker.workers.dev`
— currently Cloudflare-only; Metered can be added later by setting its two
secrets, with no code change and no redeploy.

## One-time setup

1. Install wrangler and log in:

   ```bash
   npm install
   npx wrangler login
   ```

2. Create the KV namespace and paste both printed ids into `wrangler.toml`:

   ```bash
   npx wrangler kv namespace create RENDEZVOUS_KV
   npx wrangler kv namespace create RENDEZVOUS_KV --preview
   ```

3. Create a Cloudflare Calls TURN key: dashboard → Calls → TURN → Create TURN
   Key. Note the **Key ID** and **API Token** it gives you (the token is
   shown once).

4. Create a Metered account (openrelay.metered.ca) and note your app
   subdomain and API key from their dashboard.

5. Set secrets (prompts for the value, nothing goes in a file):

   ```bash
   npx wrangler secret put CF_TURN_KEY_ID
   npx wrangler secret put CF_TURN_API_TOKEN
   npx wrangler secret put METERED_SUBDOMAIN
   npx wrangler secret put METERED_API_KEY
   ```

6. Deploy:

   ```bash
   npm run deploy
   ```

   Wrangler prints the Worker's `*.workers.dev` URL (or your custom route, if
   configured separately) — that's the base URL the Flutter client will call.

## Tests

```bash
npm test
```

No network, no account, no wrangler: the handler runs directly with `fetch`
stubbed and an in-memory stand-in for KV.

## Local dev

```bash
npm run dev
```

Then, against the printed local URL:

```bash
# TURN credentials
curl -X POST http://localhost:8787/turn

# rendezvous round-trip
curl -X POST http://localhost:8787/r/abcdefghijklmnop --data-binary 'hello'
curl http://localhost:8787/r/abcdefghijklmnop
```

## Pointing the app at it

After `npm run deploy`, build the Flutter app with the Worker URL:

```bash
flutter run -d macos --dart-define=QUICKSHARE_WORKER_URL=https://directdrop-worker.<account>.workers.dev
```

Without that define the app ignores the Worker entirely: signaling stays
Nostr-only and TURN credentials come from the build-time
`QUICKSHARE_TURN_USER` / `QUICKSHARE_TURN_PASS` defines.

To prove the Worker path actually carries a transfer, isolate it — otherwise
Nostr can answer first and a broken Worker still looks healthy:

```bash
flutter run -d macos --dart-define=QUICKSHARE_WORKER_URL=https://directdrop-worker.<account>.workers.dev --dart-define=QUICKSHARE_RENDEZVOUS_CHANNELS=worker
```

Inspect what actually landed in KV during a transfer (the room id is the
derived topic, printed in the `SIGNALING` logs):

```bash
npx wrangler kv key list --binding RENDEZVOUS_KV
```

## If `wrangler login` fails with a bot challenge

Symptom, on a network behind a VPN:

```
✘ [ERROR] It looks like you might have hit a bot challenge page.
✘ [ERROR] Invalid JSON in response: status: 403 Forbidden
```

The browser half of OAuth succeeds (the callback URL carries a `?code=`); what
gets challenged is wrangler's own back-channel request exchanging that code for
a token. A shared VPN exit IP is enough to trigger it, and the VPN cannot be
turned off here — so skip OAuth entirely and hand wrangler an API token.

1. In the dashboard (the browser passes the challenge fine): My Profile → API
   Tokens → Create Token → **Edit Cloudflare Workers** template, or a custom
   token with `Account Settings:Read`, `Workers Scripts:Edit`,
   `Workers KV Storage:Edit`.
2. Copy the account ID from the Workers Overview page (right-hand sidebar).
3. Export both, then run wrangler as usual — it never touches OAuth when these
   are set:

   ```bash
   export CLOUDFLARE_API_TOKEN=<token>
   export CLOUDFLARE_ACCOUNT_ID=<account id>
   ```

Put them in `~/.zshrc` to survive new shells, or in a `.env` file **outside**
this repo. Never commit either value.

Run every wrangler command from this directory (`cloudflare-worker/`), not from
your home directory — `secret put` and `deploy` need `wrangler.toml`, and
running elsewhere silently uses a different wrangler than the pinned one.

## Notes / things to revisit

- `MAX_BLOB_BYTES` is set to 8 KB. The ТЗ names two different sizes for what
  sits on the rendezvous — "~200 байт" in §1 and "~800–1500 байт" for the SDP
  offer in §5 — so 8 KB is a deliberately generous ceiling for encrypted SDP
  plus AEAD overhead, not a spec-derived number. Tighten it once real
  ciphertext sizes are measured.
- `/r/:roomId` overwrites on every POST rather than rejecting a second write.
  That's a deliberate choice (see comment in `handleRoomPost`) so the same
  room can carry offer, then answer — revisit if the client protocol ends up
  wanting separate rooms per direction instead.
- Metered is unconfigured, so ТЗ §12's mitigation for "Cloudflare blocked from
  Russia" is not actually in place — there is one relay provider, not two. Add
  `METERED_SUBDOMAIN` / `METERED_API_KEY` when that matters.
- No rate limiting yet. Fine for personal/small-scale use; add Cloudflare's
  built-in rate limiting rules (dashboard, no code change) before wider
  exposure.
- TURN credentials are fetched once, when the `RTCPeerConnection` is built.
  A single uninterrupted session running past the 30-minute TTL will lose its
  relay; refreshing them into a live connection via `setConfiguration()`
  (ТЗ v2.0 §9) is not implemented. Tracked as tech debt for stage 8 — it does
  not block acceptance criterion №1.
- The Cloudflare half **has** been exercised against a live account: the
  deployed `/turn` returns the documented array shape, and
  `quickshare/test/integration/live_worker_verification.dart` (hand-run, needs
  the network) confirms it survives `TurnCredentialService` into an ICE config
  with TLS/443 first and no duplicate URLs. Metered's path is still only
  covered by `npm test` against its documented payload.
- If a shape does drift, the failure is self-describing: `POST /turn` returns
  502 with the *field names* it actually received (`... carried no credentials
  (got object{urls,user,secret})`), never the values. The full upstream body
  goes to `wrangler tail` instead, where only the operator sees it.

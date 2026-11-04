# DirectDrop Worker

One Cloudflare Worker, two unrelated jobs (see comment at the top of
`src/index.js` for why they're bundled):

- `POST /turn` — short-lived (30 min) TURN credentials for Cloudflare Calls
  TURN and Metered OpenRelay, per ТЗ v2.0 §3. Either provider may be left
  unconfigured: one whose secrets are missing is skipped (and named in the
  response's `skipped` field) rather than attempted and reported as an error.
  The route is public, with no client secret: see [Abuse limits](#abuse-limits).
- `POST /r/:roomId` / `GET /r/:roomId` — a blind KV mailbox for an encrypted
  SDP blob, TTL 30 min, per ТЗ v2.0 §4. This is one of two rendezvous channels
  the app **races** by default (`QUICKSHARE_RENDEZVOUS_CHANNELS=nostr,worker`):
  the Nostr relays in `quickshare/lib/core/signaling/nostr_answer_channel.dart`
  are the other, either one is enough on its own, and the first delivery wins.

Nothing here ever sees plaintext file data, file keys, or (for `/r/:roomId`)
even knows what it's storing.

**Default address.** The app has `https://directdrop-worker.directdrop-worker.workers.dev`
compiled in (`AppConstants.workerBaseUrl`, overridable with
`QUICKSHARE_WORKER_URL`; empty turns the Worker off). This README describes the
code in this directory. It applies to a deployment once this version is
deployed, and says nothing about what the production Worker runs at any moment
— which providers have secrets set there, which limits are live. Metered is
added by setting its two secrets, with no code change and no redeploy.

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

   There is no client secret. `POST /turn` used to require an HMAC signed
   with a `TURN_CLIENT_SECRET` compiled into the app, but a secret shipped in
   a public binary protects nothing, so it is gone; `X-DD-Ts` / `X-DD-Mac`
   headers sent by older builds are ignored and those builds keep working.
   If you set `TURN_CLIENT_SECRET` earlier, remove it:
   `npx wrangler secret delete TURN_CLIENT_SECRET`. Abuse is bounded by the
   rate limits below instead.

6. Check the rate limiters in `wrangler.toml`. Each `[[ratelimits]]` needs a
   `namespace_id` that is unique across your whole Cloudflare account; change
   the `41xx` values if another Worker already uses them. Nothing to create
   beforehand: the bindings come into existence with the deploy.

7. Deploy:

   ```bash
   npm run deploy
   ```

   Wrangler prints the Worker's `*.workers.dev` URL (or your custom route, if
   configured separately) — that's the base URL the Flutter client will call.

8. Set a usage alert at the TURN provider (see
   [What rate limiting cannot do](#what-rate-limiting-cannot-do)).

## Abuse limits

Both routes are public. The Worker caps how often they can be called with
Workers Rate Limiting bindings declared in `wrangler.toml`, 60-second windows:

| Binding               | Route              | Key              | Limit |
| --------------------- | ------------------ | ---------------- | ----- |
| `RL_TURN_IP`          | `POST /turn`       | client IP        | 20    |
| `RL_TURN_GLOBAL`      | `POST /turn`       | `"global"`       | 300   |
| `RL_ROOM_POST_IP`     | `POST /r/:roomId`  | client IP        | 10    |
| `RL_ROOM_POST_GLOBAL` | `POST /r/:roomId`  | `"global"`       | 60    |
| `RL_ROOM_GET_IP`      | `GET /r/:roomId`   | client IP        | 120   |

- The client IP is `CF-Connecting-IP`; IPv6 is counted per `/64`, and an
  IPv4-mapped IPv6 address as the IPv4 address it carries.
- `RL_ROOM_GET_IP` has headroom on purpose: a waiting sender polls every 2 s
  (30 a minute), and several devices can share one NAT.
- The `global` buckets are per Cloudflare location, not worldwide: each data
  centre has its own allowance, so the real ceiling is the limit times the
  locations reached. They bound a burst, not a total. Counters are also
  approximate by design.
- The per-IP limit is checked first, so a client over its own limit does not
  spend the shared budget. Limits are checked before any KV call, provider
  call or request-body read.
- Failure policy: `/turn` **fails closed** (a missing or failing limiter means
  503, no credentials issued). `/r` **fails open** with a warning in the logs,
  because the Nostr relays can carry the rendezvous on their own and nothing
  there costs money per call.
- The POST body is read with an 8 KB cap and the upload is cancelled the
  moment it is exceeded, so a chunked request with no `Content-Length` cannot
  be buffered whole.

**Do not add a manual WAF rate-limiting rule of "10 requests per minute per
IP, Block" for `/r/*`.** Earlier versions of this README suggested one. It
breaks the rendezvous: a waiting sender polls `GET /r/:roomId` every 2 s, so
10 requests take about 20 s and the rule then blocks the poll that was about
to find the receiver's answer. If you created that rule in the dashboard,
delete it, or scope it to `http.request.method eq "POST"`. The built-in limits
above are the supported way.

### Error contract

Machine-readable errors are JSON with the code in `error`; the app can branch
on it. `Retry-After` is in seconds.

| Route    | Status | Body                                                              | Retry-After | Meaning |
| -------- | ------ | ----------------------------------------------------------------- | ----------- | ------- |
| `/turn`  | 200    | `{expiresAt, cloudflare?, metered?, skipped?}`                    |             | Credentials, valid 30 min |
| `/turn`  | 429    | `{"error":"rate_limited","scope":"turn_ip"\|"turn_global"}`       | 60          | Over a limit |
| `/turn`  | 503    | `{"error":"limiter_unavailable"}`                                 | 60          | Limiter missing or failing; nothing issued |
| `/turn`  | 503    | `{"error":"relay_disabled"}`                                      |             | Kill switch is on |
| `/turn`  | 503    | `{"error":"relay_unconfigured"}`                                  |             | Neither provider has its secrets set |
| `/turn`  | 502    | `{"error":"provider_error","cloudflare":{...},"metered":{...}}`   |             | Every configured provider failed; each entry is `{skipped}`, or `{error}` with a fixed code (`http_error` plus the provider's `status`, `bad_payload`, `unreachable`) |
| `/r/:id` | 201    | empty                                                             |             | Stored (POST) |
| `/r/:id` | 429    | `{"error":"rate_limited","scope":"room_post_ip"\|"room_post_global"\|"room_get_ip"}` | 60 | Over a limit |
| `/r/:id` | 503    | `{"error":"storage_unavailable"}`                                 | 60          | KV refused the call, e.g. the daily quota is spent |
| `/r/:id` | 400    | plain text `invalid room id` / `invalid blob size`                |             | Unchanged |
| `/r/:id` | 404    | plain text `not found`                                            |             | No blob in this room (yet) |

`/turn` responses never carry CORS headers; `/r` responses do. The old 502
`error` text `no TURN provider available` is now `provider_error`.

### Kill switch

To stop issuing credentials at once, without a deploy:

```bash
npx wrangler secret put TURN_ENABLED     # enter: false
```

`POST /turn` then answers `503 {"error":"relay_disabled"}` and calls no
provider. Turn it back on with `npx wrangler secret delete TURN_ENABLED`. Use a
secret or a dashboard variable, **not** `[vars]` in `wrangler.toml`: a deploy
would overwrite the dashboard value and silently re-enable the relay. Only the
value `false` (any case) disables; anything else leaves it on.

### What rate limiting cannot do

It limits how many credentials are *issued*, not how many **bytes** they
relay. A credential, once issued, relays traffic until it expires (30 minutes),
and the relayed volume is billed by the provider whatever this Worker does. So
set a usage or billing alert (and a hard cap where the provider offers one) in
the Cloudflare Calls and Metered dashboards. That alert is the only guard on
the bill; the kill switch stops *new* credentials, and existing ones simply
age out.

### KV consistency and polling

KV is eventually consistent: a write is visible immediately in the location
that took it, but other locations can keep serving an older value, and even a
cached "not found", for about 60 seconds. The mailbox copes because it is only
ever polled: the client asks again every couple of seconds, so a late write
simply turns up on a later poll. A reader must treat `404` (and, after an
overwrite, still seeing the previous blob) as "not yet", never as "failed".
Each POST also refreshes the 30-minute TTL.

Logs: with `[observability]` on, `429`, `503` and provider errors are written
as one JSON line `{event, route, scope, status}` (provider errors may add
`shape`, field names only). Client addresses, room ids and credentials are
never logged. View them in the dashboard (the Worker's Logs tab) or live with
`npm run tail`.

## Tests

```bash
npm test
```

No network, no account, no wrangler: the handler runs directly with `fetch`
stubbed, an in-memory stand-in for KV and fake rate-limit bindings
(`test/support.js`). `test/config.test.js` reads `wrangler.toml` and fails if
a binding name or limit there stops matching what the tests (and the Worker)
expect; a mistyped binding name would otherwise make `/turn` answer 503 in
production.

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

The app already has a Worker address compiled in. To point a build at your own
deployment instead, after `npm run deploy`:

```bash
flutter run -d macos --dart-define=QUICKSHARE_WORKER_URL=https://directdrop-worker.<account>.workers.dev
```

Without that define the app uses the address compiled into it
(`AppConstants.workerBaseUrl`). To turn the Worker off for a build, pass the
define empty (`--dart-define=QUICKSHARE_WORKER_URL=`): the answer then travels
by Nostr only, and TURN credentials come from the build-time
`QUICKSHARE_TURN_URL` / `QUICKSHARE_TURN_HOSTS` with `QUICKSHARE_TURN_USER` /
`QUICKSHARE_TURN_PASS`, if the build was given any.

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
- ТЗ §12's mitigation for "Cloudflare blocked from Russia" is a second relay
  provider. It exists only on a deployment that has set `METERED_SUBDOMAIN` /
  `METERED_API_KEY`; a Cloudflare-only deployment has one provider, not two.
  Check the deployment you care about rather than this file.
- TURN credentials are fetched when the `RTCPeerConnection` is built and again
  by `TurnCredentialRefresher` (`quickshare/lib/core/webrtc/`), which calls
  `setConfiguration()` on the live connection about five minutes before the
  30-minute expiry (ТЗ v2.0 §9), so a long relayed session can outlive the
  first credentials. It waits out a `429` for as long as `Retry-After` says (a
  minute if none), and stops for `relay_disabled` and `relay_unconfigured`.
- `quickshare/test/integration/live_worker_verification.dart` (hand-run, needs
  the network) is how a deployed Worker is checked: that `/turn` returns the
  documented array shape and that it survives `TurnCredentialService` into an
  ICE config with TLS/443 first and no duplicate URLs. Its result belongs to
  whichever deployment it was run against, on the day. Metered's path is
  otherwise covered only by `npm test` against its documented payload.
- If a shape does drift, the failure is self-describing in the logs, not in the
  response: `POST /turn` returns 502 with `{"error":"bad_payload"}` for that
  provider, and the log line carries the *field names* it actually received
  (`shape: "object{urls,user,secret}"`), never the values. Nothing a provider
  or the runtime wrote is returned: an exception from `fetch` quotes the
  address it was given, and Metered's address carries the API key. The
  response holds only the fixed codes above and a provider's HTTP status.

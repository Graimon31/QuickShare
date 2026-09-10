# Findings & Decisions

## Requirements

- Close leftovers from the 26-item audit against reconstructed TЗ.
- User asked to self-fix "the rest" after 22/26 were already in their commits.
- User then enabled **planning-with-files**; keep durable plan on disk.

## Research Findings

- 22 items were actually present in code (with residuals). Four were not:
  - **DD-02:** `cloudflare-worker/src/index.js` `POST /turn` unauthenticated, CORS `*`.
  - **DD-09:** no `UIBackgroundModes`; no URLSession; wakelock is foreground-only.
  - **DD-24:** receiver throttled; sender still emitted per 64 KB chunk.
  - **DD-25:** QHTP Wi-Fi already walked behind QR (uncommitted); internet/BT still `await expandSelection`.
- Residual: Apple BLE `pump*` treated unknown generation as 1 and could send file bytes if `isReady` fired before CAPS.

## Technical Decisions

| Decision | Rationale |
|----------|-----------|
| `X-DD-Ts` + `X-DD-Mac` HMAC-SHA256 | Matches Worker Web Crypto; 5-minute window |
| Empty app secret → do not call `/turn` | Avoids unauthenticated mint from official builds |
| `BackgroundHold` via `beginBackgroundTask` | Covers a glance at Settings; not a substitute for URLSession |
| `selectionPlaceholder` + `filesReady` | ICE/QR independent of listing |

## Issues Encountered

| Issue | Resolution |
|-------|------------|
| Live Worker will 503 until secret is set | Documented; user must `wrangler secret put TURN_CLIENT_SECRET` |
| DD-09 cannot keep WebRTC alive in background | Honest copy + 30s hold; QHTP can resume |

## Resources

- Spec: `quickshare/docs/specs/2026-09-10-requirements-audit.md`
- Worker: `cloudflare-worker/src/index.js`, `cloudflare-worker/README.md`
- Plan id: `2026-09-10-directdrop-remaining-dd-fixes`

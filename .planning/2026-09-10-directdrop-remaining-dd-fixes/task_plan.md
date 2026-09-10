# Task Plan: DirectDrop remaining DD fixes

## Goal

Close the remaining items from `quickshare/docs/specs/2026-09-10-requirements-audit.md` (DD-02, DD-09, DD-24, DD-25) in code, with tests, without claiming device-proven 100%.

## Next Step

Deploy Worker `TURN_CLIENT_SECRET` and rebuild the app with `--dart-define=QUICKSHARE_TURN_SECRET=…`. Then run the targeted Dart/Worker tests if anything else lands.

## Current Phase

Phase 4: Testing & Verification

## Phases

### Phase 1: Requirements & Discovery

- [x] Reconstruct TЗ from `requirements.html`
- [x] Write 26 bug reports (DD-01…DD-26)
- [x] Verify user's "22 of 26" claim against the tree
- **Status:** complete

### Phase 2: Planning & Structure

- [x] Identify the 4 leftovers: DD-02, DD-09, DD-24, DD-25
- [x] Note residuals: BLE pump on unknown generation, BLE receive no length check
- **Status:** complete

### Phase 3: Implementation

- [x] DD-24: `ProgressThrottle` on WebRTC sender (100 ms, force at 100%)
- [x] DD-25: internet/BT start with `selectionPlaceholder`; walk in parallel; send waits on `filesReady`
- [x] DD-02: HMAC on `POST /turn`; no CORS `*` on `/turn`; Dart signs when secret set
- [x] DD-09: iOS `BackgroundHold` (~30s), warning on sender progress; no `voip`
- [x] Residual DD-23: pump only if generation is known and &lt; 4
- **Status:** complete

### Phase 4: Testing & Verification

- [x] Worker `npm test` 19/19
- [x] Dart: throttle, selection, TURN, sender_bloc, ICE, relay
- [ ] Full `flutter test` / `flutter analyze` on the whole package
- [ ] Device run
- [ ] Worker deploy + matching dart-define
- **Status:** in_progress

### Phase 5: Delivery

- [ ] Commit uncommitted Wi-Fi index-behind-QR + this round of fixes
- [ ] User deploys Worker secret
- **Status:** pending

## Key Questions

1. Will production set `TURN_CLIENT_SECRET` before the next app build? Without it live `/turn` is 503.
2. Is a 30s iOS background task enough for DD-09, or is URLSession still wanted later?

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| HMAC of unix timestamp, not a static Bearer | Stops replay of a stolen header after 5 minutes |
| Fail closed if Worker secret missing | Open `/turn` was the bug; STUN-only is the honest fallback |
| No `voip` UIBackgroundModes | Previous commit: iOS killed the app on launch |
| Placeholder + parallel walk for internet/BT | QR/advertisement do not need the listing; first byte does |
| planning-with-files under `.planning/` | User enabled the skill; isolate this task from other work |

## Errors Encountered

| Error | Attempt | Resolution |
|-------|---------|------------|
| `progress_throttle.dart` missing (TDD red) | 1 | Created the class |
| Worker unsigned `/turn` returned 502 not 401 | 1 | Auth runs before `handleTurn` |
| `background_hold.dart` empty catch (analyze info) | 1 | Comment in the MissingPlugin catch |
| Existing TURN Dart tests had no secret | 1 | Pass `clientSecret: 's3cret'` in tests |

## Notes

- Spec: `quickshare/docs/specs/2026-09-10-requirements-audit.md`
- TЗ: Claude scratchpad `requirements.html`
- Wi-Fi index-behind-QR was already in the working tree before this round

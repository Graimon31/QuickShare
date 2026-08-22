# DirectDrop Heavy Transfer Protocol (QHTP)

**Version:** 1.0  
**Status:** Draft for implementation  
**Transport:** HTTP/1.1 over LAN (primary)  
**Scope:** v1 goals — up to 100 GB/file, 500 GB/session, 100 000 files, folders with subfolders, resume, LAN-only  

---

## 1. Goals & non-goals

### 1.1 Goals

| ID | Requirement |
|----|-------------|
| G1 | Transfer one file, many files, or a directory tree (relative paths preserved) |
| G2 | Stream disk→disk; no full-file RAM load |
| G3 | Resume after disconnect (file offset + completed items) |
| G4 | QR carries **session locator only**, not the file list |
| G5 | Per-file SHA-256 **after** receive (optional skip for empty files) |
| G6 | Auth: single-use session token (Bearer) |
| G7 | Path safety: no traversal outside receiver base dir |
| G8 | Limits enforced on both peers |

### 1.2 Non-goals (v1)

- Internet / TURN / WebRTC multi-file (may reuse auth later)
- Parallel multi-file download (always sequential)
- Pre-hash of entire tree before share
- Compression / encryption at rest
- Bidirectional sync

---

## 2. Roles

| Role | Responsibility |
|------|----------------|
| **Sender (Host)** | Indexes selection, opens local HTTP server, serves manifest + file bytes, tracks session |
| **Receiver (Client)** | Scans QR, pulls manifest, downloads items in order (or resume order), writes paths, **verifies size always and SHA-256 when the manifest carries one, before renaming** |

One active **receiver download stream** at a time per session in v1 (simplifies progress and resume). Multiple receivers are **out of scope** (token may be single-consumer).

---

## 3. Limits (normative)

| Constant | Value | Enforce where |
|----------|------:|---------------|
| `MAX_FILE_BYTES` | 100 × 1024³ | `FileIndexer._checkFileLimits`; receiver rejects the session after reading the manifest |
| `MAX_SESSION_BYTES` | 500 × 1024³ | `FileIndexer._checkFileLimits`; receiver preflight on `/v2/session` |
| `MAX_FILE_COUNT` | 100_000 | `FileIndexer._checkFileLimits`; receiver preflight |
| `MAX_PATH_DEPTH` | 32 | `FileIndexer._walkDirectory` |
| `MAX_REL_PATH_CHARS` | 512 | `FileIndexer._validatePathString`, characters |
| `MAX_NAME_BYTES` | 255 | `QhtpReceiverClient.sanitizeSegment`. **Bytes, not characters** — that is what filesystems count, and a Cyrillic name reaches the cap in half as many characters. An over-long name is shortened keeping its extension rather than refused, so the user still gets the file |
| `IDLE_NO_TRAFFIC_MS` | 30 × 60 × 1000 | Sender session timer (reset on any authed request) |
| `RESUME_STATE_TTL_MS` | 24 × 60 × 60 × 1000 | `SessionStateStore.cleanExpiredStates`, run at app start. Deletes the `.qs.partial` files first and the record last |
| `MANIFEST_MAX_BYTES` | 32 × 1024 × 1024 | Receiver checks `Content-Length` **before** parsing — the manifest is decoded into memory, so the bound has to come first |
| `CHUNK_HINT` | 1 × 1024 × 1024 | Suggested Range size (1 MiB); not mandatory |

Default skip names (sender index, configurable later):

- `.DS_Store`, `Thumbs.db`, `desktop.ini`
- Optional (default **on**): `.git/`, `node_modules/` (directory name match any segment)

---

## 4. Discovery: QR / deep link payload

### 4.1 Encoding

UTF-8 JSON → **zlib** → **base64url**, padding stripped (`=` removed; a decoder
must re-add it before decoding).

```
base64Url(zlib(utf8(json))).replaceAll('=', '')
```

> The zlib pass is not decoration. An earlier version base64-encoded the JSON
> directly, and because the SDP inside was *already* base64 of compressed
> bytes, the result grew ~33% and approached the 2953-byte ceiling of QR byte
> mode v40 EC=L. One compression pass on the outside, raw payload on the
> inside. A decoder written against the previous wording of this section would
> read compressed bytes as text and fail — this is the one place in the spec
> where the mismatch broke interoperability rather than expectations.

### 4.2 Schema (v2 locator)

Protocol version field `v` for heavy multi-file is **`2`**.

Legacy single-file QR remains `v: 1` (existing app path).

```json
{
  "v": 2,
  "ip": "192.168.1.42",
  "p": 8123,
  "t": "550e8400-e29b-41d4-a716-446655440000",
  "sid": "a1b2c3d4e5f6789012345678",
  "mode": "http-lan"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `v` | int | yes | Payload version; **2** = QHTP |
| `ip` | string | yes | IPv4 private (receiver must validate RFC1918) |
| `p` | int | yes | TCP port 1–65535 |
| `t` | string | yes | Session auth token (UUID v4 recommended) |
| `sid` | string | yes | Session id (hex 16–32 chars) |
| `mode` | string | yes | `"http-lan"` for QHTP; `"webrtc-qs1"` for the serverless internet path |
| `fn` | string | no | Display name. Present so the receiver can show it the moment the code is scanned |
| `fs` | int | no | Total bytes, same reason |
| `ic` | int | no | Item count, same reason |
| `sdp` | string | no | Serverless path only: the raw `QS1…` payload |

**Still not in QR:** per-item checksums and the item list. Those come from
`/v2/manifest`.

> `fn`, `fs` and `ic` were added deliberately and this section used to deny
> their existence. Without them the receiver had to call `/v2/session` before
> it could draw anything, which froze the scanner for up to ~20 seconds on
> some networks and read to the user as "scanning does nothing". The QR is the
> only thing available before any network call succeeds, so the preview lives
> there.

**A note on `ip`.** The table above used to require the receiver to validate
that the address is RFC1918. It does not, and cannot: the serverless payload
carries the literal `"p2p"` in this field, and a hotspot session carries
whatever subnet the vendor's access point chose. `validatePrivateIp` rejects
unparseable, link-local and multicast addresses and accepts the rest.

**A note on `sid`.** Described here as hex 16–32 chars; the implementation uses
a UUID v4 (36 characters including hyphens). Any opaque string round-trips —
nothing parses this field.

### 4.3 Compatibility

| Receiver sees | Behavior |
|---------------|----------|
| `v == 1` | Legacy single-file download (`/download`) |
| `v == 2` | QHTP (`/v2/...`) |
| other | Error: unsupported version |

---

## 5. HTTP conventions

### 5.1 Base URL

```
http://{ip}:{port}
```

Cleartext LAN only (existing platform cleartext policy).

### 5.2 Authentication

All `/v2/*` routes require:

```http
Authorization: Bearer {token}
```

| Failure | Status | Body |
|---------|--------|------|
| Missing/invalid header | 401 | `{"error":"unauthorized","code":"AUTH_REQUIRED"}` |
| Wrong token | 403 | `{"error":"forbidden","code":"AUTH_INVALID"}` |
| Session expired/closed | 410 | `{"error":"gone","code":"SESSION_GONE"}` — **not implemented**: an expired session stops the server, so the request fails to connect rather than answering 410. The 410 that does exist is `ITEM_GONE`, for a file that vanished from disk between indexing and download |

Compare tokens with **constant-time** equality.

### 5.3 Content types

| Endpoint class | Content-Type |
|----------------|--------------|
| JSON APIs | `application/json; charset=utf-8` |
| File bytes | `application/octet-stream` (or sniffed mime) |
| Errors | `application/json; charset=utf-8` |

### 5.4 Error object

```json
{
  "error": "human readable",
  "code": "MACHINE_CODE",
  "details": {}
}
```

---

## 6. Session lifecycle (sender)

```
INDEXING → READY → SERVING → (optional DRAINING) → CLOSED
                 ↘ FAILED
```

| State | Meaning |
|-------|---------|
| `INDEXING` | Walking files, building manifest |
| `READY` | Server bound, QR can be shown |
| `SERVING` | At least one authed request seen / transfer active |
| `CLOSED` | Stopped by user, timeout, or explicit complete |
| `FAILED` | Fatal index/bind error |

**Single-consumer (v1):** after Receiver calls `POST /v2/session/complete` successfully, or sender cancels, token is invalidated.

Optional: allow re-download until idle timeout — **v1 default = multi-get until sender cancels or idle timeout**, not hard single-shot (better for resume). Token lives until `CLOSED`.

---

## 7. Data model

### 7.1 Manifest item

```json
{
  "id": "000001",
  "path": "photos/2024/img_001.jpg",
  "size": 3456789,
  "mtime": 1712345678000,
  "mime": "image/jpeg"
}
```

| Field | Rules |
|-------|--------|
| `id` | Stable within session; zero-padded decimal or hex; unique |
| `path` | Relative, `/` separators only, no leading `/`, no `..` segments, no empty segments, no `\` |
| `size` | uint64, `0 … MAX_FILE_BYTES` |
| `mtime` | optional, ms since epoch UTC |
| `mime` | optional |

### 7.2 Manifest document

```json
{
  "protocol": "QHTP",
  "protocolVersion": 1,
  "sessionId": "a1b2c3d4e5f6789012345678",
  "createdAt": 1712345678000,
  "itemCount": 2,
  "totalBytes": 4000000,
  "items": [
    {
      "id": "000001",
      "path": "readme.txt",
      "size": 12,
      "mime": "text/plain"
    },
    {
      "id": "000002",
      "path": "docs/a.pdf",
      "size": 3999988,
      "mime": "application/pdf"
    }
  ]
}
```

Items carry two fields not shown above:

- `mtime` — modification time in milliseconds, always present.
- `sha256` — `sha256:<hex>`, **optional**. Filled in for sessions up to 2 GB
  and skipped above that; hashing is a full read of every byte before the QR
  can appear, and 500 GB of it would look like a hang. The receiver verifies
  the digest when present and the byte count always.

**Ordering:** `items` sorted by `path` ascending (UTF-8 byte order) for deterministic resume UI. Receiver **must not** assume order equals transfer order; transfer uses `id` list from client or default order = array order.

**Large manifests:** for `itemCount > 10_000`, sender **should** support NDJSON stream (see §8.3). v1 **must** support full JSON; NDJSON is **should** for scale.

### 7.3 Path normalization (sender)

When indexing absolute path `abs` under root `rootAbs`:

1. Resolve real path (follow symlinks: **v1 policy = skip symlinks** to avoid escape).  
2. `rel = relative(rootAbs, abs)` using `/`.  
3. Reject if any segment is `.` or `..` or empty.  
4. Reject if depth > `MAX_PATH_DEPTH`.  
5. Reject if `len(rel) > MAX_REL_PATH_CHARS`.  
6. Reject reserved Windows names on any segment (`CON`, `PRN`, …) — replace or skip (v1: **skip file** + log).  
7. UTF-8 only.

### 7.4 Path materialization (receiver)

Given `baseDir` and item `path`:

1. Split on `/`.  
2. Reject `.` / `..` / empty.  
3. `sanitizeSegment(segment)` — strip `[\x00-\x1F\x7F\\/:*?"<>|]`.  
4. `join(baseDir, ...segments)` → `normalize`.  
5. Require `isWithin(baseDir, result)`.  
6. `createDirectories(parent)`.  
7. Write to `result + ".qs.partial"` then rename on success (atomic complete).

---

## 8. API endpoints

All under `/v2`. Auth required unless noted.

### 8.1 `GET /v2/health`

**Auth:** optional (v1: **no auth** for faster preflight — only returns ok; **no sensitive data**).

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"ok":true,"protocol":"QHTP","protocolVersion":1}
```

Receiver may use this before auth to check reachability; if omitted, use HEAD session.

### 8.2 `GET /v2/session`

Returns session summary (no full item list if huge — see flags).

```http
GET /v2/session HTTP/1.1
Authorization: Bearer {token}
```

**200:**

```json
{
  "sessionId": "a1b2c3d4e5f6789012345678",
  "state": "READY",
  "itemCount": 12000,
  "totalBytes": 9876543210,
  "protocolVersion": 1,
  "supportsRange": true,
  "supportsNdjsonManifest": true
}
```

| Status | Code |
|--------|------|
| 401/403/410 | as §5.2 |

### 8.3 `GET /v2/manifest`

Full manifest.

```http
GET /v2/manifest HTTP/1.1
Authorization: Bearer {token}
Accept: application/json
```

**200:** body = Manifest document (§7.2).

**Optional NDJSON** (if `supportsNdjsonManifest`):

```http
GET /v2/manifest?format=ndjson HTTP/1.1
Authorization: Bearer {token}
Accept: application/x-ndjson
```

Stream:

1. First line: meta object **without** `items`:

```json
{"type":"meta","sessionId":"...","itemCount":12000,"totalBytes":9876543210,"protocolVersion":1}
```

2. Then one line per item:

```json
{"type":"item","id":"000001","path":"a.txt","size":1}
```

3. Final line:

```json
{"type":"end"}
```

Receiver must handle either format based on `Content-Type` / query.

**413** if JSON would exceed `MANIFEST_MAX_BYTES` and NDJSON not used — sender must use NDJSON.

> **Not implemented.** `/v2/session` honestly advertises
> `supportsNdjsonManifest: false`, and the server always serves full JSON — it
> never returns 413. The receiver enforces the ceiling from its side instead,
> refusing a manifest whose `Content-Length` exceeds `MANIFEST_MAX_BYTES`
> before parsing it. A session near `MAX_FILE_COUNT` would therefore fail on
> the receiving side rather than degrade to NDJSON.

### 8.4 `GET /v2/files/{id}`

File bytes by item id.

```http
GET /v2/files/000002 HTTP/1.1
Authorization: Bearer {token}
Range: bytes=0-1048575
```

#### Without `Range`

- **200** full body  
- Headers:
  - `Content-Length: {size}`
  - `Content-Type: {mime or octet-stream}`
  - `Accept-Ranges: bytes`
  - `X-QS-Item-Id: 000002`
  - `X-QS-Rel-Path: docs/a.pdf` (percent-encoded UTF-8)
  - `X-QS-Size: 3999988`

#### With `Range: bytes=start-end` or `bytes=start-`

RFC 7233:

- **206 Partial Content**  
- `Content-Range: bytes start-end/total`  
- `Content-Length: (end-start+1)`

| Condition | Status |
|-----------|--------|
| Invalid range | 416 with `Content-Range: bytes */total` |
| Unknown id | 404 `{"code":"ITEM_NOT_FOUND"}` |
| File vanished on disk | 410 `{"code":"ITEM_GONE"}` |

**Sender implementation notes:**

- Stream from `RandomAccessFile` / `File.openRead(start, end+1)`.  
- Do not buffer entire file.  
- Reset idle timer on each chunk flush.

### 8.5 `GET /v2/files/{id}/meta`

Lightweight metadata (optional but recommended for resume UI).

```json
{
  "id": "000002",
  "path": "docs/a.pdf",
  "size": 3999988,
  "mime": "application/pdf"
}
```

### 8.6 `POST /v2/session/complete` (receiver → sender signal)

Receiver notifies successful finish of entire session (all intended items done).

```http
POST /v2/session/complete HTTP/1.1
Authorization: Bearer {token}
Content-Type: application/json

{
  "sessionId": "a1b2c3d4e5f6789012345678",
  "receivedItems": 12000,
  "receivedBytes": 9876543210,
  "failedItems": 0
}
```

**200:**

```json
{"ok":true}
```

Sender **may** close session and stop HTTP server (v1 recommendation: close after complete **or** keep until user cancels — **default keep until idle** so flaky clients can re-fetch; UI shows complete on sender when this is received).

### 8.7 `POST /v2/session/cancel`

Either side intent: receiver aborts.

Sender marks session cancelled; subsequent file GETs → 410.

---

## 9. Receiver algorithm

### 9.1 Happy path

```
1. Decode QR (v=2), validatePrivateIp(ip), port range
2. GET /v2/session  (auth)
3. Disk preflight: freeSpace >= totalBytes + margin
4. If itemCount/totalBytes over limits → fail
5. GET /v2/manifest (json or ndjson)
6. Persist local SessionState (see §10)
7. For each item in order:
     a. If local state says completed+checksum ok → skip
     b. Determine startOffset from .qs.partial length (0 if none)
     c. GET /v2/files/{id} with Range if startOffset > 0
     d. Append to .qs.partial while hashing SHA-256
     e. On full size: rename to final path; store checksum; mark completed
     f. Update overall progress; reset retry budget per file
8. POST /v2/session/complete
9. Delete SessionState (or mark done)
```

### 9.2 Per-file retry

- Network errors: up to **3** retries with backoff 1s, 2s, 4s  
- On 4xx (except 416/401): fail item, continue to next (collect errors)  
- 401/403/410 session: abort all  

### 9.3 Progress events (for UI / BLoC)

```json
{
  "phase": "transferring",
  "itemIndex": 3,
  "itemCount": 100,
  "itemId": "000004",
  "itemPath": "a/b.bin",
  "itemReceived": 1048576,
  "itemSize": 5242880,
  "sessionReceived": 10485760,
  "sessionTotal": 100000000,
  "speedBps": 12500000
}
```

Phases: `connecting` | `manifest` | `transferring` | `verifying` | `completed` | `failed` | `cancelled`.

`verifying` = hashing tail / rename (usually overlapped with write).

### 9.4 Checksum

While writing bytes, update SHA-256.  
Store as `sha256:{hex}` in SessionState.  
v1: **no** checksum from sender in manifest (avoids pre-hash). Integrity = full read length match + optional local hash for resume corruption detect:

- If `.qs.partial` exists and size `s`, resume from `s` **without** re-hashing prefix **only if** state stores `partialSha256` mid-state;  
- **v1 simplification:** on resume, **re-download whole file** if partial exists but `partialHash` missing; **preferred v1.1:** incremental hash state (complex).  

**v1 normative resume hash policy:**

1. Persist `partialBytes` only.  
2. On resume, request `Range: bytes={partialBytes}-`.  
3. Hash **only the appended part** is insufficient for full file hash — full file hash computed by **re-reading final file once** after rename (stream hash) for items marked `verify:true` (default **true** for size > 0).  
4. Empty files: create empty file, hash of empty = known SHA-256.

This trades one extra read for simple resume (acceptable for v1).

---

## 10. Receiver local state (resume)

Path example: `{appSupport}/qhtp/{sessionId}/state.json`

```json
{
  "protocolVersion": 1,
  "sessionId": "a1b2c3d4e5f6789012345678",
  "host": "192.168.1.42",
  "port": 8123,
  "token": "…",
  "baseDir": "/storage/…/DirectDrop/Incoming/a1b2c3d4",
  "createdAt": 1712345678000,
  "updatedAt": 1712349999000,
  "items": {
    "000001": {
      "path": "readme.txt",
      "size": 12,
      "status": "completed",
      "sha256": "sha256:…",
      "finalPath": "/…/readme.txt"
    },
    "000002": {
      "path": "docs/a.pdf",
      "size": 3999988,
      "status": "partial",
      "partialPath": "/…/docs/a.pdf.qs.partial",
      "partialBytes": 1048576
    }
  }
}
```

`status`: `pending` | `partial` | `completed` | `failed`

TTL: delete state if older than `RESUME_STATE_TTL_MS` and not in progress.

**Security:** state contains token — store in app private dir only; wipe on complete/cancel.

---

## 11. Sender index algorithm

```
Input: list of roots (files and/or directories)
items = []
totalBytes = 0

for root in roots:
  if file: addOne(root, relName)
  if dir: walk(root, prefix="")

addOne(absPath, relPath):
  apply skip rules
  normalize relPath
  size = file.length
  enforce MAX_FILE_BYTES
  totalBytes += size; enforce MAX_SESSION_BYTES
  items.add(...)
  enforce MAX_FILE_COUNT

walk: recursive, skip symlinks, depth guard
sort items by path
assign ids "000001"…
state = READY
bind HTTP server
issue token + sid
encode QR v2
```

**UI:** emit index progress `{scannedFiles, totalBytesSoFar}`.

---

## 12. Sequence diagrams

### 12.1 Full transfer

```
Receiver                         Sender
   |                                |
   |  GET /v2/session               |
   |------------------------------->|
   |  200 summary                   |
   |<-------------------------------|
   |  GET /v2/manifest              |
   |------------------------------->|
   |  200 manifest                  |
   |<-------------------------------|
   |  GET /v2/files/000001          |
   |------------------------------->|
   |  200 body                      |
   |<-------------------------------|
   |  GET /v2/files/000002          |
   |  Range: bytes=1048576-         |
   |------------------------------->|
   |  206 partial                   |
   |<-------------------------------|
   |  ...                           |
   |  POST /v2/session/complete     |
   |------------------------------->|
   |  200 ok                        |
   |<-------------------------------|
```

### 12.2 Auth failure

```
Receiver → GET /v2/manifest (bad token) → 403 AUTH_INVALID → stop
```

---

## 13. Mapping to legacy v1

| Legacy | QHTP |
|--------|------|
| QR `v,ip,p,t,fn,fs,cs` | QR `v=2,ip,p,t,sid,mode` |
| `GET /download` | `GET /v2/files/{id}` |
| `HEAD /download` | `GET /v2/session` or HEAD file |
| Inline checksum in QR | Post-receive hash only |
| One shot token invalidate on complete stream | Session-level lifetime |

Both stacks can run on same port with route prefix `/v2` vs legacy routes during migration.

---

## 14. Security requirements (normative)

1. **Private IP only** on receiver before connect (existing `validatePrivateIp`).  
2. **Bearer token** entropy ≥ 122 bits (UUID v4).  
3. **No path escape** on receiver (§7.4).  
4. **Symlinks skipped** on sender walk.  
5. **Do not log tokens** in production.  
6. Bind server `InternetAddress.anyIPv4` ok on LAN; document risk on hostile Wi‑Fi.  
7. Rate-limit failed auth (optional v1.1): 20/min then 429.  

---

## 15. HTTP status code summary

| Code | When |
|------|------|
| 200 | OK full |
| 206 | Partial content |
| 400 | Malformed request |
| 401 | Auth missing |
| 403 | Auth invalid |
| 404 | Item not found |
| 410 | Session/item gone |
| 413 | Manifest too large |
| 416 | Range not satisfiable |
| 429 | Rate limited (optional) |
| 500 | Internal |

---

## 16. Test vectors (implement + automate)

1. **Single empty file** — manifest size 0, final empty path exists.  
2. **Single 1-byte file** — full GET, hash.  
3. **Range resume** — partial 1 MiB of 5 MiB, resume Range, final size 5 MiB.  
4. **Tree** — `a/b/c.txt`, `a/d.txt` structure preserved.  
5. **Traversal item** — sender must never emit `../x`; if forced, receiver rejects.  
6. **1000 tiny files** — complete without FD leak.  
7. **Auth** — wrong token 403.  
8. **Limits** — index fails when fileCount > 100_000.  
9. **Unicode paths** — `фото/снимок 1.jpg`.  
10. **Legacy QR v1** still works in parallel.

---

## 17. Implementation map (this codebase)

| Component | Change |
|-----------|--------|
| `shared/models/qr_payload.dart` | Add v2 fields; keep v1 factory |
| `sender/.../local_http_server.dart` | Add `/v2/*` router or new `QhtpHttpServer` |
| New `sender/domain/entities/transfer_manifest.dart` | Manifest + items |
| New `sender/.../file_indexer.dart` | Walk + limits |
| `receiver/.../receiver_repository_impl.dart` | Branch v1/v2 |
| New `receiver/.../qhtp_client.dart` | Session/manifest/range download |
| New `receiver/.../session_state_store.dart` | Resume JSON |
| BLoCs | Multi progress states |
| `AppConstants` | Limit constants from §3 |
| PWA | Полностью удалён из проекта |

---

## 18. Versioning

| Field | Meaning |
|-------|---------|
| QR `v` | Wire discovery version (2 = QHTP locator) |
| Manifest `protocolVersion` | Body schema version (start at 1) |

Breaking manifest changes → bump `protocolVersion`; receivers reject unknown with clear error.

---

## 19. Open points deferred to v1.1+

| Topic | Direction |
|-------|-----------|
| Incremental hash for partial without re-read | Store hash state every N MB |
| NDJSON required for all | When itemCount > 5_000 |
| Multi-receiver | Token per receiver |
| Compression | per-file optional |
| WebRTC datachannel framing of same manifest | Reuse item ids + chunk msgs |

---

## 20. Summary

QHTP v1 is a **LAN HTTP pull protocol**:

1. QR v2 locates host + token + session.  
2. Client pulls **manifest**, then **files by id** with **HTTP Range** resume.  
3. Paths are **relative and sanitized**.  
4. Limits and auth are explicit.  
5. No giant payloads in QR; no full-tree pre-hash.

This is sufficient to implement H1 (single huge file as 1-item manifest) and H2 (folders) on the same API.


---

## Appendix: verified against the code on 2026-08-16

Three limits in the table above existed only in this document until then, and
have since been implemented rather than removed from the spec:

- `MAX_NAME_CHARS` was absent from the code entirely, and is now
  `MAX_NAME_BYTES` — renamed because bytes are what `ENAMETOOLONG` counts.
- `MANIFEST_MAX_BYTES` was a declared constant nobody read.
- `MAX_FILE_BYTES` was enforced on the sending side only.

Per-item `sha256` in the manifest is **optional**. The indexer fills it in for
sessions up to 2 GB and skips it above that: hashing is a full read of every
byte before the QR code can appear, which for 500 GB would look like a hang.
Above the threshold the receiver still verifies the byte count, which is what
catches truncation.

# Findings

## Project location

- Primary: `/Users/mrgraimon/Desktop/Share`
- Copy: `/Users/mrgraimon/Desktop/Share_copy` (older git)

## Product

DirectDrop — P2P file transfer, Flutter, 5 OS. No account, no cloud, no own server.

## In-flight

Branch `fix/transfer-reliability` is 32 commits ahead of origin with uncommitted DD-02/09/24/25 work. Separate plan: remaining DD fixes.

## Extra variants (follow-up)

Not in the first wave list, still grounded:

- CompactSdp **drops IPv6** candidates (`compact_sdp_test.dart`) — dual-stack LAN is leaving throughput on the table.
- No pause-transfer UI; lifecycle `paused` is app-background, not user pause.
- No share-sheet, tray, Live Activities, CLI, LocalSend interop.
- Media picker already refuses iOS transcode — a privacy option (strip EXIF) would fit that stance.
- QHTP is sequential by spec; HTTP/2 or multi-GET would be a protocol bump.

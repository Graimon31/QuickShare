# QHTP (QuickShare Heavy Transfer Protocol) v1 Walkthrough

We have completed the full end-to-end (E2E) fixes and integration for **QHTP v1** in QuickShare (`quickshare/`).

## Key Accomplishments & E2E Unblocking

### 1. Robust QR Payload Branching (`C3`)
- Added explicit `isQhtp: true` flag to `TransferSession` in [transfer_session.dart](file:///Users/mrgraimon/Desktop/Share/quickshare/lib/features/sender/domain/entities/transfer_session.dart).
- `generateQRPayload` in [sender_repository_impl.dart](file:///Users/mrgraimon/Desktop/Share/quickshare/lib/features/sender/data/repositories/sender_repository_impl.dart):
  - `session.isQhtp == false` -> Legacy `v: 1` QR payload (`ip`, `port`, `token`, `fileName`, `fileSize`, `checksum`).
  - `session.isQhtp == true` -> QHTP `v: 2` locator QR payload (`ip`, `port`, `token`, `sessionId`, `mode: "http-lan"`).

### 2. Receiver QR Decoder v2 Support (`C1`)
- Updated `QRPayloadDecoder` in [qr_payload_decoder.dart](file:///Users/mrgraimon/Desktop/Share/quickshare/lib/features/receiver/data/qr/qr_payload_decoder.dart):
  - Accepts both `payload.version == 1` and `payload.version == 2`.
  - Validates `payload.isValid` (accepting QHTP session locators without `fileName`/`fileSize` fields).

### 3. SenderBloc `_onStartQhtpSend` Handler (`C2`)
- Implemented `_onStartQhtpSend` in [sender_bloc.dart](file:///Users/mrgraimon/Desktop/Share/quickshare/lib/features/sender/presentation/bloc/sender_bloc.dart):
  - Connected to the **Select Folder** UI button in `FilePickerPage`.
  - Indexes directory, starts QHTP HTTP server, generates QR v2 locator, and emits `QRReady(qrData, session)`.

---

## Architectural Mapping

| Layer | Component | Status |
|-------|-----------|--------|
| **Core** | `AppConstants` (`maxFileSizeBytes` = 2GB, `qhtpMaxFileBytes` = 100GB) | ✅ |
| **Model** | `QRPayload` (`v=1` & `v=2` support) | ✅ |
| **Data (Sender)** | `FileIndexer`, `LocalHttpServer` (`/v2/*` routes, 30 min idle TTL, 401/403 status codes) | ✅ |
| **Data (Receiver)** | `QhtpReceiverClient` (Range 206, `.qs.partial`, 3x retries, SHA-256 post-receive) | ✅ |
| **Domain** | `SenderRepository`, `ReceiverRepository`, `TransferSession` (`isQhtp`) | ✅ |
| **BLoC** | `SenderBloc` (`_onStartQhtpSend`), `ReceiverBloc` (`isQhtp` branching) | ✅ |
| **UI** | `FilePickerPage` (Select Folder button) | ✅ |

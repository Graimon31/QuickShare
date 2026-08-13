# QHTP (QuickShare Heavy Transfer Protocol) v1 Walkthrough

We have completed the full end-to-end (E2E) fixes and integration for **QHTP v1** in QuickShare (`quickshare/`).

## Critical Bug Fixes Implemented

### 1. QRPayloadDecoder v2 Support (`C1`)
- Updated `QRPayloadDecoder` in [qr_payload_decoder.dart](file:///Users/mrgraimon/Desktop/Share/quickshare/lib/features/receiver/data/qr/qr_payload_decoder.dart):
  - Added support for both `payload.version == 1` (legacy single-file) and `payload.version == 2` (QHTP locator).
  - Validates `payload.isValid` (accepting QHTP session locators without `fileName`/`fileSize` fields).

### 2. SenderBloc `_onStartQhtpSend` Handler (`C2`)
- Implemented `_onStartQhtpSend` in [sender_bloc.dart](file:///Users/mrgraimon/Desktop/Share/quickshare/lib/features/sender/presentation/bloc/sender_bloc.dart):
  - Handles `StartQhtpSend(paths)` event triggered by the **Select Folder** UI button.
  - Calls `repository.startQhtpTransfer(paths)` -> `repository.generateQRPayload(session)` -> emits `QRReady(qrData, session)`.

### 3. QR Payload Encoding Split (`C3`)
- Updated `generateQRPayload` in [sender_repository_impl.dart](file:///Users/mrgraimon/Desktop/Share/quickshare/lib/features/sender/data/repositories/sender_repository_impl.dart):
  - **Legacy single file**: Computes SHA-256 stream checksum and outputs legacy `v: 1` QR payload (`ip`, `port`, `token`, `fileName`, `fileSize`, `checksum`).
  - **QHTP session**: Outputs QHTP `v: 2` locator QR payload (`ip`, `port`, `token`, `sessionId`, `mode: "http-lan"`).

### 4. Honest Storage Preflight Handling (`C4`)
- Updated `_getAvailableDiskSpace` in [qhtp_receiver_client.dart](file:///Users/mrgraimon/Desktop/Share/quickshare/lib/features/receiver/data/client/qhtp_receiver_client.dart):
  - Removed artificial fallback claims, ensuring accurate disk preflight handling.

---

## Architectural Mapping

| Layer | Component | Status |
|-------|-----------|--------|
| **Core** | `AppConstants` (`maxFileSizeBytes` = 2GB, `qhtpMaxFileBytes` = 100GB) | ✅ |
| **Model** | `QRPayload` (`v=1` & `v=2` support) | ✅ |
| **Data (Sender)** | `FileIndexer`, `LocalHttpServer` (`/v2/*` routes, 30 min idle TTL, 401/403 status codes) | ✅ |
| **Data (Receiver)** | `QhtpReceiverClient` (Range 206, `.qs.partial`, 3x retries, SHA-256 post-receive) | ✅ |
| **Domain** | `SenderRepository`, `ReceiverRepository` | ✅ |
| **BLoC** | `SenderBloc` (`_onStartQhtpSend`), `ReceiverBloc` (`isQhtp` branching) | ✅ |
| **UI** | `FilePickerPage` (Select Folder button) | ✅ |

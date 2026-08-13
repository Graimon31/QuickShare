# ⚡ QuickShare — Ultra-Fast Cross-Platform P2P File Sharing

**QuickShare** is a production-ready, open-source peer-to-peer file transfer system written in Flutter. It enables direct, zero-cloud file transfers across **macOS, iOS, Android, Windows, and Linux** using ultra-high-speed LAN HTTP streaming (QHTP) and WebRTC signaling.

---

## 🌟 Key Features

- 🚀 **QHTP (Quick HTTP Transfer Protocol)**: Streams large files and directory trees over local Wi-Fi / Ethernet at up to line-rate speeds (100MB/s+).
- 🌐 **WebRTC Signaling**: Direct P2P transfers over the internet using STUN/ICE signaling.
- 📶 **Smart LAN IP Prioritization**: Automatically filters out VPN (utun/tailscale), Docker, and link-local interfaces to pick the true local private IPv4.
- 📱 **Cross-Platform**: Tailored native builds for macOS, iOS, Android, Windows, and Linux.
- 🎨 **Modern Dark Glass Theme**: Glassmorphism aesthetic `#0B1220` with neon gradients, progress metrics, and QR code scanning.
- 🛡️ **Zero Cloud Storage**: Files stream directly from peer to peer with end-to-end security and path traversal protection.

---

## 🏗️ Architecture Overview

```
 ┌────────────────┐          QHTP (HTTP Streaming / Port 8000-9000)          ┌────────────────┐
 │  Sender App    │ ────────────────────────────────────────────────────────> │  Receiver App  │
 │ (macOS/Android)│                                                           │(iOS/Android/Mac)│
 └────────────────┘                                                           └────────────────┘
         │                                                                            │
         │                        WebRTC STUN / Signaling                             │
         └───────────────────> [ Signaling Server ] <────────────────────────────────┘
```

### Transport Mechanisms
1. **Local Wi-Fi / LAN (QHTP)**:
   - Sender launches a lightweight embedded HTTP server (`shelf`).
   - Generates a QR code containing IP address, port, and one-time session token.
   - Receiver scans the QR code or inputs the Wi-Fi code to initiate streamed HTTP downloads.
2. **Internet Mode (WebRTC)**:
   - Uses a WebSocket signaling server to exchange SDP offers/answers and ICE candidates.
   - Streams raw binary data over an encrypted WebRTC DataChannel.
3. **Bluetooth Discovery (macOS Native)**:
   - macOS native Swift plugin (`QuickShareBluetooth.swift`) advertises and searches for nearby Macs.

---

## 🚀 Getting Started

### Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install) 3.24+
- Xcode 15+ (for macOS & iOS builds)
- Android SDK & NDK (for Android builds)

### Running the App

```bash
# 1. Install dependencies
flutter pub get

# 2. Run on macOS Desktop
flutter run -d macos

# 3. Run on iOS Simulator
flutter run -d iphonesimulator

# 4. Run on Android Emulator
flutter run -d android
```

---

## ⚙️ Configuration & Environment

To override the WebRTC signaling server URL for internet transfers:

```bash
flutter run --dart-define=QUICKSHARE_SIGNALING_URL=wss://share.yourdomain.com
```

---

## 🧪 Testing & Verification

```bash
# Run unit and integration tests
flutter test

# Run static analysis
flutter analyze
```

---

## 📄 License

Distributed under the MIT License. See `LICENSE` for details.

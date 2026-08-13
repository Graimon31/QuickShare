# Signaling Server Setup and Deployment

This server is headless — it brokers WebRTC signaling between two QuickShare
apps and serves no UI. File bytes never pass through it; they travel directly
between peers over a WebRTC DataChannel.

## Pointing the app at a server

The app defaults to `ws://localhost:3000`. Override it at build time:

```bash
flutter run   -d macos --dart-define=QUICKSHARE_SIGNALING_URL=wss://share.example.com
flutter build macos    --dart-define=QUICKSHARE_SIGNALING_URL=wss://share.example.com
```

Both the sending and receiving Mac must point at the same server.



## Enabling HTTPS (Local/LAN)

For true WebRTC capabilities on some mobile browsers (like iOS Safari), HTTPS is required even for local network usage.

1. **Generate a self-signed certificate**:
   ```bash
   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes
   ```

2. **Update `server.js`**:
   Follow the comments in `server.js` to require `https` and pass the certificate and key to `https.createServer`.
   Run the server with the environment variable `HTTPS_ENABLED=true`.

3. **Trusting the Certificate (iOS)**:
   - Send the `cert.pem` file to your iOS device (e.g., via AirDrop or email).
   - Open it and install the profile.
   - Go to Settings > General > About > Certificate Trust Settings and enable full trust for your root certificate.

## Production Deployment

If you wish to deploy the signaling server publicly:

- **Render/Heroku/Fly.io**: These platforms handle TLS termination for you. The existing HTTP code in `server.js` will work perfectly behind their load balancers. Just ensure the client connects using `wss://` and `https://`.
- **Cloudflare Workers**: You can rewrite the WebSocket signaling server as a Cloudflare Worker for a scalable, free-tier-friendly option.

## Security Notes
Currently, the local server runs on cleartext HTTP. While WebRTC data channels are encrypted end-to-end via DTLS, the initial signaling metadata (SDP, ICE candidates) is sent in cleartext over the WebSocket connection unless HTTPS/WSS is enabled. Use HTTPS on untrusted LANs.

// QuickShare signaling server.
//
// Headless: it brokers WebRTC signaling between two QuickShare app instances
// and serves no UI. Peers exchange offer/answer/ICE through here, then move
// the file directly over a WebRTC DataChannel — file bytes do not pass
// through this process.
const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const crypto = require('crypto');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Liveness probe — useful once this is deployed behind a real host.
app.get('/health', (_req, res) => res.json({ ok: true, service: 'quickshare-signaling' }));

// Simple in-memory room management
const rooms = new Map();
const connectionCounts = new Map();

function log(msg) {
    const timestamp = new Date().toISOString().substring(11, 19);
    console.log(`[${timestamp}] ${msg}`);
}

// Room cleanup: delete rooms idle for 5 minutes (300,000ms)
setInterval(() => {
    const now = Date.now();
    for (const [code, room] of rooms.entries()) {
        if (now - room.lastActivity > 300000) {
            log(`🧹 Cleaning up idle room: ${code}`);
            if (room.sender && room.sender.readyState === WebSocket.OPEN) {
                room.sender.send(JSON.stringify({ type: 'peer-disconnected' }));
            }
            if (room.receiver && room.receiver.readyState === WebSocket.OPEN) {
                room.receiver.send(JSON.stringify({ type: 'peer-disconnected' }));
            }
            rooms.delete(code);
        }
    }
}, 30000);

wss.on('connection', (ws, req) => {
    const ip = req.socket.remoteAddress;
    const now = Date.now();
    
    log(`🔌 New connection from ${ip}`);

    // Rate limiting: max 10 connections per IP per minute
    let rateData = connectionCounts.get(ip) || { count: 0, resetTime: now + 60000 };
    if (now > rateData.resetTime) {
        rateData = { count: 1, resetTime: now + 60000 };
    } else {
        rateData.count++;
    }
    connectionCounts.set(ip, rateData);

    if (rateData.count > 10) {
        log(`⚠️ Rate limit exceeded for ${ip}`);
        ws.close(1008, 'Rate limit exceeded');
        return;
    }

    let currentRoomCode = null;
    let role = null; // 'sender' or 'receiver'

    ws.on('message', (message, isBinary) => {
        if (isBinary) {
            return;
        }

        const textStr = message.toString('utf8');
        if (textStr.length > 65536) {
            log(`⚠️ Message too large from ${role} in room ${currentRoomCode}`);
            ws.close(1009, 'Message too large');
            return;
        }

        try {
            const data = JSON.parse(textStr);
            const { type, roomCode, mode, payload } = data;

            const validTypes = ['create-room', 'join-room', 'offer', 'answer', 'ice-candidate'];
            if (!validTypes.includes(type)) {
                return;
            }

            if (currentRoomCode && rooms.has(currentRoomCode)) {
                rooms.get(currentRoomCode).lastActivity = Date.now();
            }

            switch (type) {
                case 'create-room':
                    if (rooms.size >= 100) {
                        log(`⚠️ Server full, creation rejected`);
                        ws.send(JSON.stringify({ type: 'error', message: 'Server full, cannot create room' }));
                        return;
                    }

                    let newRoomCode;
                    do {
                        newRoomCode = crypto.randomBytes(3).toString('hex').toUpperCase();
                    } while (rooms.has(newRoomCode));
                    
                    rooms.set(newRoomCode, { sender: ws, receiver: null, lastActivity: Date.now() });
                    currentRoomCode = newRoomCode;
                    role = 'sender';
                    ws.send(JSON.stringify({ type: 'room-created', roomCode: newRoomCode }));
                    log(`✨ Room created: ${newRoomCode} (Mode: ${mode || 'wifi'})`);
                    break;

                case 'join-room':
                    const room = rooms.get(roomCode);
                    if (!room) {
                        log(`❌ Join failed: Room ${roomCode} not found`);
                        ws.send(JSON.stringify({ type: 'error', message: 'Room not found' }));
                        return;
                    }
                    if (room.receiver && room.receiver !== ws && room.receiver.readyState === WebSocket.OPEN) {
                        log(`⚠️ Join failed: Room ${roomCode} is full`);
                        ws.send(JSON.stringify({ type: 'error', message: 'Room is full' }));
                        return;
                    }
                    room.receiver = ws;
                    currentRoomCode = roomCode;
                    role = 'receiver';
                    
                    ws.send(JSON.stringify({ type: 'room-joined', roomCode }));
                    if (room.sender && room.sender.readyState === WebSocket.OPEN) {
                        room.sender.send(JSON.stringify({ type: 'receiver-joined' }));
                    }
                    log(`🤝 Receiver joined room: ${roomCode}`);
                    break;

                case 'offer':
                    log(`📤 Relay OFFER in room ${currentRoomCode}`);
                    relayToPeer(currentRoomCode, role, textStr);
                    break;

                case 'answer':
                    log(`📥 Relay ANSWER in room ${currentRoomCode}`);
                    relayToPeer(currentRoomCode, role, textStr);
                    break;

                case 'ice-candidate':
                    relayToPeer(currentRoomCode, role, textStr);
                    break;

                default:
                    log(`❓ Unknown message type: ${type}`);
            }
        } catch (e) {
            log(`❌ Error parsing message: ${e.message}`);
        }
    });

    ws.on('close', () => {
        if (currentRoomCode) {
            const room = rooms.get(currentRoomCode);
            if (room) {
                const target = role === 'sender' ? room.receiver : room.sender;
                if (target && target.readyState === WebSocket.OPEN) {
                    target.send(JSON.stringify({ type: 'peer-disconnected' }));
                }
                if (role === 'sender') {
                    rooms.delete(currentRoomCode);
                    log(`🗑️ Room ${currentRoomCode} deleted (Sender disconnected)`);
                } else if (role === 'receiver') {
                    room.receiver = null;
                    log(`🚪 Receiver left room ${currentRoomCode} (Room kept active)`);
                }
            }
        }
    });
});

// Relays a JSON control message as a text frame to the peer.
function relayToPeer(roomCode, currentRole, textMessage) {
    if (!roomCode) return;
    const targetRoom = rooms.get(roomCode);
    if (targetRoom) {
        const target = currentRole === 'sender' ? targetRoom.receiver : targetRoom.sender;
        if (target && target.readyState === WebSocket.OPEN) {
            const asText = typeof textMessage === 'string' ? textMessage : textMessage.toString('utf8');
            target.send(asText, { binary: false });
        }
    }
}

const PORT = process.env.PORT || 3000;
// Bind all interfaces so phones on the LAN can reach this Mac (not only loopback).
const HOST = process.env.HOST || '0.0.0.0';
server.listen(PORT, HOST, () => {
    log(`🚀 QuickShare Signaling Server listening on ${HOST}:${PORT}`);
    log(`   Receivers need: ws://<this-mac-lan-ip>:${PORT}`);
});

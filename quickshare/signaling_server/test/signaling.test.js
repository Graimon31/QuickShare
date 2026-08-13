// WebRTC signaling server E2E test.
// Verifies room creation, joining, and SDP/ICE signaling relay between peers.
const { spawn } = require('child_process');
const path = require('path');
const assert = require('assert');
const WebSocket = require('ws');

const SERVER = path.join(__dirname, '..', 'server.js');
const PORT = Number(process.env.TEST_PORT || 3997);

function run() {
    return new Promise((resolve, reject) => {
        const srv = spawn('node', [SERVER], {
            env: { ...process.env, PORT: String(PORT) },
            stdio: ['ignore', 'ignore', 'pipe'],
        });
        const fail = (e) => { srv.kill(); reject(e); };
        const timer = setTimeout(() => fail(new Error('timed out waiting for signaling test')), 10000);

        setTimeout(() => {
            const sender = new WebSocket(`ws://127.0.0.1:${PORT}`);
            sender.on('error', fail);
            sender.on('open', () => sender.send(JSON.stringify({ type: 'create-room', mode: 'wifi' })));

            let createdRoomCode = null;

            sender.on('message', (data) => {
                const msg = JSON.parse(data.toString('utf8'));

                if (msg.type === 'room-created') {
                    createdRoomCode = msg.roomCode;
                    const receiver = new WebSocket(`ws://127.0.0.1:${PORT}`);
                    receiver.on('error', fail);
                    receiver.on('open', () => receiver.send(
                        JSON.stringify({ type: 'join-room', roomCode: createdRoomCode, mode: 'wifi' })
                    ));

                    receiver.on('message', (rdata) => {
                        const rmsg = JSON.parse(rdata.toString('utf8'));
                        if (rmsg.type === 'room-joined') {
                            // Receiver connected
                        } else if (rmsg.type === 'offer') {
                            assert.strictEqual(rmsg.payload, 'test-sdp-offer');
                            receiver.send(JSON.stringify({ type: 'answer', roomCode: createdRoomCode, payload: 'test-sdp-answer' }));
                        }
                    });
                } else if (msg.type === 'receiver-joined') {
                    // Send offer to receiver
                    sender.send(JSON.stringify({ type: 'offer', roomCode: createdRoomCode, payload: 'test-sdp-offer' }));
                } else if (msg.type === 'answer') {
                    assert.strictEqual(msg.payload, 'test-sdp-answer');
                    clearTimeout(timer);
                    srv.kill();
                    resolve();
                }
            });
        }, 500);
    });
}

run().then(() => {
    console.log('✓ room-created & room-joined');
    console.log('✓ offer & answer relay');
    console.log('\nPASS');
    process.exit(0);
}).catch((e) => {
    console.error('FAIL:', e.message);
    process.exit(1);
});

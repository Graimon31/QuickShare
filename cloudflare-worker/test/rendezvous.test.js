// The /r/:roomId mailbox, against an in-memory stand-in for KV.
import { test } from 'node:test';
import assert from 'node:assert/strict';

import worker from '../src/index.js';

function makeEnv() {
  const store = new Map();
  return {
    puts: [],
    RENDEZVOUS_KV: {
      async put(key, value, options) {
        store.set(key, value);
        this.lastTtl = options?.expirationTtl;
      },
      async get(key) {
        return store.get(key) ?? null;
      },
    },
  };
}

const VALID_ROOM = 'abcdefghijklmnop'; // 16 chars, base64url alphabet

const post = (room, body) =>
  new Request(`https://worker.example/r/${room}`, { method: 'POST', body });
const get = (room) => new Request(`https://worker.example/r/${room}`);

test('a posted blob comes back byte for byte', async () => {
  const env = makeEnv();
  const payload = new Uint8Array([0, 1, 2, 250, 251, 255]);

  const written = await worker.fetch(post(VALID_ROOM, payload), env);
  assert.equal(written.status, 201);

  const read = await worker.fetch(get(VALID_ROOM), env);
  assert.equal(read.status, 200);
  assert.deepEqual(new Uint8Array(await read.arrayBuffer()), payload);
});

test('an unknown room is a 404, not an empty 200', async () => {
  const env = makeEnv();
  const read = await worker.fetch(get(VALID_ROOM), env);
  assert.equal(read.status, 404);
});

test('the room TTL is the spec 30 minutes', async () => {
  const env = makeEnv();
  await worker.fetch(post(VALID_ROOM, new Uint8Array([1])), env);
  assert.equal(env.RENDEZVOUS_KV.lastTtl, 30 * 60);
});

test('a second post overwrites, so one room carries offer then answer', async () => {
  const env = makeEnv();
  await worker.fetch(post(VALID_ROOM, new Uint8Array([1, 1, 1])), env);
  await worker.fetch(post(VALID_ROOM, new Uint8Array([2, 2])), env);

  const read = await worker.fetch(get(VALID_ROOM), env);
  assert.deepEqual(new Uint8Array(await read.arrayBuffer()), new Uint8Array([2, 2]));
});

test('a malformed room id is rejected before touching KV', async () => {
  const env = makeEnv();
  for (const bad of ['short', 'has spaces here!!', '../../etc/passwd', 'a'.repeat(65)]) {
    const response = await worker.fetch(post(encodeURIComponent(bad), new Uint8Array([1])), env);
    assert.equal(response.status, 400, `"${bad}" should be rejected`);
  }
});

test('an empty or oversized blob is rejected', async () => {
  const env = makeEnv();

  const empty = await worker.fetch(post(VALID_ROOM, new Uint8Array([])), env);
  assert.equal(empty.status, 400);

  const huge = await worker.fetch(post(VALID_ROOM, new Uint8Array(8 * 1024 + 1)), env);
  assert.equal(huge.status, 400);

  const atLimit = await worker.fetch(post(VALID_ROOM, new Uint8Array(8 * 1024)), env);
  assert.equal(atLimit.status, 201, 'exactly at the ceiling must pass');
});

test('CORS preflight is answered', async () => {
  const env = makeEnv();
  const response = await worker.fetch(
    new Request(`https://worker.example/r/${VALID_ROOM}`, { method: 'OPTIONS' }),
    env,
  );
  assert.equal(response.status, 204);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
});

test('an unknown path is a 404', async () => {
  const env = makeEnv();
  const response = await worker.fetch(new Request('https://worker.example/nope'), env);
  assert.equal(response.status, 404);
});

// The /r/:roomId mailbox, against an in-memory stand-in for KV.
import { test } from 'node:test';
import assert from 'node:assert/strict';

import worker from '../src/index.js';
import { captureLogs, limiterBindings, throwingLimiter } from './support.js';

/// [limiters] is passed to limiterBindings (`{overrides, now}`); `null` leaves
/// the env without any limiter binding at all. [kv] replaces KV methods, to
/// make storage fail.
function makeEnv({ limiters = {}, kv = {} } = {}) {
  const store = new Map();
  const env = {
    puts: [],
    kvReads: 0,
    kvWrites: 0,
    RENDEZVOUS_KV: {
      async put(key, value, options) {
        env.kvWrites++;
        store.set(key, value);
        this.lastTtl = options?.expirationTtl;
      },
      async get(key) {
        env.kvReads++;
        return store.get(key) ?? null;
      },
      ...kv,
    },
    ...(limiters === null ? {} : limiterBindings(limiters)),
  };
  return env;
}

const VALID_ROOM = 'abcdefghijklmnop'; // 16 chars, base64url alphabet

const withIp = (ip) => (ip ? { 'CF-Connecting-IP': ip } : {});
const post = (room, body, ip) =>
  new Request(`https://worker.example/r/${room}`, {
    method: 'POST',
    body,
    headers: withIp(ip),
  });
const get = (room, ip) =>
  new Request(`https://worker.example/r/${room}`, { headers: withIp(ip) });

/// A POST whose body arrives in [chunks] pieces with no Content-Length, the
/// way chunked transfer encoding looks to the Worker. `stats.pulled` counts
/// the chunks actually requested from the stream, so a test can tell reading
/// with a cap from buffering everything and checking afterwards.
function chunkedPost(room, { chunks, chunkBytes, ip }) {
  const stats = { pulled: 0, cancelled: false };
  let sent = 0;
  const body = new ReadableStream(
    {
      pull(controller) {
        if (sent >= chunks) return controller.close();
        sent++;
        stats.pulled++;
        controller.enqueue(new Uint8Array(chunkBytes).fill(7));
      },
      cancel() {
        stats.cancelled = true;
      },
    },
    { highWaterMark: 0 },
  );
  const request = new Request(`https://worker.example/r/${room}`, {
    method: 'POST',
    body,
    duplex: 'half',
    headers: withIp(ip),
  });
  assert.equal(request.headers.get('content-length'), null, 'the premise: no Content-Length');
  return { request, stats };
}

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

test('a malformed URI encoded room id returns 400 not 500', async () => {
  const env = makeEnv();
  const response = await worker.fetch(new Request('https://worker.example/r/%E0%A4%A'), env);
  assert.equal(response.status, 400);
});

test('Content-Length pre-check rejects oversized body before reading arrayBuffer', async () => {
  const env = makeEnv();
  const response = await worker.fetch(
    new Request(`https://worker.example/r/${VALID_ROOM}`, {
      method: 'POST',
      headers: { 'Content-Length': '99999' },
      body: new Uint8Array([1, 2, 3]),
    }),
    env,
  );
  assert.equal(response.status, 400);
  assert.equal(await response.text(), 'invalid blob size');
});

// --- abuse limits -----------------------------------------------------------
//
// The mailbox is public and every POST is a KV write, with 1000 a day on the
// free tier. The limits sit in front of KV and in front of body buffering.

const rateLimited = (scope) => ({ error: 'rate_limited', scope });

test('POST is limited per IP: 429 with Retry-After, and KV is never reached', async () => {
  const env = makeEnv();
  for (let i = 0; i < 10; i++) {
    const ok = await worker.fetch(post(VALID_ROOM, new Uint8Array([i + 1]), '203.0.113.7'), env);
    assert.equal(ok.status, 201, `POST ${i + 1} is within the limit of 10`);
  }
  assert.equal(env.kvWrites, 10);

  const limited = await worker.fetch(post(VALID_ROOM, new Uint8Array([99]), '203.0.113.7'), env);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('Retry-After'), '60');
  assert.match(limited.headers.get('Content-Type'), /application\/json/);
  assert.equal(limited.headers.get('Access-Control-Allow-Origin'), '*');
  assert.deepEqual(await limited.json(), rateLimited('room_post_ip'));
  assert.equal(env.kvWrites, 10, 'the refused POST must not write');

  const other = await worker.fetch(post(VALID_ROOM, new Uint8Array([5]), '203.0.113.8'), env);
  assert.equal(other.status, 201, 'another IP has its own bucket');
});

test('POST over the global ceiling is 429 with the global scope', async () => {
  const env = makeEnv({ limiters: { overrides: { RL_ROOM_POST_GLOBAL: 2 } } });
  assert.equal((await worker.fetch(post(VALID_ROOM, new Uint8Array([1]), '198.51.100.1'), env)).status, 201);
  assert.equal((await worker.fetch(post(VALID_ROOM, new Uint8Array([1]), '198.51.100.2'), env)).status, 201);

  const limited = await worker.fetch(post(VALID_ROOM, new Uint8Array([1]), '198.51.100.3'), env);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('Retry-After'), '60');
  assert.deepEqual(await limited.json(), rateLimited('room_post_global'));
  assert.equal(env.kvWrites, 2);
});

test('GET is limited per IP at 120 a minute: 429 before KV, and the next minute is clear', async () => {
  let clock = 5_000_000;
  const env = makeEnv({ limiters: { now: () => clock } });
  for (let i = 0; i < 120; i++) {
    const miss = await worker.fetch(get(VALID_ROOM, '203.0.113.7'), env);
    assert.equal(miss.status, 404, `GET ${i + 1} is within the limit`);
  }
  assert.equal(env.kvReads, 120);

  const limited = await worker.fetch(get(VALID_ROOM, '203.0.113.7'), env);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('Retry-After'), '60');
  assert.equal(limited.headers.get('Access-Control-Allow-Origin'), '*');
  assert.deepEqual(await limited.json(), rateLimited('room_get_ip'));
  assert.equal(env.kvReads, 120, 'the refused GET must not read');

  clock += 60_000;
  assert.equal((await worker.fetch(get(VALID_ROOM, '203.0.113.7'), env)).status, 404);
});

test('a rate-limited POST never reads its body', async () => {
  const env = makeEnv({ limiters: { overrides: { RL_ROOM_POST_IP: 0 } } });
  const { request, stats } = chunkedPost(VALID_ROOM, {
    chunks: 4,
    chunkBytes: 1024,
    ip: '203.0.113.7',
  });

  const response = await worker.fetch(request, env);

  assert.equal(response.status, 429);
  assert.equal(stats.pulled, 0, 'refusing must cost no buffering');
  assert.equal(env.kvWrites, 0);
});

test('IPv6 clients in one /64 share a mailbox bucket', async () => {
  const env = makeEnv({ limiters: { overrides: { RL_ROOM_GET_IP: 2 } } });
  const status = async (ip) => (await worker.fetch(get(VALID_ROOM, ip), env)).status;

  assert.equal(await status('2001:db8:1:2::1'), 404);
  assert.equal(await status('2001:db8:1:2:aaaa:bbbb:cccc:dddd'), 404);
  assert.equal(await status('2001:DB8:1:2::99'), 429);
  assert.equal(await status('2001:db8:1:3::1'), 404, 'the neighbouring /64 is another client');
});

test('a request without CF-Connecting-IP is still served, on a shared fallback bucket', async () => {
  const env = makeEnv();
  const response = await worker.fetch(post(VALID_ROOM, new Uint8Array([1])), env);
  assert.equal(response.status, 201);
});

test('requests without an address are one client: they share the fallback bucket and its limit', async () => {
  const env = makeEnv({ limiters: { overrides: { RL_ROOM_POST_IP: 2 } } });
  const status = async () => (await worker.fetch(post(VALID_ROOM, new Uint8Array([1])), env)).status;

  assert.deepEqual([await status(), await status(), await status()], [201, 201, 429]);
  assert.equal(new Set(env.RL_ROOM_POST_IP.calls).size, 1, 'a bucket each would be no limit at all');
});

test('a forged X-Forwarded-For does not choose the mailbox bucket', async () => {
  const env = makeEnv({ limiters: { overrides: { RL_ROOM_GET_IP: 2 } } });
  const seen = [];
  for (let i = 0; i < 4; i++) {
    const request = new Request(`https://worker.example/r/${VALID_ROOM}`, {
      headers: { 'CF-Connecting-IP': '203.0.113.7', 'X-Forwarded-For': `198.51.100.${i + 1}` },
    });
    seen.push((await worker.fetch(request, env)).status);
  }
  assert.deepEqual(seen, [404, 404, 429, 429]);
});

test('a normal two-device session never meets a limit', async () => {
  // The sender polls every 2 s for five minutes: 150 GETs at 30 a minute. Both
  // phones may sit behind one NAT, so the receiver polls from the same
  // address, and each side posts once.
  let clock = 9_000_000;
  const env = makeEnv({ limiters: { now: () => clock } });
  const nat = '203.0.113.7';
  const seen = [];

  const offer = await worker.fetch(post(VALID_ROOM, new Uint8Array([1, 1]), nat), env);
  seen.push(offer.status);
  for (let poll = 0; poll < 150; poll++) {
    clock += 2_000;
    seen.push((await worker.fetch(get(VALID_ROOM, nat), env)).status);
    if (poll === 10) {
      const answer = await worker.fetch(post(VALID_ROOM, new Uint8Array([2, 2]), nat), env);
      seen.push(answer.status);
    }
    if (poll >= 10) seen.push((await worker.fetch(get(VALID_ROOM, nat), env)).status);
  }

  assert.ok(seen.length > 280, 'the session really ran');
  assert.ok(!seen.includes(429), 'no limit may fire on the happy path');
  assert.ok(seen.every((s) => [200, 201, 404].includes(s)), seen.join(','));
});

test('if the limiter throws or is missing the mailbox fails open and warns', async (t) => {
  const logs = captureLogs(t);
  const cases = [
    makeEnv({ limiters: null }),
    {
      ...makeEnv({ limiters: null }),
      RL_ROOM_POST_IP: throwingLimiter(),
      RL_ROOM_POST_GLOBAL: throwingLimiter(),
      RL_ROOM_GET_IP: throwingLimiter(),
    },
  ];
  for (const env of cases) {
    const written = await worker.fetch(post(VALID_ROOM, new Uint8Array([4, 2]), '203.0.113.7'), env);
    assert.equal(written.status, 201, 'rendezvous has Nostr first; a limiter outage must not close it');
    const read = await worker.fetch(get(VALID_ROOM, '203.0.113.7'), env);
    assert.equal(read.status, 200);
    assert.deepEqual(new Uint8Array(await read.arrayBuffer()), new Uint8Array([4, 2]));
  }

  const warnings = logs.filter(({ args }) => JSON.parse(args[0]).event === 'limiter_fail_open');
  assert.ok(warnings.length > 0, 'failing open must leave a trace');
  assert.ok(warnings.every(({ method }) => method === 'warn'));
  assert.ok(!logs.map(({ args }) => args.join(' ')).join('\n').includes('203.0.113.7'));
});

test('429 and fail-open log lines carry route and scope, never the IP', async (t) => {
  const logs = captureLogs(t);
  const env = makeEnv({ limiters: { overrides: { RL_ROOM_GET_IP: 0 } } });
  assert.equal((await worker.fetch(get(VALID_ROOM, '2001:db8:aaaa:bbbb::1'), env)).status, 429);

  assert.equal(logs.length, 1);
  assert.deepEqual(JSON.parse(logs[0].args[0]), {
    event: 'rate_limited',
    route: '/r',
    scope: 'room_get_ip',
    status: 429,
  });
  assert.ok(!logs[0].args[0].includes('2001'));
  assert.ok(!logs[0].args[0].includes(VALID_ROOM), 'room ids are bearer-ish; keep them out too');
});

// --- storage failures --------------------------------------------------------

test('a KV write that fails is 503 storage_unavailable with Retry-After, not an exception', async (t) => {
  const logs = captureLogs(t);
  const env = makeEnv({
    kv: {
      async put() {
        throw new Error('KV put() limit exceeded for the day.');
      },
    },
  });

  const response = await worker.fetch(post(VALID_ROOM, new Uint8Array([1]), '203.0.113.7'), env);

  assert.equal(response.status, 503);
  assert.equal(response.headers.get('Retry-After'), '60');
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
  assert.deepEqual(await response.json(), { error: 'storage_unavailable' });
  const line = JSON.parse(logs.at(-1).args[0]);
  assert.deepEqual(line, { event: 'storage_unavailable', route: '/r', scope: 'kv_put', status: 503 });
});

test('a KV read that fails is 503 storage_unavailable with Retry-After', async () => {
  const env = makeEnv({
    kv: {
      async get() {
        throw new Error('KV get() limit exceeded for the day.');
      },
    },
  });

  const response = await worker.fetch(get(VALID_ROOM, '203.0.113.7'), env);

  assert.equal(response.status, 503);
  assert.equal(response.headers.get('Retry-After'), '60');
  assert.deepEqual(await response.json(), { error: 'storage_unavailable' });
});

// --- body size ---------------------------------------------------------------

test('a chunked body with no Content-Length cannot get past the cap by being buffered', async () => {
  const env = makeEnv();
  // 4000 chunks of 1 KB would be 4 MB if read to the end.
  const { request, stats } = chunkedPost(VALID_ROOM, {
    chunks: 4000,
    chunkBytes: 1024,
    ip: '203.0.113.7',
  });

  const response = await worker.fetch(request, env);

  assert.equal(response.status, 400);
  assert.equal(await response.text(), 'invalid blob size');
  assert.ok(stats.pulled <= 12, `read ${stats.pulled} chunks; it should stop just past 8 KB`);
  assert.ok(stats.cancelled, 'the upload must be aborted, not left running');
  assert.equal(env.kvWrites, 0);
});

test('a chunked body of exactly 8 KB is stored byte for byte', async () => {
  const env = makeEnv();
  const { request } = chunkedPost(VALID_ROOM, { chunks: 8, chunkBytes: 1024, ip: '203.0.113.7' });

  const written = await worker.fetch(request, env);
  assert.equal(written.status, 201);

  const read = await worker.fetch(get(VALID_ROOM, '203.0.113.7'), env);
  assert.deepEqual(new Uint8Array(await read.arrayBuffer()), new Uint8Array(8192).fill(7));
});

test('a chunked body with no bytes at all is rejected like an empty one', async () => {
  const env = makeEnv();
  const { request } = chunkedPost(VALID_ROOM, { chunks: 0, chunkBytes: 1, ip: '203.0.113.7' });

  const response = await worker.fetch(request, env);

  assert.equal(response.status, 400);
  assert.equal(env.kvWrites, 0);
});

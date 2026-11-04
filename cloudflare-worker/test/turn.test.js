// Feeds the Worker the exact payloads Cloudflare and Metered document, with
// upstream `fetch` stubbed, and checks what comes out the other side is what
// the Dart client (TurnCredentialService) parses.
//
// This is the shape contract that could not be verified any other way: the
// real APIs need live accounts, and a mismatch there is the single most
// likely reason a first live deploy fails.
//
//     node --test test/
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';

import worker from '../src/index.js';
import { captureLogs, limiterBindings, throwingLimiter } from './support.js';

// https://developers.cloudflare.com/realtime/turn/generate-credentials/
const CLOUDFLARE_DOCUMENTED = {
  iceServers: [
    { urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.cloudflare.com:53'] },
    {
      urls: [
        'turn:turn.cloudflare.com:3478?transport=udp',
        'turn:turn.cloudflare.com:53?transport=udp',
        'turn:turn.cloudflare.com:3478?transport=tcp',
        'turn:turn.cloudflare.com:80?transport=tcp',
        'turns:turn.cloudflare.com:5349?transport=tcp',
        'turns:turn.cloudflare.com:443?transport=tcp',
      ],
      username: 'cf-user',
      credential: 'cf-cred',
    },
  ],
};

// The shape of the sibling `credentials/generate` endpoint — also current,
// also documented, just packaged differently. We do not call it; this pins
// the tolerance that makes switching endpoints a one-line change.
const CLOUDFLARE_SINGLE_OBJECT = {
  iceServers: {
    urls: ['turns:turn.cloudflare.com:443?transport=tcp'],
    username: 'cf-object-user',
    credential: 'cf-object-cred',
  },
};

// https://www.metered.ca/docs/turn-rest-api/get-credential/ — array, and note
// `urls` is a STRING per entry, not an array.
const METERED_DOCUMENTED = [
  { urls: 'stun:standard.relay.metered.ca:80' },
  { urls: 'turn:standard.relay.metered.ca:80', username: 'm-user', credential: 'm-cred' },
  { urls: 'turn:standard.relay.metered.ca:443', username: 'm-user', credential: 'm-cred' },
  { urls: 'turns:standard.relay.metered.ca:443?transport=tcp', username: 'm-user', credential: 'm-cred' },
];

const PROVIDERS = {
  CF_TURN_KEY_ID: 'key',
  CF_TURN_API_TOKEN: 'token',
  METERED_SUBDOMAIN: 'app',
  METERED_API_KEY: 'apikey',
};

/// A fresh env per call: the fake limiters count, so sharing one across tests
/// would make them depend on each other's traffic.
function makeEnv({ limiters = {}, ...extra } = {}) {
  return { ...PROVIDERS, ...limiterBindings(limiters), ...extra };
}

function stubUpstream({ cloudflare, metered }) {
  mock.method(globalThis, 'fetch', async (url) => {
    const href = typeof url === 'string' ? url : url.url;
    if (href.includes('cloudflare.com')) {
      if (cloudflare instanceof Error) return new Response('nope', { status: 500 });
      return new Response(JSON.stringify(cloudflare), { status: 201 });
    }
    if (href.includes('metered.live')) {
      if (metered instanceof Error) return new Response('nope', { status: 401 });
      return new Response(JSON.stringify(metered), { status: 200 });
    }
    throw new Error(`unexpected upstream call to ${href}`);
  });
}

function turnRequest(ip, headers = {}) {
  return new Request('https://worker.example/turn', {
    method: 'POST',
    headers: ip ? { 'CF-Connecting-IP': ip, ...headers } : headers,
  });
}

async function callTurn(env = makeEnv(), ip = '203.0.113.7') {
  const response = await worker.fetch(turnRequest(ip), env);
  return { status: response.status, body: await response.json(), response };
}

/// Upstream that must never be reached: records every call so a test can
/// assert there were none.
function forbidUpstream() {
  return mock.method(globalThis, 'fetch', async (url) => {
    throw new Error(`no provider call expected, got ${url}`);
  });
}

test('the documented Cloudflare + Metered payloads produce what the Dart client parses', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });

  const { status, body } = await callTurn();
  assert.equal(status, 200);

  // TurnCredentialService reads data['cloudflare']['iceServers'] and
  // data['metered']['iceServers'] and concatenates them.
  const merged = [...body.cloudflare.iceServers, ...body.metered.iceServers];
  const withCreds = merged.filter((s) => s.username && s.credential);
  assert.ok(withCreds.length >= 2, 'both providers must contribute credentials');

  // Every entry must carry `urls` as a LIST — the Dart side hands these
  // straight to RTCPeerConnection.
  for (const server of merged) {
    assert.ok(Array.isArray(server.urls), `urls must be a list, got ${typeof server.urls}`);
  }

  assert.equal(body.cloudflare.iceServers[1].username, 'cf-user');
  assert.equal(body.metered.iceServers[0].username, 'm-user');
  assert.ok(typeof body.expiresAt === 'string' && !Number.isNaN(Date.parse(body.expiresAt)));
});

test('TLS on 443 is offered ahead of plain UDP', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });

  const { body } = await callTurn();
  const relayUrls = body.cloudflare.iceServers
    .filter((s) => s.username)
    .map((s) => s.urls[0]);
  assert.equal(relayUrls[0], 'turns:turn.cloudflare.com:443?transport=tcp');
  assert.ok(relayUrls[1].startsWith('turn:'));
});

test('the sibling generate endpoint\'s single-object shape also yields credentials', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_SINGLE_OBJECT, metered: METERED_DOCUMENTED });

  const { status, body } = await callTurn();
  assert.equal(status, 200);
  assert.equal(body.cloudflare.iceServers[1].username, 'cf-object-user');
});

test("Metered's own TLS URL is preferred over the hardcoded OpenRelay host", async (t) => {
  t.after(() => mock.restoreAll());
  // A registered account relays through its own domain, not standard.relay.
  const ownDomain = METERED_DOCUMENTED.map((s) =>
    typeof s.urls === 'string'
      ? { ...s, urls: s.urls.replace('standard.relay.metered.ca', 'myapp.relay.metered.ca') }
      : s,
  );
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: ownDomain });

  const { body } = await callTurn();
  assert.equal(
    body.metered.iceServers[0].urls[0],
    'turns:myapp.relay.metered.ca:443?transport=tcp',
  );
});

test('one provider failing still returns the other', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: new Error('down'), metered: METERED_DOCUMENTED });

  const { status, body } = await callTurn();
  assert.equal(status, 200);
  assert.equal(body.cloudflare, undefined);
  assert.ok(body.metered.iceServers.length > 0);
});

test('both providers failing gives a 502 with a fixed code and the provider status for each', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: new Error('down'), metered: new Error('down') });

  const { status, body } = await callTurn();
  assert.equal(status, 502);
  assert.deepEqual(body, {
    error: 'provider_error',
    cloudflare: { error: 'http_error', status: 500 },
    metered: { error: 'http_error', status: 401 },
  });
});

/// Every log line the Worker wrote, parsed.
function logLines(logs) {
  return logs.map(({ args }) => JSON.parse(args[0]));
}

test('an unrecognised payload is described by its shape in the log, and by a fixed code in the 502', async (t) => {
  t.after(() => mock.restoreAll());
  const logs = captureLogs(t);
  stubUpstream({
    cloudflare: { iceServers: [{ urls: ['x'], user: 'renamed', secret: 'hunter2' }] },
    metered: new Error('down'),
  });

  const { status, body } = await callTurn();
  assert.equal(status, 502);
  assert.deepEqual(body.cloudflare, { error: 'bad_payload' });

  const line = logLines(logs).find((e) => e.scope === 'cloudflare');
  assert.match(line.shape, /urls,user,secret/, 'field names help calibration, in the log');
  const everything = JSON.stringify(body) + logs.map(({ args }) => args.join(' ')).join('\n');
  assert.ok(!everything.includes('hunter2'), 'values must not leak, anywhere');
});

test('an object payload is described by its field names only: not in the 502, not in the log', async (t) => {
  t.after(() => mock.restoreAll());
  const logs = captureLogs(t);
  // iceServers as a lone object without credentials takes the object branch
  // of the shape summary, which the array case above never reaches.
  stubUpstream({
    cloudflare: { iceServers: { secret: 'hunter2' } },
    metered: { tokens: 'hunter3', nested: { password: 'hunter4' } },
  });

  const { status, body } = await callTurn();
  assert.equal(status, 502);
  assert.deepEqual(body, {
    error: 'provider_error',
    cloudflare: { error: 'bad_payload' },
    metered: { error: 'bad_payload' },
  });

  const shapes = Object.fromEntries(
    logLines(logs).filter((e) => e.shape).map((e) => [e.scope, e.shape]),
  );
  assert.deepEqual(shapes, {
    cloudflare: 'object{secret}',
    metered: 'object{tokens,nested}',
  });
  const everything = JSON.stringify(body) + logs.map(({ args }) => args.join(' ')).join('\n');
  for (const value of ['hunter2', 'hunter3', 'hunter4']) {
    assert.ok(!everything.includes(value), `${value} leaked`);
  }
});

// --- nothing a provider or the runtime says is repeated to the caller --------
//
// An exception raised by `fetch` quotes the address it was given, and
// Metered's address carries the API key in its query string. A bad
// METERED_SUBDOMAIN is all it takes to put that key into a public 502.

const KEY = 'THE-SECRET-KEY-8f3a';

/// Ways an upstream call can blow up. Each one's message carries what the
/// request was made of, the way undici and workerd do.
const THROWERS = {
  'a URL the runtime cannot parse': (href) => new TypeError(`Failed to parse URL from ${href}`),
  'a connection that fails': (href) => {
    const e = new Error(`fetch failed: connect ECONNREFUSED while requesting ${href}`);
    e.cause = new Error(href);
    return e;
  },
  'a thrown string': (href) => `network error for ${href}`,
};

for (const [name, thrower] of Object.entries(THROWERS)) {
  test(`${name}: neither the 502 nor the logs repeat the address or the key`, async (t) => {
    t.after(() => mock.restoreAll());
    const logs = captureLogs(t);
    mock.method(globalThis, 'fetch', async (url) => {
      throw thrower(typeof url === 'string' ? url : url.url);
    });
    const env = makeEnv({
      METERED_SUBDOMAIN: 'bad host',
      METERED_API_KEY: KEY,
      CF_TURN_KEY_ID: 'cf-key-id-77',
      CF_TURN_API_TOKEN: 'cf-token-88',
    });

    const { status, body } = await callTurn(env);

    assert.equal(status, 502);
    assert.deepEqual(body, {
      error: 'provider_error',
      cloudflare: { error: 'unreachable' },
      metered: { error: 'unreachable' },
    });
    const everything = JSON.stringify(body) + logs.map(({ args }) => args.join(' ')).join('\n');
    for (const secret of [KEY, 'bad host', 'apiKey', 'cf-key-id-77', 'cf-token-88', 'metered.live']) {
      assert.ok(!everything.includes(secret), `"${secret}" reached the response or a log`);
    }
  });
}

test('the same, with the real fetch failing on a malformed Metered host', async (t) => {
  t.after(() => mock.restoreAll());
  const logs = captureLogs(t);
  const realFetch = globalThis.fetch;
  // Cloudflare is down; Metered goes to the genuine fetch, which refuses
  // `https://bad host...` before any network is touched.
  mock.method(globalThis, 'fetch', async (url, init) => {
    const href = typeof url === 'string' ? url : url.url;
    if (href.includes('cloudflare.com')) return new Response('nope', { status: 500 });
    return realFetch(url, init);
  });

  const { status, body } = await callTurn(
    makeEnv({ METERED_SUBDOMAIN: 'bad host', METERED_API_KEY: KEY }),
  );

  assert.equal(status, 502);
  assert.deepEqual(body.metered, { error: 'unreachable' });
  const everything = JSON.stringify(body) + logs.map(({ args }) => args.join(' ')).join('\n');
  assert.ok(!everything.includes(KEY), 'the API key reached the response or a log');
});

test('a provider answering 200 with a body that is not JSON cannot echo that body', async (t) => {
  t.after(() => mock.restoreAll());
  const logs = captureLogs(t);
  mock.method(globalThis, 'fetch', async (url) => {
    const href = typeof url === 'string' ? url : url.url;
    // JSON.parse quotes the start of the text it rejects.
    const html = href.includes('cloudflare.com')
      ? `<html>cf-reflected-secret ${KEY}</html>`
      : `{"bad": ${KEY}`;
    return new Response(html, { status: 200 });
  });

  const { status, body } = await callTurn();

  assert.equal(status, 502);
  assert.deepEqual(body, {
    error: 'provider_error',
    cloudflare: { error: 'bad_payload' },
    metered: { error: 'bad_payload' },
  });
  const everything = JSON.stringify(body) + logs.map(({ args }) => args.join(' ')).join('\n');
  assert.ok(!everything.includes(KEY));
  assert.ok(!everything.includes('cf-reflected-secret'));
});

test('only fixed words and numbers appear in a 502, whatever the providers say', async (t) => {
  t.after(() => mock.restoreAll());
  // Statuses are the one upstream value a caller gets back, and only as a
  // number; nothing the providers wrote is repeated.
  mock.method(globalThis, 'fetch', async () =>
    new Response(JSON.stringify({ message: KEY, error: KEY }), {
      status: 503,
      statusText: KEY,
      headers: { 'X-Echo': KEY },
    }),
  );

  const { status, body, response } = await callTurn();

  assert.equal(status, 502);
  assert.deepEqual(body, {
    error: 'provider_error',
    cloudflare: { error: 'http_error', status: 503 },
    metered: { error: 'http_error', status: 503 },
  });
  assert.ok(![...response.headers.values()].some((v) => v.includes(KEY)));
});

// --- the credentials are asked for, and promised, for 30 minutes -------------

test('Cloudflare is asked for 30-minute credentials, and the response promises 30 minutes', async (t) => {
  t.after(() => mock.restoreAll());
  const asked = [];
  mock.method(globalThis, 'fetch', async (url, init) => {
    const href = typeof url === 'string' ? url : url.url;
    if (href.includes('cloudflare.com')) {
      asked.push(JSON.parse(init.body));
      return new Response(JSON.stringify(CLOUDFLARE_DOCUMENTED), { status: 201 });
    }
    return new Response(JSON.stringify(METERED_DOCUMENTED), { status: 200 });
  });

  const before = Date.now();
  const { body } = await callTurn();
  const after = Date.now();

  assert.deepEqual(asked, [{ ttl: 1800 }], 'what the upstream is told to mint');
  const expiry = Date.parse(body.expiresAt);
  // What the client schedules its refresh from: it must not be later than the
  // credentials really stop working.
  assert.ok(expiry >= before + 1_800_000, 'not shorter than the credentials last');
  assert.ok(expiry <= after + 1_800_000, `promises ${(expiry - after) / 60_000} min`);
});

// --- the caller cannot choose its own bucket ---------------------------------

test('a forged X-Forwarded-For, rotated on every request, still meets the limit', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });
  const env = makeEnv({ limiters: { overrides: { RL_TURN_IP: 2 } } });
  const forged = ['X-Forwarded-For', 'X-Real-IP', 'True-Client-IP', 'Forwarded', 'X-Client-IP'];

  const seen = [];
  for (let i = 0; i < 6; i++) {
    const headers = Object.fromEntries(forged.map((h) => [h, `198.51.100.${i + 1}`]));
    const response = await worker.fetch(turnRequest('203.0.113.7', headers), env);
    seen.push(response.status);
  }
  assert.deepEqual(seen, [200, 200, 429, 429, 429, 429]);
  assert.deepEqual([...new Set(env.RL_TURN_IP.calls)], ['203.0.113.7'], 'one bucket, the real one');
});

test('with no CF-Connecting-IP a rotating X-Forwarded-For still shares one bucket', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });
  const env = makeEnv({ limiters: { overrides: { RL_TURN_IP: 2 } } });

  const seen = [];
  for (let i = 0; i < 4; i++) {
    const response = await worker.fetch(
      turnRequest(null, { 'X-Forwarded-For': `198.51.100.${i + 1}` }),
      env,
    );
    seen.push(response.status);
  }
  assert.deepEqual(seen, [200, 200, 429, 429]);
  assert.equal(new Set(env.RL_TURN_IP.calls).size, 1);
});
test('with only Cloudflare configured, Metered is skipped rather than attempted', async (t) => {
  t.after(() => mock.restoreAll());
  // Fails the test outright if the Worker calls metered.live at all: an
  // unconfigured provider must cost zero requests, not one 401 per call.
  mock.method(globalThis, 'fetch', async (url) => {
    const href = typeof url === 'string' ? url : url.url;
    if (href.includes('metered.live')) {
      throw new Error('metered must not be called when it is not configured');
    }
    return new Response(JSON.stringify(CLOUDFLARE_DOCUMENTED), { status: 201 });
  });

  const cloudflareOnly = {
    CF_TURN_KEY_ID: 'key',
    CF_TURN_API_TOKEN: 'token',
    ...limiterBindings(),
  };
  const response = await worker.fetch(turnRequest('203.0.113.7'), cloudflareOnly);
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.equal(body.cloudflare.iceServers[1].username, 'cf-user');
  assert.equal(body.metered, undefined);
  assert.match(body.skipped.join(' '), /metered is not configured/);
});

// --- /turn is public: no shared secret, abuse is bounded by rate limits -----
//
// A secret compiled into a public binary protects nothing, so DD-02's HMAC is
// gone. These tests pin both halves: old clients still work, and the limits
// that replaced the secret are enforced before anything costs money.

test('POST /turn needs no secret and no signature headers', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });

  const env = makeEnv();
  assert.equal(env.TURN_CLIENT_SECRET, undefined);
  const response = await worker.fetch(turnRequest('203.0.113.7'), env);

  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), null, 'no CORS wildcard');
  assert.ok((await response.json()).cloudflare.iceServers.length > 0);
});

test('signature headers from old clients are ignored, whatever they hold', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });

  const stale = String(Math.floor(Date.now() / 1000) - 86_400);
  const variants = [
    { 'X-DD-Ts': String(Math.floor(Date.now() / 1000)), 'X-DD-Mac': 'a'.repeat(64) },
    { 'X-DD-Ts': stale, 'X-DD-Mac': 'deadbeef' },
    { 'X-DD-Ts': 'not-a-number', 'X-DD-Mac': '' },
    { 'X-DD-Mac': 'only-a-mac' },
  ];
  for (const headers of variants) {
    const response = await worker.fetch(
      turnRequest('203.0.113.7', headers),
      makeEnv(),
    );
    assert.equal(response.status, 200, JSON.stringify(headers));
  }
});

test('over the per-IP limit /turn answers 429 and never calls a provider', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });

  let clock = 1_000_000;
  const env = makeEnv({ limiters: { now: () => clock } });
  for (let i = 0; i < 20; i++) {
    const ok = await worker.fetch(turnRequest('203.0.113.7'), env);
    assert.equal(ok.status, 200, `request ${i + 1} is within the limit of 20`);
  }
  const upstreamCalls = globalThis.fetch.mock.callCount();

  const limited = await worker.fetch(turnRequest('203.0.113.7'), env);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('Retry-After'), '60');
  assert.match(limited.headers.get('Content-Type'), /application\/json/);
  assert.equal(limited.headers.get('Access-Control-Allow-Origin'), null);
  assert.deepEqual(await limited.json(), { error: 'rate_limited', scope: 'turn_ip' });
  assert.equal(globalThis.fetch.mock.callCount(), upstreamCalls, 'provider must not be called');

  const neighbour = await worker.fetch(turnRequest('203.0.113.8'), env);
  assert.equal(neighbour.status, 200, 'another IP has its own bucket');

  clock += 60_000;
  const nextWindow = await worker.fetch(turnRequest('203.0.113.7'), env);
  assert.equal(nextWindow.status, 200, 'the limit is per minute, not forever');
});

test('over the global limit /turn answers 429 with the global scope', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });

  const env = makeEnv({ limiters: { overrides: { RL_TURN_GLOBAL: 3 } } });
  for (let i = 1; i <= 3; i++) {
    const ok = await worker.fetch(turnRequest(`198.51.100.${i}`), env);
    assert.equal(ok.status, 200);
  }
  const upstreamCalls = globalThis.fetch.mock.callCount();

  const limited = await worker.fetch(turnRequest('198.51.100.4'), env);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('Retry-After'), '60');
  assert.deepEqual(await limited.json(), { error: 'rate_limited', scope: 'turn_global' });
  assert.equal(globalThis.fetch.mock.callCount(), upstreamCalls);
});

test('a request refused for its IP does not spend the global budget', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });

  const env = makeEnv({
    limiters: { overrides: { RL_TURN_IP: 2, RL_TURN_GLOBAL: 3 } },
  });
  const status = async (ip) => (await worker.fetch(turnRequest(ip), env)).status;

  assert.equal(await status('203.0.113.1'), 200);
  assert.equal(await status('203.0.113.1'), 200);
  for (let i = 0; i < 10; i++) {
    assert.equal(await status('203.0.113.1'), 429);
  }
  // One global token is left, because the ten refusals above never reached it.
  assert.equal(await status('203.0.113.2'), 200);
  assert.equal(await status('203.0.113.3'), 429);
});

test('with a limiter binding missing /turn fails closed: 503 and no provider call', async (t) => {
  t.after(() => mock.restoreAll());
  for (const name of ['RL_TURN_IP', 'RL_TURN_GLOBAL']) {
    const upstream = forbidUpstream();
    const env = makeEnv();
    delete env[name];

    const { status, body, response } = await callTurn(env);
    assert.equal(status, 503, `${name} missing`);
    assert.deepEqual(body, { error: 'limiter_unavailable' });
    assert.equal(response.headers.get('Access-Control-Allow-Origin'), null);
    assert.equal(response.headers.get('Retry-After'), '60', 'a sane wait, not a hammering client');
    assert.equal(upstream.mock.callCount(), 0, 'an unguarded mint is the one thing to avoid');
    mock.restoreAll();
  }
});

test('with a limiter that throws /turn fails closed: 503 and no provider call', async (t) => {
  t.after(() => mock.restoreAll());
  for (const name of ['RL_TURN_IP', 'RL_TURN_GLOBAL']) {
    const upstream = forbidUpstream();
    const { status, body, response } = await callTurn(makeEnv({ [name]: throwingLimiter() }));
    assert.equal(status, 503, `${name} throwing`);
    assert.deepEqual(body, { error: 'limiter_unavailable' });
    assert.equal(response.headers.get('Retry-After'), '60');
    assert.equal(upstream.mock.callCount(), 0);
    mock.restoreAll();
  }
});

test('IPv6 clients in one /64 share a /turn bucket; other prefixes do not', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });

  const env = makeEnv({ limiters: { overrides: { RL_TURN_IP: 3 } } });
  const status = async (ip) => (await worker.fetch(turnRequest(ip), env)).status;

  // Same 2001:db8:1:2::/64, written three different ways. A client who owns
  // the whole /64 would otherwise get 2^64 buckets.
  assert.equal(await status('2001:db8:1:2::1'), 200);
  assert.equal(await status('2001:0DB8:0001:0002:aaaa:bbbb:cccc:dddd'), 200);
  assert.equal(await status('2001:db8:1:2:ffff:ffff:ffff:ffff'), 200);
  assert.equal(await status('2001:db8:1:2:1234::9'), 429, 'fourth address, same /64');
  assert.equal(await status('2001:db8:1:3::1'), 200, 'the next /64 is a different client');
});

test('an IPv4-mapped IPv6 address is bucketed as the IPv4 address it carries', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });

  // If this were bucketed as a /64 every IPv4 client would share one bucket.
  const env = makeEnv({ limiters: { overrides: { RL_TURN_IP: 1 } } });
  const status = async (ip) => (await worker.fetch(turnRequest(ip), env)).status;

  assert.equal(await status('::ffff:192.0.2.1'), 200);
  assert.equal(await status('192.0.2.1'), 429, 'the same host, so the same bucket');
  assert.equal(await status('::ffff:192.0.2.2'), 200, 'a different host is not affected');
});

test('TURN_ENABLED=false is a kill switch: 503 relay_disabled and no provider call', async (t) => {
  t.after(() => mock.restoreAll());
  for (const value of ['false', 'FALSE', ' False ']) {
    const upstream = forbidUpstream();
    const { status, body, response } = await callTurn(makeEnv({ TURN_ENABLED: value }));
    assert.equal(status, 503, JSON.stringify(value));
    assert.deepEqual(body, { error: 'relay_disabled' });
    assert.equal(response.headers.get('Access-Control-Allow-Origin'), null);
    assert.equal(upstream.mock.callCount(), 0);
    mock.restoreAll();
  }
});

test('anything but "false" leaves /turn enabled', async (t) => {
  t.after(() => mock.restoreAll());
  for (const value of [undefined, 'true', '', '1']) {
    mock.restoreAll();
    stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });
    const env = makeEnv();
    if (value !== undefined) env.TURN_ENABLED = value;
    const { status } = await callTurn(env);
    assert.equal(status, 200, `TURN_ENABLED=${JSON.stringify(value)}`);
  }
});

test('with no provider configured /turn is 503 relay_unconfigured, calling nothing', async (t) => {
  t.after(() => mock.restoreAll());
  const upstream = forbidUpstream();

  const { status, body } = await callTurn({ ...limiterBindings() });

  assert.equal(status, 503);
  assert.deepEqual(body, { error: 'relay_unconfigured' });
  assert.equal(upstream.mock.callCount(), 0);
});

test('429, 503 and provider failures are one-line JSON logs with no IP or credential', async (t) => {
  t.after(() => mock.restoreAll());
  const logs = captureLogs(t);
  const v4 = '203.0.113.77';
  const v6 = '2001:db8:abcd:12:1:2:3:4';

  // 429: the second request from the same address.
  const limited = makeEnv({ limiters: { overrides: { RL_TURN_IP: 1 } } });
  stubUpstream({ cloudflare: new Error('down'), metered: new Error('down') });
  await worker.fetch(turnRequest(v4), limited);
  assert.equal((await worker.fetch(turnRequest(v4), limited)).status, 429);
  // 503: limiter gone, then the kill switch.
  await worker.fetch(turnRequest(v6), makeEnv({ RL_TURN_IP: throwingLimiter() }));
  await worker.fetch(turnRequest(v6), makeEnv({ TURN_ENABLED: 'false' }));
  // Provider failures (502): from the first request above, whose upstream is
  // the two stubbed 500/401 answers.

  const entries = logs.map(({ args }) => {
    assert.equal(args.length, 1, 'a single argument, so it stays one log line');
    assert.equal(typeof args[0], 'string');
    assert.ok(!args[0].includes('\n'), 'one line');
    return JSON.parse(args[0]);
  });
  const events = new Set(entries.map((e) => e.event));
  for (const event of ['rate_limited', 'limiter_unavailable', 'relay_disabled', 'provider_error']) {
    assert.ok(events.has(event), `missing a "${event}" log line`);
  }
  const allowed = new Set(['event', 'route', 'scope', 'status', 'shape']);
  for (const entry of entries) {
    assert.deepEqual(
      Object.keys(entry).filter((k) => !allowed.has(k)),
      [],
      `unexpected fields in ${JSON.stringify(entry)}`,
    );
    assert.equal(entry.route, '/turn');
  }
  const limitedLine = entries.find((e) => e.event === 'rate_limited');
  assert.deepEqual(limitedLine, {
    event: 'rate_limited',
    route: '/turn',
    scope: 'turn_ip',
    status: 429,
  });

  const everything = logs.map(({ args }) => args.join(' ')).join('\n');
  for (const secret of ['203.0.113', '2001:db8', 'abcd:12', 'cf-cred', 'cf-user', 'apikey', 'token']) {
    assert.ok(!everything.includes(secret), `logs must not contain ${secret}`);
  }
});

test('upstream error response body is not leaked into 502 error message', async (t) => {
  t.after(() => mock.restoreAll());
  const sensitiveLeak = 'super_secret_upstream_token_and_internal_stack_trace';
  mock.method(globalThis, 'fetch', async (url) => {
    const href = typeof url === 'string' ? url : url.url;
    if (href.includes('cloudflare.com')) {
      return new Response(JSON.stringify({ error: sensitiveLeak }), { status: 500 });
    }
    if (href.includes('metered.live')) {
      return new Response(sensitiveLeak, { status: 502 });
    }
    throw new Error(`unexpected upstream call to ${href}`);
  });

  const { status, body } = await callTurn();
  assert.equal(status, 502);
  assert.ok(!JSON.stringify(body).includes(sensitiveLeak), 'upstream body must not leak into response');
  assert.deepEqual(body.cloudflare, { error: 'http_error', status: 500 });
  assert.deepEqual(body.metered, { error: 'http_error', status: 502 });
});

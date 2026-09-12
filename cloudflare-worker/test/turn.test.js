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
import { createHmac } from 'node:crypto';

import worker from '../src/index.js';

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

const ENV = {
  CF_TURN_KEY_ID: 'key',
  CF_TURN_API_TOKEN: 'token',
  METERED_SUBDOMAIN: 'app',
  METERED_API_KEY: 'apikey',
  TURN_CLIENT_SECRET: 's3cret',
};

function turnHeaders(secret = ENV.TURN_CLIENT_SECRET, now = Date.now()) {
  const ts = Math.floor(now / 1000).toString();
  const mac = createHmac('sha256', secret).update(ts).digest('hex');
  return { 'X-DD-Ts': ts, 'X-DD-Mac': mac };
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

async function callTurn() {
  const response = await worker.fetch(
    new Request('https://worker.example/turn', {
      method: 'POST',
      headers: turnHeaders(),
    }),
    ENV,
  );
  return { status: response.status, body: await response.json() };
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

test('both providers failing gives a 502 that names each cause', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: new Error('down'), metered: new Error('down') });

  const { status, body } = await callTurn();
  assert.equal(status, 502);
  assert.match(body.cloudflare.error, /500/);
  assert.match(body.metered.error, /401/);
});

test('an unrecognised payload reports the shape but never the values', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({
    cloudflare: { iceServers: [{ urls: ['x'], user: 'renamed', secret: 'hunter2' }] },
    metered: new Error('down'),
  });

  const { status, body } = await callTurn();
  assert.equal(status, 502);
  assert.match(body.cloudflare.error, /urls,user,secret/, 'field names help calibration');
  assert.ok(
    !body.cloudflare.error.includes('hunter2'),
    'values must not leak into the response',
  );
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
    TURN_CLIENT_SECRET: ENV.TURN_CLIENT_SECRET,
  };
  const response = await worker.fetch(
    new Request('https://worker.example/turn', {
      method: 'POST',
      headers: turnHeaders(),
    }),
    cloudflareOnly,
  );
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.equal(body.cloudflare.iceServers[1].username, 'cf-user');
  assert.equal(body.metered, undefined);
  assert.match(body.skipped.join(' '), /metered is not configured/);
});

test('with no client secret configured, /turn is 503 not an open mint', async (t) => {
  t.after(() => mock.restoreAll());
  mock.method(globalThis, 'fetch', async () => {
    throw new Error('no upstream call should happen at all');
  });

  const response = await worker.fetch(
    new Request('https://worker.example/turn', { method: 'POST' }),
    {},
  );

  assert.equal(response.status, 503);
  assert.match(await response.text(), /not configured/);
});

// DD-02: anyone could POST /turn and mint Cloudflare Calls credentials.
test('POST /turn without a signature is refused', async () => {
  const response = await worker.fetch(
    new Request('https://worker.example/turn', { method: 'POST' }),
    { ...ENV, TURN_CLIENT_SECRET: 's3cret' },
  );
  assert.equal(response.status, 401);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), null);
});

test('POST /turn with a valid signature is served and has no CORS wildcard', async (t) => {
  t.after(() => mock.restoreAll());
  stubUpstream({ cloudflare: CLOUDFLARE_DOCUMENTED, metered: METERED_DOCUMENTED });
  const { status, body } = await callTurn();
  assert.equal(status, 200);
  assert.ok(body.cloudflare.iceServers.length > 0);
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
  assert.match(body.cloudflare.error, /500/);
  assert.match(body.metered.error, /502/);
});




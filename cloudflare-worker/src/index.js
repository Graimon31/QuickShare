// DirectDrop rendezvous + TURN-credential Worker.
//
// Two independent jobs live in one Worker because they share the same
// deploy/secrets story, not because they share data:
//   POST /turn        -> short-lived TURN credentials (Cloudflare Calls + Metered)
//   POST/GET /r/:room -> blind KV mailbox for an encrypted SDP blob (reserve
//                         rendezvous channel; Nostr relays remain the primary
//                         path, see AI_BRIEF_RENDEZVOUS.md at repo root)
//
// The Worker never sees plaintext file data or file keys. For /r/:room it
// doesn't even know what it's storing — client encrypts, Worker just holds
// bytes for up to TTL_SECONDS.

const TTL_SECONDS = 30 * 60; // matches the spec's 30-minute room lifetime
const MAX_BLOB_BYTES = 8 * 1024; // encrypted SDP + AEAD overhead, generous headroom
const ROOM_ID_RE = /^[A-Za-z0-9_-]{16,64}$/; // base64url, no padding

function withCors(response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
  return response;
}

/// HMAC-SHA256 hex of [message] under [secret].
async function hmacSha256Hex(secret, message) {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(message),
  );
  return [...new Uint8Array(sig)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

function timingSafeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

/// DD-02: /turn mints live TURN credentials. A browser page with CORS *
/// used to be enough to drain the project's Cloudflare Calls quota. The
/// client signs the unix timestamp with TURN_CLIENT_SECRET; a missing
/// secret is a misconfigured deploy, not an open endpoint.
const TURN_AUTH_WINDOW_SECONDS = 300;

async function authorizeTurn(request, env) {
  const secret = env.TURN_CLIENT_SECRET;
  if (!secret) {
    return text('turn client secret is not configured', 503, { cors: false });
  }
  const ts = request.headers.get('X-DD-Ts');
  const mac = request.headers.get('X-DD-Mac');
  if (!ts || !mac) return text('unauthorized', 401, { cors: false });
  const t = Number(ts);
  const now = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(t) || Math.abs(now - t) > TURN_AUTH_WINDOW_SECONDS) {
    return text('unauthorized', 401, { cors: false });
  }
  const expected = await hmacSha256Hex(secret, ts);
  if (!timingSafeEqual(expected, mac.toLowerCase())) {
    return text('unauthorized', 401, { cors: false });
  }
  return null;
}

function json(body, init = {}) {
  const { cors = true, ...rest } = init;
  const response = new Response(JSON.stringify(body), {
    ...rest,
    headers: { 'Content-Type': 'application/json', ...(rest.headers) },
  });
  return cors ? withCors(response) : response;
}

function text(body, status, { cors = true } = {}) {
  const response = new Response(body, { status });
  return cors ? withCors(response) : response;
}

/// Summarises an unexpected upstream payload without echoing its values.
///
/// Field *names* are what a shape mismatch is about and are safe to hand back;
/// the values are live TURN credentials and stay out of both the HTTP response
/// and logs. The structural summary goes to `console.log` (`wrangler tail`),
/// visible to the operator, not to whoever called /turn.
function describeShape(data) {
  if (Array.isArray(data)) {
    return `array[${data.length}] of ${
      data.length ? `{${Object.keys(data[0] ?? {}).join(',')}}` : 'nothing'
    }`;
  }
  if (data && typeof data === 'object') {
    return `object{${Object.keys(data).join(',')}}`;
  }
  return typeof data;
}

/// Raised when a provider's secrets were never set.
///
/// A provider nobody configured is not a failure worth diagnosing — running
/// with only Cloudflare is a legitimate setup, and Metered can be added later
/// by setting two secrets and nothing else. Without this the Worker would ask
/// `undefined.metered.live` for credentials on every single call and report
/// its 401 as if something had broken.
class NotConfigured extends Error {
  constructor(provider, names) {
    super(`${provider} is not configured (missing ${names.join(', ')})`);
    this.notConfigured = true;
  }
}

function requireSecrets(env, provider, names) {
  const missing = names.filter((n) => !env[n]);
  if (missing.length) throw new NotConfigured(provider, missing);
}

/// Pulls username/credential out of either shape Cloudflare's TURN API serves.
///
/// Not a legacy fallback — both are current, documented endpoints that differ
/// only in packaging:
///   `credentials/generate-ice-servers` -> iceServers is an ARRAY (a STUN
///       entry with no credentials, then a TURN entry with them)
///   `credentials/generate`             -> iceServers is a single OBJECT
///       carrying urls/username/credential
///
/// We call the first. The object branch is therefore unreachable today and
/// exists so that switching the URL above stays a one-line change; keep it
/// only as long as that is worth four lines. Metered's array is handled by the
/// same code, which is the other reason it is shaped this way.
function extractCredentials(iceServers) {
  if (Array.isArray(iceServers)) {
    return iceServers.find((s) => s && s.username && s.credential) ?? null;
  }
  if (iceServers && iceServers.username && iceServers.credential) {
    return iceServers;
  }
  return null;
}

async function fetchCloudflareTurn(env) {
  requireSecrets(env, 'cloudflare', ['CF_TURN_KEY_ID', 'CF_TURN_API_TOKEN']);

  // `generate-ice-servers`, not `generate`: this is the endpoint Cloudflare
  // documents, and it returns a list already shaped like RTCPeerConnection's
  // iceServers.
  const res = await fetch(
    `https://rtc.live.cloudflare.com/v1/turn/keys/${env.CF_TURN_KEY_ID}/credentials/generate-ice-servers`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.CF_TURN_API_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ ttl: TTL_SECONDS }),
    },
  );
  if (!res.ok) {
    const errorText = await res.text().catch(() => '');
    let shape = typeof errorText;
    try {
      shape = describeShape(JSON.parse(errorText));
    } catch (_) {}
    console.log(`cloudflare turn credential fetch failed (${res.status}):`, shape);
    throw new Error(`cloudflare turn credential fetch failed: ${res.status}`);
  }

  const data = await res.json();
  const creds = extractCredentials(data.iceServers ?? data);
  if (!creds) {
    console.log(
      'cloudflare /turn unexpected payload shape:',
      describeShape(data.iceServers ?? data),
    );
    throw new Error(
      `cloudflare turn response carried no credentials (got ${describeShape(
        data.iceServers ?? data,
      )})`,
    );
  }

  // Transports are pinned rather than passed through verbatim. Cloudflare
  // returns every port it supports in one entry, best-first ordering not
  // guaranteed; ТЗ §2.3 wants TLS/443/TCP tried first, because that is the
  // shape the always-on VPN carries as ordinary HTTPS.
  return {
    iceServers: [
      { urls: ['stun:stun.cloudflare.com:3478'] },
      {
        urls: ['turns:turn.cloudflare.com:443?transport=tcp'],
        username: creds.username,
        credential: creds.credential,
      },
      {
        urls: ['turn:turn.cloudflare.com:3478?transport=udp'],
        username: creds.username,
        credential: creds.credential,
      },
    ],
  };
}

/// Metered answers with an array whose `urls` is a STRING per entry, one entry
/// per port/transport.
///
/// Their TLS/443 entry is preferred over a hardcoded host because the relay
/// domain differs per account — `standard.relay.metered.ca` is the free
/// OpenRelay name, and a registered app gets its own. The constant below is
/// only the fallback for when no 443 entry comes back.
function pickMeteredTlsUrl(servers) {
  if (!Array.isArray(servers)) return null;
  const tls = servers.find(
    (s) =>
      s &&
      typeof s.urls === 'string' &&
      s.urls.startsWith('turns:') &&
      s.urls.includes('443'),
  );
  return tls ? tls.urls : null;
}

async function fetchMeteredTurn(env) {
  requireSecrets(env, 'metered', ['METERED_SUBDOMAIN', 'METERED_API_KEY']);

  const res = await fetch(
    `https://${env.METERED_SUBDOMAIN}.metered.live/api/v1/turn/credentials?apiKey=${env.METERED_API_KEY}`,
  );
  if (!res.ok) {
    const errorText = await res.text().catch(() => '');
    let shape = typeof errorText;
    try {
      shape = describeShape(JSON.parse(errorText));
    } catch (_) {}
    console.log(`metered turn credential fetch failed (${res.status}):`, shape);
    throw new Error(`metered turn credential fetch failed: ${res.status}`);
  }

  const servers = await res.json();
  const creds = extractCredentials(servers);
  if (!creds) {
    console.log('metered /turn unexpected payload shape:', describeShape(servers));
    throw new Error(
      `metered response carried no credentials (got ${describeShape(servers)})`,
    );
  }

  const url =
    pickMeteredTlsUrl(servers) ??
    'turns:standard.relay.metered.ca:443?transport=tcp';

  return {
    iceServers: [
      {
        urls: [url],
        username: creds.username,
        credential: creds.credential,
      },
    ],
  };
}

async function handleTurn(env) {
  const [cloudflare, metered] = await Promise.allSettled([
    fetchCloudflareTurn(env),
    fetchMeteredTurn(env),
  ]);

  if (cloudflare.status === 'rejected' && metered.status === 'rejected') {
    // An unconfigured provider is reported as `skipped` rather than as an
    // error, so a Cloudflare-only deployment that genuinely breaks still reads
    // as one clear failure instead of two.
    const describe = (r) =>
      r.reason && r.reason.notConfigured
        ? { skipped: r.reason.message }
        : { error: String(r.reason) };

    return json(
      {
        error: 'no TURN provider available',
        cloudflare: describe(cloudflare),
        metered: describe(metered),
      },
      { status: 502, cors: false },
    );
  }

  const body = { expiresAt: new Date(Date.now() + TTL_SECONDS * 1000).toISOString() };
  if (cloudflare.status === 'fulfilled') body.cloudflare = cloudflare.value;
  if (metered.status === 'fulfilled') body.metered = metered.value;

  // Name what did not come back, so a half-configured deploy is visible in the
  // response rather than only in the logs.
  const skipped = [cloudflare, metered]
    .filter((r) => r.status === 'rejected' && r.reason && r.reason.notConfigured)
    .map((r) => r.reason.message);
  if (skipped.length) body.skipped = skipped;

  return json(body, { cors: false });
}

async function handleRoomPost(request, env, roomId) {
  if (!ROOM_ID_RE.test(roomId)) {
    return text('invalid room id', 400);
  }
  const contentLength = request.headers.get('content-length');
  if (contentLength !== null) {
    const len = parseInt(contentLength, 10);
    if (isNaN(len) || len <= 0 || len > MAX_BLOB_BYTES) {
      return text('invalid blob size', 400);
    }
  }
  const blob = await request.arrayBuffer();
  if (blob.byteLength === 0 || blob.byteLength > MAX_BLOB_BYTES) {
    return text('invalid blob size', 400);
  }
  // Plain overwrite, not create-once: the room is a bulletin board a sender
  // and receiver can both post to during a handshake (offer, then answer),
  // not a single-write slot. Each POST also refreshes the TTL.
  await env.RENDEZVOUS_KV.put(`room:${roomId}`, blob, { expirationTtl: TTL_SECONDS });
  return text(null, 201);
}

async function handleRoomGet(env, roomId) {
  if (!ROOM_ID_RE.test(roomId)) {
    return text('invalid room id', 400);
  }
  const blob = await env.RENDEZVOUS_KV.get(`room:${roomId}`, 'arrayBuffer');
  if (blob === null) {
    return text('not found', 404);
  }
  return withCors(
    new Response(blob, { headers: { 'Content-Type': 'application/octet-stream' } }),
  );
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return withCors(new Response(null, { status: 204 }));
    }

    if (request.method === 'POST' && url.pathname === '/turn') {
      const denied = await authorizeTurn(request, env);
      if (denied) return denied;
      return handleTurn(env);
    }

    const roomMatch = url.pathname.match(/^\/r\/([^/]+)$/);
    if (roomMatch) {
      let roomId;
      try {
        roomId = decodeURIComponent(roomMatch[1]);
      } catch {
        return text('invalid room id', 400);
      }
      if (request.method === 'POST') return handleRoomPost(request, env, roomId);
      if (request.method === 'GET') return handleRoomGet(env, roomId);
    }

    return text('not found', 404);
  },
};

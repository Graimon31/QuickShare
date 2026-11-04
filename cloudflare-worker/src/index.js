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
//
// Both routes are public. /turn used to demand an HMAC from the client, but a
// secret compiled into a public binary protects nothing, so abuse is bounded
// by rate limits instead (see "Rate limiting" below) plus a kill switch.

const TTL_SECONDS = 30 * 60; // matches the spec's 30-minute room lifetime
const MAX_BLOB_BYTES = 8 * 1024; // encrypted SDP + AEAD overhead, generous headroom
const ROOM_ID_RE = /^[A-Za-z0-9_-]{16,64}$/; // base64url, no padding
const RETRY_AFTER_SECONDS = '60'; // the rate-limit window, and a sane wait after a 503

function withCors(response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
  return response;
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

/// One JSON object per line, so Workers Logs can filter on the fields.
///
/// Callers pass `{event, route, scope, status}` and nothing else but, for
/// provider errors, a structural `shape`. No client address, room id, token or
/// credential goes through here, and none may be added.
function logEvent(fields, level = 'log') {
  console[level](JSON.stringify(fields));
}

// --- Rate limiting ----------------------------------------------------------
//
// Workers Rate Limiting bindings (`[[ratelimits]]` in wrangler.toml, one
// namespace each; the numbers live there, not here). Every window is 60 s.
//
//   RL_TURN_IP           /turn, per client
//   RL_TURN_GLOBAL       /turn, one shared bucket (key "global")
//   RL_ROOM_POST_IP      POST /r/:id, per client
//   RL_ROOM_POST_GLOBAL  POST /r/:id, one shared bucket; guards KV writes
//   RL_ROOM_GET_IP       GET /r/:id, per client; a waiting sender polls every
//                        2 s, so 30/min, and several devices can share a NAT
//
// The "global" buckets are only as global as the binding: Cloudflare counts
// per location, so each data centre has its own allowance and the true ceiling
// is limit x locations reached. They bound a burst, not a monthly bill.
//
// The per-client check runs first, so a client already over its own limit
// never spends the shared budget.
const TURN_LIMITS = [
  { scope: 'turn_ip', binding: 'RL_TURN_IP', perClient: true },
  { scope: 'turn_global', binding: 'RL_TURN_GLOBAL', perClient: false },
];
const ROOM_POST_LIMITS = [
  { scope: 'room_post_ip', binding: 'RL_ROOM_POST_IP', perClient: true },
  { scope: 'room_post_global', binding: 'RL_ROOM_POST_GLOBAL', perClient: false },
];
const ROOM_GET_LIMITS = [
  { scope: 'room_get_ip', binding: 'RL_ROOM_GET_IP', perClient: true },
];

/// The 8 sixteen-bit groups of an IPv6 text address, or null if it is not one.
function ipv6Groups(ip) {
  let addr = ip.toLowerCase();
  // A dotted IPv4 tail (::ffff:192.0.2.1) is the last two groups in disguise.
  const dotted = addr.match(/^(.*:)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (dotted) {
    const [a, b, c, d] = dotted.slice(2).map(Number);
    if ([a, b, c, d].some((n) => n > 255)) return null;
    addr = `${dotted[1]}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const halves = addr.split('::');
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const gap = 8 - head.length - tail.length;
  if (halves.length === 2 ? gap < 1 : gap !== 0) return null;
  const groups = [...head, ...Array(halves.length === 2 ? gap : 0).fill('0'), ...tail];
  if (!groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return null;
  return groups.map((g) => parseInt(g, 16));
}

/// The bucket a caller is counted in.
///
/// CF-Connecting-IP is set by Cloudflare's edge and cannot be forged by a
/// client of a Worker that is only reachable through it. IPv6 is cut to the
/// /64: that is what one subscriber gets, and counting full addresses would
/// hand a single client 2^64 buckets. An IPv4-mapped address is the IPv4 host
/// it carries; treated as a /64 it would pool every IPv4 client into one.
function clientKey(request) {
  const ip = request.headers.get('CF-Connecting-IP')?.trim();
  if (!ip) return 'unknown'; // only outside Cloudflare, e.g. a bare workerd
  if (!ip.includes(':')) return ip;
  const g = ipv6Groups(ip);
  if (!g) return ip;
  if (g.slice(0, 5).every((x) => x === 0) && g[5] === 0xffff) {
    return `${g[6] >> 8}.${g[6] & 255}.${g[7] >> 8}.${g[7] & 255}`;
  }
  return `${g.slice(0, 4).map((x) => x.toString(16)).join(':')}::/64`;
}

/// Spends one token: 'ok', 'limited', or 'unavailable' when the binding is
/// missing or throws. What an outage means is the caller's policy.
async function spend(limiter, key) {
  if (!limiter || typeof limiter.limit !== 'function') return 'unavailable';
  try {
    const { success } = await limiter.limit({ key });
    return success ? 'ok' : 'limited';
  } catch (_) {
    return 'unavailable';
  }
}

/// Runs [limits] in order. Returns the Response that refuses the request, or
/// null to let it through.
///
/// [failOpen] is the answer to "the limiter itself is down". /turn fails
/// closed: an unguarded mint is the whole risk, and the client falls back to
/// STUN-only. The mailbox fails open: Nostr is the primary rendezvous, nothing
/// there costs money per call, and a limiter outage should not also take the
/// reserve channel down.
async function enforceLimits(request, env, route, limits, { failOpen, cors }) {
  const client = clientKey(request);
  for (const { scope, binding, perClient } of limits) {
    const verdict = await spend(env[binding], perClient ? client : 'global');
    if (verdict === 'limited') {
      logEvent({ event: 'rate_limited', route, scope, status: 429 });
      return json(
        { error: 'rate_limited', scope },
        { status: 429, cors, headers: { 'Retry-After': RETRY_AFTER_SECONDS } },
      );
    }
    if (verdict === 'unavailable') {
      if (failOpen) {
        logEvent({ event: 'limiter_fail_open', route, scope }, 'warn');
        continue;
      }
      logEvent({ event: 'limiter_unavailable', route, scope, status: 503 });
      return json(
        { error: 'limiter_unavailable' },
        { status: 503, cors, headers: { 'Retry-After': RETRY_AFTER_SECONDS } },
      );
    }
  }
  return null;
}

/// Reads at most [max] bytes of the request body, or returns null the moment
/// it goes over, cancelling the rest of the upload.
///
/// Content-Length can be absent (chunked transfer) or wrong, and
/// `arrayBuffer()` would buffer whatever arrives; checking the size afterwards
/// is too late.
async function readCapped(request, max) {
  if (!request.body) return new ArrayBuffer(0);
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out.buffer;
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

/// A provider that was asked and failed.
///
/// [code] is one of three fixed words and is all the public 502 repeats:
///   http_error   the provider answered with an error status ([status])
///   bad_payload  it answered 200 with something that holds no credentials
///   unreachable  the call itself threw
/// Nothing the provider or the runtime wrote is kept. An exception from
/// `fetch` quotes the address it was given, and Metered's address carries the
/// API key; a body can quote anything. Those never reach a response, and the
/// log gets a structural description, never a message.
class ProviderFailure extends Error {
  constructor(code, status) {
    super(code);
    this.code = code;
    if (Number.isInteger(status)) this.status = status;
  }
}

/// The class name of whatever was thrown, and nothing it said.
function errorKind(e) {
  const name = e instanceof Error ? e.name : typeof e;
  return /^[A-Za-z]{1,40}$/.test(name) ? name : 'Error';
}

/// Runs a provider call. If it throws, only the kind of exception is logged and
/// the caller sees a [ProviderFailure].
async function callProvider(scope, call) {
  try {
    return await call();
  } catch (e) {
    logEvent({ event: 'provider_error', route: '/turn', scope, shape: errorKind(e) });
    throw new ProviderFailure('unreachable');
  }
}

/// Reads a provider's 200 as JSON. A body that is not JSON is a payload with no
/// credentials in it, and what the parser quoted of it stays here.
async function readProviderJson(scope, res) {
  try {
    return await res.json();
  } catch (_) {
    logEvent({
      event: 'provider_error',
      route: '/turn',
      scope,
      status: res.status,
      shape: 'not json',
    });
    throw new ProviderFailure('bad_payload');
  }
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
  const res = await callProvider('cloudflare', () =>
    fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${env.CF_TURN_KEY_ID}/credentials/generate-ice-servers`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.CF_TURN_API_TOKEN}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ ttl: TTL_SECONDS }),
      },
    ),
  );
  if (!res.ok) {
    const errorText = await res.text().catch(() => '');
    let shape = typeof errorText;
    try {
      shape = describeShape(JSON.parse(errorText));
    } catch (_) {}
    logEvent({
      event: 'provider_error',
      route: '/turn',
      scope: 'cloudflare',
      status: res.status,
      shape,
    });
    throw new ProviderFailure('http_error', res.status);
  }

  const data = await readProviderJson('cloudflare', res);
  const creds = extractCredentials(data.iceServers ?? data);
  if (!creds) {
    logEvent({
      event: 'provider_error',
      route: '/turn',
      scope: 'cloudflare',
      status: res.status,
      shape: describeShape(data.iceServers ?? data),
    });
    throw new ProviderFailure('bad_payload');
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

  const res = await callProvider('metered', () =>
    fetch(
      `https://${env.METERED_SUBDOMAIN}.metered.live/api/v1/turn/credentials?apiKey=${env.METERED_API_KEY}`,
    ),
  );
  if (!res.ok) {
    const errorText = await res.text().catch(() => '');
    let shape = typeof errorText;
    try {
      shape = describeShape(JSON.parse(errorText));
    } catch (_) {}
    logEvent({
      event: 'provider_error',
      route: '/turn',
      scope: 'metered',
      status: res.status,
      shape,
    });
    throw new ProviderFailure('http_error', res.status);
  }

  const servers = await readProviderJson('metered', res);
  const creds = extractCredentials(servers);
  if (!creds) {
    logEvent({
      event: 'provider_error',
      route: '/turn',
      scope: 'metered',
      status: res.status,
      shape: describeShape(servers),
    });
    throw new ProviderFailure('bad_payload');
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

/// The kill switch: set TURN_ENABLED to "false" (a secret or a dashboard
/// variable, not [vars] in wrangler.toml, which every deploy would overwrite)
/// and /turn stops calling providers at once. `String()` so a TOML boolean
/// `false` works the same as the text.
function relayDisabled(env) {
  return String(env.TURN_ENABLED).trim().toLowerCase() === 'false';
}

async function handleTurn(request, env) {
  if (relayDisabled(env)) {
    logEvent({ event: 'relay_disabled', route: '/turn', status: 503 });
    return json({ error: 'relay_disabled' }, { status: 503, cors: false });
  }

  const limited = await enforceLimits(request, env, '/turn', TURN_LIMITS, {
    failOpen: false,
    cors: false,
  });
  if (limited) return limited;

  const [cloudflare, metered] = await Promise.allSettled([
    fetchCloudflareTurn(env),
    fetchMeteredTurn(env),
  ]);

  if (cloudflare.status === 'rejected' && metered.status === 'rejected') {
    // Nothing was asked of any provider: the deploy has no secrets for either.
    if (cloudflare.reason?.notConfigured && metered.reason?.notConfigured) {
      logEvent({ event: 'relay_unconfigured', route: '/turn', status: 503 });
      return json({ error: 'relay_unconfigured' }, { status: 503, cors: false });
    }

    // An unconfigured provider is reported as `skipped` rather than as an
    // error, so a Cloudflare-only deployment that genuinely breaks still reads
    // as one clear failure instead of two.
    //
    // A failure is a fixed code and, for an error status, that number. The
    // rest of what went wrong is in the log (a structural description), never
    // here: this body goes to whoever called a public route.
    const describe = (scope, r) => {
      if (r.reason && r.reason.notConfigured) return { skipped: r.reason.message };
      if (r.reason instanceof ProviderFailure) {
        return r.reason.status === undefined
          ? { error: r.reason.code }
          : { error: r.reason.code, status: r.reason.status };
      }
      // Not one of ours: a bug. Say only what kind it was.
      logEvent({ event: 'provider_error', route: '/turn', scope, shape: errorKind(r.reason) });
      return { error: 'unreachable' };
    };

    logEvent({ event: 'provider_error', route: '/turn', status: 502 });
    return json(
      {
        error: 'provider_error',
        cloudflare: describe('cloudflare', cloudflare),
        metered: describe('metered', metered),
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

/// KV refused the call, most likely because the free tier's daily quota
/// (1000 writes, 100k reads) is spent. Reported, not thrown: an unhandled
/// exception would reach the client as an opaque 1101 with no Retry-After.
function storageUnavailable(scope) {
  logEvent({ event: 'storage_unavailable', route: '/r', scope, status: 503 });
  return json(
    { error: 'storage_unavailable' },
    { status: 503, headers: { 'Retry-After': RETRY_AFTER_SECONDS } },
  );
}

async function handleRoomPost(request, env, roomId) {
  if (!ROOM_ID_RE.test(roomId)) {
    return text('invalid room id', 400);
  }
  // Before the body is read and before KV is touched: a refused request must
  // cost neither buffering nor a write against the daily quota.
  const limited = await enforceLimits(request, env, '/r', ROOM_POST_LIMITS, {
    failOpen: true,
    cors: true,
  });
  if (limited) return limited;

  const contentLength = request.headers.get('content-length');
  if (contentLength !== null) {
    const len = parseInt(contentLength, 10);
    if (isNaN(len) || len <= 0 || len > MAX_BLOB_BYTES) {
      return text('invalid blob size', 400);
    }
  }
  const blob = await readCapped(request, MAX_BLOB_BYTES);
  if (blob === null || blob.byteLength === 0) {
    return text('invalid blob size', 400);
  }
  // Plain overwrite, not create-once: the room is a bulletin board a sender
  // and receiver can both post to during a handshake (offer, then answer),
  // not a single-write slot. Each POST also refreshes the TTL.
  try {
    await env.RENDEZVOUS_KV.put(`room:${roomId}`, blob, { expirationTtl: TTL_SECONDS });
  } catch (_) {
    return storageUnavailable('kv_put');
  }
  return text(null, 201);
}

async function handleRoomGet(request, env, roomId) {
  if (!ROOM_ID_RE.test(roomId)) {
    return text('invalid room id', 400);
  }
  const limited = await enforceLimits(request, env, '/r', ROOM_GET_LIMITS, {
    failOpen: true,
    cors: true,
  });
  if (limited) return limited;

  let blob;
  try {
    blob = await env.RENDEZVOUS_KV.get(`room:${roomId}`, 'arrayBuffer');
  } catch (_) {
    return storageUnavailable('kv_get');
  }
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
      return handleTurn(request, env);
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
      if (request.method === 'GET') return handleRoomGet(request, env, roomId);
    }

    return text('not found', 404);
  },
};

// Shared fakes for the Worker tests. Not a *.test.js file, so
// `node --test test/*.test.js` does not pick it up as a suite of its own.

/// The production ceilings, per 60 s. They mirror wrangler.toml, and
/// config.test.js fails if the two ever drift apart.
export const LIMITS = {
  RL_TURN_IP: 20,
  RL_TURN_GLOBAL: 300,
  RL_ROOM_POST_IP: 10,
  RL_ROOM_POST_GLOBAL: 60,
  RL_ROOM_GET_IP: 120,
};

/// An in-memory stand-in for a Workers Rate Limiting binding: `limit({key})`
/// resolves `{success}`, counting per key in fixed windows of [periodMs].
/// [now] is injectable so a test can walk a five-minute session in no time.
export function makeLimiter({ limit, periodMs = 60_000, now = Date.now } = {}) {
  const counts = new Map();
  return {
    calls: [],
    async limit({ key }) {
      this.calls.push(key);
      const slot = `${Math.floor(now() / periodMs)}|${key}`;
      const used = (counts.get(slot) ?? 0) + 1;
      counts.set(slot, used);
      return { success: used <= limit };
    },
  };
}

/// A limiter whose backing service is down.
export function throwingLimiter() {
  return {
    async limit() {
      throw new Error('limiter backend unavailable');
    },
  };
}

/// All five bindings, at production limits unless [overrides] says otherwise
/// (`{RL_TURN_GLOBAL: 3}` keeps a "global ceiling" test to a handful of calls).
export function limiterBindings({ overrides = {}, now } = {}) {
  const limits = { ...LIMITS, ...overrides };
  return Object.fromEntries(
    Object.entries(limits).map(([name, limit]) => [name, makeLimiter({ limit, now })]),
  );
}

/// Captures everything the Worker writes to the console for the duration of
/// test [t]; the original methods come back when the test ends. Each entry is
/// the raw argument list, so a test can check a log call is a single string.
export function captureLogs(t) {
  const calls = [];
  for (const method of ['log', 'info', 'warn', 'error']) {
    t.mock.method(console, method, (...args) => {
      calls.push({ method, args });
    });
  }
  return calls;
}

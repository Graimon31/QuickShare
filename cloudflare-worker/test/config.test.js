// The limits live in wrangler.toml and the code only names the bindings, so a
// typo on either side would not show up until production: a mistyped name makes
// /turn answer 503 limiter_unavailable forever. This pins the two together.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { LIMITS } from './support.js';

const toml = readFileSync(new URL('../wrangler.toml', import.meta.url), 'utf8')
  .split('\n')
  .filter((line) => !line.trim().startsWith('#'))
  .join('\n');

function ratelimitBlocks() {
  return toml
    .split(/^\[\[ratelimits\]\]/m)
    .slice(1)
    .map((chunk) => chunk.split(/^\[/m)[0])
    .map((block) => ({
      name: block.match(/^\s*name\s*=\s*"([^"]+)"/m)?.[1],
      namespaceId: block.match(/^\s*namespace_id\s*=\s*"([^"]+)"/m)?.[1],
      limit: Number(block.match(/simple\s*=\s*\{[^}]*limit\s*=\s*(\d+)/)?.[1]),
      period: Number(block.match(/simple\s*=\s*\{[^}]*period\s*=\s*(\d+)/)?.[1]),
    }));
}

test('wrangler.toml declares exactly the limiters the Worker uses, at 60 s windows', () => {
  const blocks = ratelimitBlocks();
  assert.deepEqual(blocks.map((b) => b.name).sort(), Object.keys(LIMITS).sort());
  for (const block of blocks) {
    assert.equal(block.limit, LIMITS[block.name], `${block.name} limit`);
    assert.equal(block.period, 60, `${block.name} period`);
  }
});

test('every limiter has its own namespace id, or their counters would merge', () => {
  const ids = ratelimitBlocks().map((b) => b.namespaceId);
  assert.equal(ids.length, Object.keys(LIMITS).length);
  assert.ok(ids.every(Boolean));
  assert.equal(new Set(ids).size, ids.length);
});

test('Workers Logs is on, so the 429/503 log lines can be seen', () => {
  assert.match(toml, /^\[observability\]\s*\n\s*enabled\s*=\s*true/m);
});

test('the kill switch is not pinned in [vars], where every deploy would reset it', () => {
  assert.doesNotMatch(toml, /^\s*TURN_ENABLED\s*=/m);
});

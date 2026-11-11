// Parity test for the Tier 2 Worker against the original Vercel handlers
// (aldol2678/inhagame apps/world/api/hub-entry.js, hub-event.js,
// asset-canary-flag.js) and their contract tests
// (apps/world/tests/hub-api-contract.test.mjs, asset-canary-flag-api.test.mjs,
// supabase/tests/integration/hub-api.integration.test.mjs).
//
//   npm install && node test-parity.mjs
//
// The unmodified worker.js runs with the real @neondatabase/serverless driver;
// only the driver's HTTP transport is replaced (neonConfig.fetchFunction), the
// same way the original contract test replaces fetch. No network, no database.
//
// Optional end-to-end pass against a real Postgres that has schema.sql applied
// (a disposable local database or an ISOLATED Neon branch — never the live one):
//
//   TEST_PG_URL=postgresql://... node test-parity.mjs
//
// A non-loopback TEST_PG_URL is refused unless TEST_PG_ALLOW_REMOTE=1 is also
// set. The URL is read from the environment only and is never printed.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { neonConfig } from '@neondatabase/serverless';
import worker from './worker.js';

// ---- mini runner: one line per failure, "passed/total" at the end ----
let passed = 0;
let total = 0;
const failures = [];
async function t(name, fn) {
  total += 1;
  try {
    await fn();
    passed += 1;
  } catch (error) {
    failures.push(`not ok - ${name}\n    ${String(error?.message ?? error).split('\n').join('\n    ')}`);
  }
}

// ---- harness ----
// Placeholder only: the host is unresolvable and the transport is stubbed.
const ENV = { DATABASE_URL: 'postgresql://parity:parity@db.invalid/parity' };
const ID = {
  event: '0b1c2d3e-4f50-4a61-8b72-938495a6b7c8',
  entry: '1a2b3c4d-5e6f-4a7b-9c8d-0e1f2a3b4c5d',
  session: '2b3c4d5e-6f70-4b8c-ad9e-1f2a3b4c5d6e',
  visitor: '3c4d5e6f-7081-4c9d-be0f-2a3b4c5d6e7f',
};
const ORIGINS = {
  'https://inhagame.app': 'campus',
  'https://duck.inhagame.app': 'classic',
  'https://induckup.inhagame.app': 'induckup',
  'https://survival.inhagame.app': 'survival',
  'https://grow.inhagame.app': 'induck-grow',
};
const BOOL = 16; // pg type oid

/** A successful Neon HTTP reply with one boolean column. */
const neonRows = (column, values) => () => new Response(JSON.stringify({
  fields: [{ name: column, dataTypeID: BOOL }],
  rows: values.map((v) => [v === true ? 't' : v === false ? 'f' : v]),
  command: 'SELECT', rowCount: values.length, rowAsArray: true,
}), { status: 200, headers: { 'content-type': 'application/json' } });
/** Postgres answered with an error (what PostgREST turned into a non-2xx). */
const neonDbError = (code = '22P02') => () => new Response(
  JSON.stringify({ message: 'database error', code }), { status: 400 });
const neonHttpError = (status) => () => new Response('<html>upstream</html>', { status });
const unreachable = () => { throw new TypeError('fetch failed'); };
const timedOut = () => { throw new DOMException('The operation timed out.', 'TimeoutError'); };
const unreadable = () => new Response('not json', { status: 200 });

let calls;
function stubDb(reply = neonRows('accepted', [true])) {
  calls = [];
  neonConfig.fetchFunction = async (url, init) => {
    const sent = JSON.parse(init.body);
    calls.push({ url: String(url), query: sent.query, params: sent.params, init });
    return reply(sent);
  };
}

async function call(path, { method = 'POST', headers = {}, body, env = ENV } = {}) {
  const init = { method, headers };
  if (body !== undefined && method !== 'GET' && method !== 'HEAD') init.body = body;
  const res = await worker.fetch(new Request(`https://inhagame.app${path}`, init), env);
  return res;
}

const entryBody = (overrides = {}) => ({
  event_id: ID.event, entry_id: ID.entry, event_type: 'game_landing', target: 'classic', ...overrides,
});
async function entry(body = entryBody(), origin = 'https://duck.inhagame.app', extra = {}) {
  const res = await call('/api/hub-entry', {
    headers: { origin, 'content-type': 'application/json', ...extra },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  assert.equal(res.headers.get('cache-control'), 'no-store');
  return res;
}
const eventBody = (overrides = {}) => ({
  event_id: ID.event, session_id: ID.session, visitor_id: ID.visitor,
  event_type: 'hub_game_click', surface: 'home', target: 'classic',
  acquisition_source: 'direct', campaign: null, ...overrides,
});
const hubHeaders = { origin: 'https://inhagame.app', host: 'inhagame.app' };
async function event(body = eventBody(), headers = hubHeaders) {
  const res = await call('/api/hub-event', {
    headers: { 'content-type': 'text/plain', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  assert.equal(res.headers.get('cache-control'), 'no-store');
  return res;
}
const ENTRY_SQL = 'select public.log_game_entry_v1($1::uuid, $2::uuid, $3::text, $4::text) as accepted';
const EVENT_SQL = 'select public.log_hub_event_v2($1::uuid, $2::uuid, $3::uuid, $4::text, $5::text, $6::text, $7::text, $8::text) as accepted';
const FLAG_SQL = 'select enabled from public.runtime_flags where flag = $1 limit 1';

// =====================================================================
// hub-entry
// =====================================================================
await t('hub-entry: a valid stage is stored with the target taken from the Origin', async () => {
  stubDb();
  const res = await entry();
  assert.equal(res.status, 204);
  assert.equal(await res.text(), '');
  assert.equal(res.headers.get('access-control-allow-origin'), 'https://duck.inhagame.app');
  assert.equal(res.headers.get('vary'), 'Origin');
  assert.equal(res.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
  assert.equal(res.headers.get('access-control-allow-headers'), 'Content-Type');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].query, ENTRY_SQL);
  assert.deepEqual(calls[0].params, [ID.event, ID.entry, 'game_landing', 'classic']);
});

for (const [origin, target] of Object.entries(ORIGINS)) {
  await t(`hub-entry: origin ${origin} attributes to ${target}`, async () => {
    stubDb();
    const res = await entry(entryBody({ target }), origin);
    assert.equal(res.status, 204);
    assert.equal(res.headers.get('access-control-allow-origin'), origin);
    assert.equal(calls[0].params[3], target);
  });
}

for (const eventType of ['game_landing', 'game_play_start', 'game_load_error',
  'game_first_result', 'game_first_clear', 'game_retry', 'classic_ranked_start']) {
  await t(`hub-entry: stage ${eventType} is accepted`, async () => {
    stubDb();
    assert.equal((await entry(entryBody({ event_type: eventType }))).status, 204);
    assert.equal(calls[0].params[2], eventType);
  });
}

await t('hub-entry: CORS preflight from a game origin', async () => {
  stubDb();
  const res = await call('/api/hub-entry', { method: 'OPTIONS', headers: { origin: 'https://survival.inhagame.app' } });
  assert.equal(res.status, 204);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('access-control-allow-origin'), 'https://survival.inhagame.app');
  assert.equal(res.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
  assert.equal(res.headers.get('access-control-allow-headers'), 'Content-Type');
  assert.equal(calls.length, 0);
});

await t('hub-entry: a text/plain body is read like JSON text', async () => {
  stubDb();
  const res = await call('/api/hub-entry', {
    headers: { origin: 'https://duck.inhagame.app', 'content-type': 'text/plain' },
    body: JSON.stringify(entryBody()),
  });
  assert.equal(res.status, 204);
});

for (const origin of [undefined, 'https://evil.example', 'http://duck.inhagame.app',
  'https://duck.inhagame.app.evil.example', 'https://duck.inhagame.app:8443', 'null',
  'https://DUCK.inhagame.app', 'https://duck.inhagame.app/', 'constructor', '__proto__', 'toString']) {
  await t(`hub-entry: origin ${String(origin)} is refused before anything else`, async () => {
    stubDb();
    const headers = origin === undefined ? {} : { origin };
    const res = await call('/api/hub-entry', { headers, body: JSON.stringify(entryBody()) });
    assert.equal(res.status, 403);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(res.headers.get('access-control-allow-origin'), null);
    assert.equal(res.headers.get('vary'), null);
    assert.equal(calls.length, 0);
  });
}

await t('hub-entry guard order: Origin (403) is checked before the method (405)', async () => {
  stubDb();
  for (const method of ['GET', 'OPTIONS', 'PUT', 'DELETE']) {
    const res = await call('/api/hub-entry', { method, headers: { origin: 'https://evil.example' } });
    assert.equal(res.status, 403, method);
  }
  assert.equal(calls.length, 0);
});

for (const method of ['GET', 'HEAD', 'PUT', 'PATCH', 'DELETE']) {
  await t(`hub-entry: ${method} is 405 (with the CORS headers already set)`, async () => {
    stubDb();
    const res = await call('/api/hub-entry', { method, headers: { origin: 'https://duck.inhagame.app' } });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(res.headers.get('access-control-allow-origin'), 'https://duck.inhagame.app');
    assert.equal(res.headers.get('allow'), null, 'the original sends no Allow header here');
    assert.equal(calls.length, 0);
  });
}

await t('hub-entry guard order: method (405) is checked before the body (413 / 400)', async () => {
  stubDb();
  const res = await call('/api/hub-entry', {
    method: 'PUT', headers: { origin: 'https://duck.inhagame.app' }, body: 'x'.repeat(2000),
  });
  assert.equal(res.status, 405);
});

await t('hub-entry guard order: size (413) is checked before JSON parsing (400)', async () => {
  stubDb();
  assert.equal((await entry('{'.repeat(513))).status, 413);
  assert.equal((await entry('{'.repeat(512))).status, 400);
  assert.equal(calls.length, 0);
});

await t('hub-entry: the body limit is 512 characters inclusive', async () => {
  stubDb();
  const base = JSON.stringify(entryBody({ pad: '' }));
  const at = JSON.stringify(entryBody({ pad: 'x'.repeat(512 - base.length) }));
  const over = JSON.stringify(entryBody({ pad: 'x'.repeat(513 - base.length) }));
  assert.equal(at.length, 512);
  assert.equal(over.length, 513);
  assert.equal((await entry(at)).status, 204);
  assert.equal((await entry(over)).status, 413);
  assert.equal(calls.length, 1);
});

for (const [name, body, status] of [
  ['malformed event_id', entryBody({ event_id: 'not-a-uuid' }), 400],
  ['nil uuid', entryBody({ event_id: '00000000-0000-0000-0000-000000000000' }), 400],
  ['malformed entry_id', entryBody({ entry_id: `${ID.entry}0` }), 400],
  ['missing event_id', entryBody({ event_id: undefined }), 400],
  ['missing entry_id', entryBody({ entry_id: undefined }), 400],
  ['hub event type', entryBody({ event_type: 'hub_visit' }), 400],
  ['unsupported event type', entryBody({ event_type: 'game_purchase' }), 400],
  ['missing event type', entryBody({ event_type: undefined }), 400],
  ['unknown target', entryBody({ target: 'tetris' }), 400],
  ['cross-game target', entryBody({ target: 'induckup' }), 400],
  ['missing target', entryBody({ target: undefined }), 400],
  ['non-JSON body', '{"event_id":', 400],
  ['empty body', '', 400],
  ['JSON array', '[]', 400],
  ['JSON null', 'null', 400],
  ['JSON number', '7', 400],
  ['JSON string', '"game_landing"', 400],
  ['oversized body', JSON.stringify({ ...entryBody(), pad: 'x'.repeat(512) }), 413],
]) {
  await t(`hub-entry: ${name} -> ${status}, never reaches the database`, async () => {
    stubDb();
    const res = await entry(body);
    assert.equal(res.status, status);
    assert.equal(res.headers.get('access-control-allow-origin'), 'https://duck.inhagame.app');
    assert.equal(calls.length, 0);
  });
}

// false covers every server-side refusal: missing or expired click, play before
// landing, cross-game reuse. A resent event_id is NOT a refusal: the function
// returns true for it (see test-schema.sql), so it is 204, as in the original.
for (const [name, reply, status] of [
  ['accepted', neonRows('accepted', [true]), 204],
  ['refused', neonRows('accepted', [false]), 409],
  ['non-boolean verdict', neonRows('accepted', [null]), 409],
  ['no row', neonRows('accepted', []), 409],
  ['database error', neonDbError('22P02'), 502],
  ['upstream HTTP 500', neonHttpError(500), 502],
  ['upstream HTTP 503', neonHttpError(503), 502],
  ['upstream unreachable', unreachable, 503],
  ['upstream timeout', timedOut, 503],
  ['unreadable upstream reply', unreadable, 503],
]) {
  await t(`hub-entry verdict: ${name} -> ${status}`, async () => {
    stubDb(reply);
    const res = await entry();
    assert.equal(res.status, status);
    assert.equal(await res.text(), '');
    assert.equal(res.headers.get('access-control-allow-origin'), 'https://duck.inhagame.app');
    assert.equal(calls.length, 1);
  });
}

await t('hub-entry: DATABASE_URL unset -> 503 after every guard, no request is made', async () => {
  stubDb();
  for (const env of [{}, { DATABASE_URL: '' }]) {
    const res = await call('/api/hub-entry', {
      headers: { origin: 'https://duck.inhagame.app' }, body: JSON.stringify(entryBody()), env,
    });
    assert.equal(res.status, 503);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    // guards still answer first when unconfigured
    const bad = await call('/api/hub-entry', {
      headers: { origin: 'https://duck.inhagame.app' }, body: '{', env,
    });
    assert.equal(bad.status, 400);
    const cross = await call('/api/hub-entry', { headers: { origin: 'https://evil.example' }, body: '{}', env });
    assert.equal(cross.status, 403);
  }
  assert.equal(calls.length, 0);
});

await t('hub-entry: the upstream call is bounded by an abort signal (4000 ms in the original)', async () => {
  stubDb();
  await entry();
  assert.ok(calls[0].init.signal instanceof AbortSignal);
  assert.equal(calls[0].init.signal.aborted, false);
});

await t('hub-entry: only the four entry fields reach the database, no client credentials', async () => {
  stubDb();
  const res = await entry({
    ...entryBody(), email: 'duck@inha.edu', nickname: 'duck', access_token: 'jwt', user_id: ID.visitor,
    visitor_id: ID.visitor, session_id: ID.session, user_agent: 'x',
  }, 'https://duck.inhagame.app', { authorization: 'Bearer user-jwt', cookie: 'sb-access-token=secret' });
  assert.equal(res.status, 204);
  assert.deepEqual(calls[0].params, [ID.event, ID.entry, 'game_landing', 'classic']);
  const sent = JSON.stringify([calls[0].query, calls[0].params]) +
    JSON.stringify([...new Headers(calls[0].init.headers).entries()]);
  for (const leak of ['duck@inha.edu', 'user-jwt', 'sb-access-token', ID.visitor, ID.session]) {
    assert.ok(!sent.includes(leak), `${leak} must not be forwarded`);
  }
});

// =====================================================================
// hub-event
// =====================================================================
await t('hub-event: a valid hub event is stored with acquisition fields', async () => {
  stubDb();
  const res = await event();
  assert.equal(res.status, 204);
  assert.equal(await res.text(), '');
  assert.equal(res.headers.get('access-control-allow-origin'), null, 'same-origin endpoint: no CORS headers');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].query, EVENT_SQL);
  assert.deepEqual(calls[0].params,
    [ID.event, ID.session, ID.visitor, 'hub_game_click', 'home', 'classic', 'direct', null]);
});

for (const eventType of ['hub_visit', 'hub_panel_view', 'hub_game_click', 'campus_entry_click',
  'campus_boot_ready', 'campus_boot_error', 'campus_zone_enter', 'hub_card_impression',
  'profile_view', 'profile_edit_open', 'profile_edit_save', 'profile_game_click',
  'first_session_start', 'first_goal_seen', 'first_move', 'first_zone_arrival', 'first_npc_interaction',
  'quest_started', 'first_player_encounter', 'first_activity_start', 'first_activity_complete',
  'first_reward', 'reward_seen', 'growth_seen', 'core_loop_complete', 'next_goal_seen',
  'core15_complete', 'world_return', 'next_discovery_click',
  'asset_canary_selected', 'asset_canary_active', 'asset_canary_rollback', 'asset_canary_failure']) {
  await t(`hub-event: event type ${eventType} is accepted`, async () => {
    stubDb();
    assert.equal((await event(eventBody({ event_type: eventType }))).status, 204);
    assert.equal(calls[0].params[3], eventType);
  });
}

await t('hub-event: target and campaign are optional and stored as null', async () => {
  stubDb();
  assert.equal((await event(eventBody({ event_type: 'hub_visit', target: undefined, campaign: undefined }))).status, 204);
  assert.equal(calls[0].params[5], null);
  assert.equal(calls[0].params[7], null);
});

await t('hub-event: a missing or null acquisition_source is stored as unknown', async () => {
  for (const value of [undefined, null]) {
    stubDb();
    assert.equal((await event(eventBody({ acquisition_source: value }))).status, 204);
    assert.equal(calls[0].params[6], 'unknown');
  }
});

await t('hub-event: every acquisition source and a campaign are forwarded', async () => {
  for (const source of ['direct', 'everytime', 'internal', 'external', 'unknown']) {
    stubDb();
    const res = await event(eventBody({ acquisition_source: source, campaign: 'induck_grow_v1_launch_20260925' }));
    assert.equal(res.status, 204, source);
    assert.equal(calls[0].params[6], source);
    assert.equal(calls[0].params[7], 'induck_grow_v1_launch_20260925');
  }
});

for (const [eventType, target] of [
  ['first_activity_start', 'inkyung_living'], ['first_goal_seen', 'first_campus'],
  ['next_goal_seen', 'main2_back_gate_guide'], ['asset_canary_active', 'induck_v3'],
]) {
  await t(`hub-event: ${eventType} forwards surface campus and target ${target}`, async () => {
    stubDb();
    const res = await event(eventBody({ event_type: eventType, surface: 'campus', target }));
    assert.equal(res.status, 204);
    assert.equal(calls[0].params[4], 'campus');
    assert.equal(calls[0].params[5], target);
  });
}

await t('hub-event: a request without Origin (beacon) passes', async () => {
  stubDb();
  assert.equal((await event(eventBody(), { host: 'inhagame.app' })).status, 204);
  assert.equal((await event(eventBody(), {})).status, 204, 'no Origin and no Host');
});

for (const headers of [
  { origin: 'https://evil.example', host: 'inhagame.app' },
  { origin: 'https://duck.inhagame.app', host: 'inhagame.app' },
  { origin: 'https://inhagame.app:8443', host: 'inhagame.app' },
  { origin: 'not a url', host: 'inhagame.app' },
  { origin: 'null', host: 'inhagame.app' },
  { origin: 'https://inhagame.app' },
]) {
  await t(`hub-event: cross-site ${JSON.stringify(headers)} is 403`, async () => {
    stubDb();
    const res = await event(eventBody(), headers);
    assert.equal(res.status, 403);
    assert.equal(calls.length, 0);
  });
}

await t('hub-event: same-host Origin passes whatever the scheme (host comparison only)', async () => {
  stubDb();
  assert.equal((await event(eventBody(), { origin: 'http://inhagame.app', host: 'inhagame.app' })).status, 204);
  assert.equal((await event(eventBody(), { origin: 'https://tier02.example:8787', host: 'tier02.example:8787' })).status, 204);
});

for (const method of ['GET', 'HEAD', 'OPTIONS', 'PUT', 'DELETE']) {
  await t(`hub-event: ${method} is 405, checked before the Origin`, async () => {
    stubDb();
    const res = await call('/api/hub-event', { method, headers: { origin: 'https://evil.example', host: 'inhagame.app' } });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(res.headers.get('allow'), null, 'the original sends no Allow header here');
    assert.equal(calls.length, 0);
  });
}

await t('hub-event guard order: Origin (403) is checked before the body (413 / 400)', async () => {
  stubDb();
  const res = await event('x'.repeat(5000), { origin: 'https://evil.example', host: 'inhagame.app' });
  assert.equal(res.status, 403);
});

await t('hub-event guard order: size (413) is checked before JSON parsing (400)', async () => {
  stubDb();
  assert.equal((await event('{'.repeat(1025))).status, 413);
  assert.equal((await event('{'.repeat(1024))).status, 400);
  assert.equal(calls.length, 0);
});

await t('hub-event: the body limit is 1024 characters inclusive', async () => {
  stubDb();
  const base = JSON.stringify(eventBody({ pad: '' }));
  const at = JSON.stringify(eventBody({ pad: 'x'.repeat(1024 - base.length) }));
  const over = JSON.stringify(eventBody({ pad: 'x'.repeat(1025 - base.length) }));
  assert.equal(at.length, 1024);
  assert.equal((await event(at)).status, 204);
  assert.equal((await event(over)).status, 413);
  assert.equal(calls.length, 1);
});

for (const [name, body, status] of [
  ['malformed event_id', eventBody({ event_id: 'x' }), 400],
  ['malformed session_id', eventBody({ session_id: 'x' }), 400],
  ['malformed visitor_id', eventBody({ visitor_id: 'x' }), 400],
  ['missing visitor_id', eventBody({ visitor_id: undefined }), 400],
  ['nil session uuid', eventBody({ session_id: '00000000-0000-0000-0000-000000000000' }), 400],
  ['game stage on hub endpoint', eventBody({ event_type: 'game_landing' }), 400],
  ['unsupported event type', eventBody({ event_type: 'purchase' }), 400],
  ['surface missing', eventBody({ surface: undefined }), 400],
  ['surface not a string', eventBody({ surface: 3 }), 400],
  ['target not a string', eventBody({ target: 7 }), 400],
  ['invalid acquisition source', eventBody({ acquisition_source: 'javascript:bad' }), 400],
  ['acquisition source not a string', eventBody({ acquisition_source: 5 }), 400],
  ['invalid campaign', eventBody({ campaign: 'Bad Campaign!' }), 400],
  ['campaign not a string', eventBody({ campaign: 20260925 }), 400],
  ['campaign too long', eventBody({ campaign: 'a'.repeat(65) }), 400],
  ['non-JSON body', 'hub_visit', 400],
  ['empty body', '', 400],
  ['JSON null', 'null', 400],
  ['JSON array', '[]', 400],
  ['JSON number', '7', 400],
  ['oversized body', JSON.stringify({ ...eventBody(), pad: 'x'.repeat(1024) }), 413],
]) {
  await t(`hub-event: ${name} -> ${status}, never reaches the database`, async () => {
    stubDb();
    assert.equal((await event(body)).status, status);
    assert.equal(calls.length, 0);
  });
}

// false covers vocabulary / context-check refusals and the 120-per-hour session
// limit; a resent event_id returns true (204), as in the original.
for (const [name, reply, status] of [
  ['accepted', neonRows('accepted', [true]), 204],
  ['refused', neonRows('accepted', [false]), 400],
  ['non-boolean verdict', neonRows('accepted', [null]), 400],
  ['no row', neonRows('accepted', []), 400],
  ['database error', neonDbError('23502'), 502],
  ['upstream HTTP 503', neonHttpError(503), 502],
  ['upstream unreachable', unreachable, 503],
  ['upstream timeout', timedOut, 503],
  ['unreadable upstream reply', unreadable, 503],
]) {
  await t(`hub-event verdict: ${name} -> ${status}`, async () => {
    stubDb(reply);
    const res = await event();
    assert.equal(res.status, status);
    assert.equal(await res.text(), '');
    assert.equal(calls.length, 1);
  });
}

await t('hub-event: DATABASE_URL unset -> 503 after every guard, no request is made', async () => {
  stubDb();
  for (const env of [{}, { DATABASE_URL: '' }]) {
    const post = (body, headers = hubHeaders, method = 'POST') =>
      call('/api/hub-event', { method, headers, body, env });
    assert.equal((await post(JSON.stringify(eventBody()))).status, 503);
    assert.equal((await post(undefined, hubHeaders, 'GET')).status, 405);
    assert.equal((await post('{}', { origin: 'https://evil.example', host: 'inhagame.app' })).status, 403);
    assert.equal((await post('x'.repeat(1025))).status, 413);
    assert.equal((await post('{')).status, 400);
  }
  assert.equal(calls.length, 0);
});

await t('hub-event: account fields are neither needed nor forwarded', async () => {
  stubDb();
  const res = await event({ ...eventBody(), email: 'duck@inha.edu', nickname: 'duck', user_id: ID.entry, access_token: 'jwt' },
    { ...hubHeaders, authorization: 'Bearer user-jwt', cookie: 'sb-access-token=secret' });
  assert.equal(res.status, 204);
  assert.equal(calls[0].params.length, 8);
  const sent = JSON.stringify([calls[0].query, calls[0].params]) +
    JSON.stringify([...new Headers(calls[0].init.headers).entries()]);
  for (const leak of ['duck@inha.edu', 'user-jwt', 'sb-access-token', ID.entry, 'jwt"']) {
    assert.ok(!sent.includes(leak), `${leak} must not be forwarded`);
  }
});

// =====================================================================
// asset-canary-flag
// =====================================================================
const flag = (options = {}) => call('/api/asset-canary-flag', { method: 'GET', ...options });

await t('asset-canary-flag: enabled row maps to 200 {"enabled":true}', async () => {
  stubDb(neonRows('enabled', [true]));
  const res = await flag();
  assert.equal(res.status, 200);
  assert.equal(await res.text(), '{"enabled":true}');
  assert.equal(res.headers.get('content-type'), 'application/json; charset=utf-8');
  assert.equal(res.headers.get('cache-control'), 'public, max-age=5');
  assert.equal(res.headers.get('vercel-cdn-cache-control'), 'public, s-maxage=5, stale-while-revalidate=5');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].query, FLAG_SQL);
  assert.deepEqual(calls[0].params, ['asset_glb_canary_v1']);
  assert.ok(calls[0].init.signal instanceof AbortSignal, 'bounded like the original 1200 ms fetch');
});

await t('asset-canary-flag: disabled row maps to 200 {"enabled":false}', async () => {
  stubDb(neonRows('enabled', [false]));
  const res = await flag();
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { enabled: false });
  assert.match(res.headers.get('vercel-cdn-cache-control'), /s-maxage=5/);
});

for (const [name, reply] of [
  ['database error (e.g. table missing)', neonDbError('42P01')],
  ['upstream HTTP 500', neonHttpError(500)],
  ['no row', neonRows('enabled', [])],
  ['two rows', neonRows('enabled', [true, true])],
  ['null enabled', neonRows('enabled', [null])],
  ['non-boolean enabled', () => new Response(JSON.stringify({
    fields: [{ name: 'enabled', dataTypeID: 25 }], rows: [['yes']],
    command: 'SELECT', rowCount: 1, rowAsArray: true }), { status: 200 })],
  ['upstream unreachable', unreachable],
  ['upstream timeout', timedOut],
  ['unreadable upstream reply', unreadable],
]) {
  await t(`asset-canary-flag: ${name} fails closed as 503`, async () => {
    stubDb(reply);
    const res = await flag();
    assert.equal(res.status, 503);
    assert.equal(await res.text(), '');
    assert.equal(res.headers.get('cache-control'), 'no-store, max-age=0');
    assert.equal(res.headers.get('vercel-cdn-cache-control'), 'public, s-maxage=5, stale-while-revalidate=5');
  });
}

await t('asset-canary-flag: DATABASE_URL unset -> 503, no request is made', async () => {
  stubDb(neonRows('enabled', [true]));
  for (const env of [{}, { DATABASE_URL: '' }]) {
    assert.equal((await flag({ env })).status, 503);
    assert.equal((await flag({ env, method: 'POST' })).status, 405);
  }
  assert.equal(calls.length, 0);
});

for (const method of ['POST', 'PUT', 'DELETE', 'OPTIONS', 'HEAD']) {
  await t(`asset-canary-flag: ${method} is 405 with Allow: GET and no-store`, async () => {
    stubDb(() => { throw new Error('must not call upstream'); });
    const res = await flag({ method });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('allow'), 'GET');
    assert.match(res.headers.get('cache-control'), /no-store/);
    assert.equal(calls.length, 0);
  });
}

// =====================================================================
// asset-canary-flag 5-second cache (Cache API) and the daily purge cron
// =====================================================================
// Node has no `caches`; install a tiny mock so the wiring is testable, and
// remove it again afterwards so later sections see the plain-Node path.
const cacheStore = new Map();
globalThis.caches = {
  default: {
    async match(req) {
      const hit = cacheStore.get(req.url);
      if (hit && Date.now() - hit.at < 5000) return hit.res.clone();
      cacheStore.delete(req.url);
      return undefined;
    },
    async put(req, res) { cacheStore.set(req.url, { res: res.clone(), at: Date.now() }); },
  },
};

await t('asset-canary-flag: a 200 is cached for 5s and the second read hits no DB', async () => {
  cacheStore.clear();
  stubDb(neonRows('enabled', [true]));
  const first = await flag();
  assert.equal(first.status, 200);
  assert.deepEqual(await first.json(), { enabled: true });
  assert.equal(calls.length, 1);
  stubDb(neonRows('enabled', [false])); // the stored value changes underneath
  const second = await flag();
  assert.equal(second.status, 200);
  assert.deepEqual(await second.json(), { enabled: true }); // still the cached value
  assert.equal(calls.length, 0);
});

await t('asset-canary-flag: a 503 is not cached', async () => {
  cacheStore.clear();
  stubDb(neonDbError('42P01'));
  assert.equal((await flag()).status, 503);
  stubDb(neonRows('enabled', [true]));
  const res = await flag();
  assert.equal(res.status, 200);
  assert.equal(calls.length, 1);
});

await t('asset-canary-flag: after 5s the cache expires and the DB is read again', async () => {
  cacheStore.clear();
  stubDb(neonRows('enabled', [true]));
  assert.equal((await flag()).status, 200);
  cacheStore.get('https://inhagame.app/api/asset-canary-flag').at = Date.now() - 6000;
  stubDb(neonRows('enabled', [false]));
  const res = await flag();
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { enabled: false });
  assert.equal(calls.length, 1);
});

delete globalThis.caches;

// ---- scheduled purge ----
const intRows = (column, values) => () => new Response(JSON.stringify({
  fields: [{ name: column, dataTypeID: 23 }],
  rows: values.map((v) => [String(v)]),
  command: 'SELECT', rowCount: values.length, rowAsArray: true,
}), { status: 200, headers: { 'content-type': 'application/json' } });

await t('scheduled: purge calls purge_telemetry_90d and logs the count', async () => {
  stubDb(intRows('deleted', [7]));
  await worker.scheduled({ cron: '0 3 * * *', scheduledTime: Date.now() }, ENV, {});
  assert.equal(calls.length, 1);
  assert.equal(calls[0].query, 'select public.purge_telemetry_90d() as deleted');
  assert.deepEqual(calls[0].params, []);
});

await t('scheduled: a database failure propagates so the cron retries', async () => {
  stubDb(unreachable);
  await assert.rejects(worker.scheduled({ cron: '0 3 * * *', scheduledTime: Date.now() }, ENV, {}));
});

// =====================================================================
// router (same convention as Tier 01)
// =====================================================================
for (const path of ['/', '/api', '/api/nope', '/api/hub-entry/', '/api/hub-event/x', '/api/world-time', '/API/hub-event']) {
  await t(`router: ${path} is 404 and touches nothing`, async () => {
    stubDb();
    const res = await call(path, { method: 'GET' });
    assert.equal(res.status, 404);
    assert.equal(await res.text(), 'Not found');
    assert.equal(calls.length, 0);
  });
}

await t('router: the query string does not affect routing', async () => {
  stubDb(neonRows('enabled', [false]));
  assert.equal((await flag({})).status, 200);
  assert.equal((await call('/api/asset-canary-flag?x=1', { method: 'GET' })).status, 200);
});

// =====================================================================
// Optional: end to end against a real Postgres with schema.sql applied.
// The driver's HTTP transport is bridged to node-postgres, so the Worker's
// exact SQL text and parameters run against the real functions and tables.
// =====================================================================
const PG_URL = process.env.TEST_PG_URL;
let integration = 'skipped (set TEST_PG_URL to a disposable database to run it)';
if (PG_URL) {
  const loopback = /^postgres(ql)?:\/\/([^@/]*@)?(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(\/|$)/.test(PG_URL);
  if (!loopback && process.env.TEST_PG_ALLOW_REMOTE !== '1') {
    console.error('TEST_PG_URL is not a loopback database. Refusing to run: set TEST_PG_ALLOW_REMOTE=1 only ' +
      'for an ISOLATED Neon branch, never for the live database.');
    process.exit(2);
  }
  const { default: pg } = await import('pg');
  const raw = { getTypeParser: () => (value) => value };
  const admin = new pg.Client({ connectionString: PG_URL });
  const app = new pg.Client({ connectionString: PG_URL });
  await admin.connect();
  await app.connect();
  // The Worker's queries run as the least-privilege group role from schema.sql.
  // A non-superuser owner (e.g. neondb_owner) must be a member to SET ROLE; the
  // membership is granted only if missing and revoked again at the end.
  const { rows: [{ member }] } = await admin.query(
    `select pg_has_role(current_user, 'inha_world_tier2_app', 'SET') as member`);
  if (!member) await admin.query('grant inha_world_tier2_app to current_user');
  await app.query('set role inha_world_tier2_app');
  integration = 'ran as role inha_world_tier2_app';

  neonConfig.fetchFunction = async (url, init) => {
    const { query, params } = JSON.parse(init.body);
    try {
      const result = await app.query({ text: query, values: params, rowMode: 'array', types: raw });
      return new Response(JSON.stringify({
        fields: result.fields.map((f) => ({ name: f.name, dataTypeID: f.dataTypeID })),
        rows: result.rows, command: result.command, rowCount: result.rowCount, rowAsArray: true,
      }), { status: 200 });
    } catch (error) {
      return new Response(JSON.stringify({ message: error.message, code: error.code }), { status: 400 });
    }
  };

  const sessions = [];
  const GAME_ORIGIN = Object.fromEntries(Object.entries(ORIGINS).map(([origin, game]) => [game, origin]));
  const post = async (path, headers, body) =>
    (await call(path, { headers, body: JSON.stringify(body) })).status;
  /** A hub card click through /api/hub-event; its event id is the entry id games carry. */
  async function click(target, extra = {}) {
    const ids = { session: randomUUID(), visitor: randomUUID() };
    sessions.push(ids.session);
    const eventId = randomUUID();
    const status = await post('/api/hub-event', hubHeaders, {
      event_id: eventId, session_id: ids.session, visitor_id: ids.visitor,
      event_type: target === 'campus' ? 'campus_entry_click' : 'hub_game_click', surface: 'home', target,
      acquisition_source: 'direct', campaign: null, ...extra,
    });
    assert.equal(status, 204, `hub click for ${target}`);
    return { entryId: eventId, ...ids };
  }
  /** A game stage through /api/hub-entry from the game's own origin. */
  const stage = (game, entryId, eventType, eventId = randomUUID(), bodyTarget = game) =>
    post('/api/hub-entry', { origin: GAME_ORIGIN[game] },
      { event_id: eventId, entry_id: entryId, event_type: eventType, target: bodyTarget });
  const stages = async (where, values) =>
    (await admin.query(`select * from public.game_entries where ${where} order by created_at, event_type`, values)).rows;

  await t('db: click -> landing -> play is stored once per stage and attributed to the click', async () => {
    const { entryId, session, visitor } = await click('classic');
    const landingId = randomUUID();
    assert.equal(await stage('classic', entryId, 'game_landing', landingId), 204);
    assert.equal(await stage('classic', entryId, 'game_play_start'), 204);
    assert.equal(await stage('classic', entryId, 'game_first_result'), 204);
    assert.equal(await stage('classic', entryId, 'game_first_clear'), 204);
    const stored = await stages('entry_id = $1', [entryId]);
    assert.deepEqual(stored.map((r) => r.event_type).sort(),
      ['game_first_clear', 'game_first_result', 'game_landing', 'game_play_start']);
    for (const row of stored) {
      assert.equal(row.target, 'classic');
      assert.equal(row.session_id, session, 'session comes from the click, not the game');
      assert.equal(row.visitor_id, visitor, 'visitor comes from the click, not the game');
    }
    assert.equal(stored.find((r) => r.event_type === 'game_landing').event_id, landingId);
  });

  await t('db: duplicate stages and duplicate event ids are idempotent (204, not 409)', async () => {
    const { entryId } = await click('survival');
    const landingId = randomUUID();
    assert.equal(await stage('survival', entryId, 'game_landing', landingId), 204);
    assert.equal(await stage('survival', entryId, 'game_landing'), 204, 'second landing, new event id');
    assert.equal(await stage('survival', entryId, 'game_landing', landingId), 204, 'same event id resent');
    assert.equal((await stages(`entry_id = $1 and event_type = 'game_landing'`, [entryId])).length, 1);
    const other = await click('survival');
    assert.equal(await stage('survival', other.entryId, 'game_landing', landingId), 204, 'event id reused for another entry');
    assert.equal((await stages('event_id = $1', [landingId]))[0].entry_id, entryId, 'the first row is never overwritten');
    assert.equal((await stages('entry_id = $1', [other.entryId])).length, 0);
  });

  await t('db: a resent hub event is idempotent (204) and stored once', async () => {
    const { entryId, session, visitor } = await click('classic');
    const again = await post('/api/hub-event', hubHeaders, {
      event_id: entryId, session_id: session, visitor_id: visitor,
      event_type: 'hub_game_click', surface: 'home', target: 'classic',
    });
    assert.equal(again, 204);
    const { rows } = await admin.query('select count(*)::int as n from public.hub_events where event_id = $1', [entryId]);
    assert.equal(rows[0].n, 1);
  });

  await t('db: a stage without a stored click is refused (409)', async () => {
    const missing = randomUUID();
    assert.equal(await stage('classic', missing, 'game_landing'), 409);
    assert.equal((await stages('entry_id = $1', [missing])).length, 0);
  });

  await t('db: play before landing is refused until the landing exists', async () => {
    const { entryId } = await click('induckup');
    assert.equal(await stage('induckup', entryId, 'game_play_start'), 409);
    assert.equal(await stage('induckup', entryId, 'game_first_result'), 409);
    assert.equal(await stage('induckup', entryId, 'game_landing'), 204);
    assert.equal(await stage('induckup', entryId, 'game_play_start'), 204);
  });

  await t('db: an entry cannot be reused by another game', async () => {
    const { entryId } = await click('classic');
    assert.equal(await stage('survival', entryId, 'game_landing'), 409, 'database refuses the other game');
    assert.equal(await stage('classic', entryId, 'game_landing', randomUUID(), 'survival'), 400,
      'API refuses a body target that differs from the origin');
    assert.equal((await stages('entry_id = $1', [entryId])).length, 0);
  });

  await t('db: an entry older than 30 minutes has expired', async () => {
    const { entryId } = await click('classic');
    await admin.query(`update public.hub_events set created_at = now() - interval '31 minutes' where event_id = $1`, [entryId]);
    assert.equal(await stage('classic', entryId, 'game_landing'), 409);
    const fresh = await click('classic');
    await admin.query(`update public.hub_events set created_at = now() - interval '29 minutes' where event_id = $1`, [fresh.entryId]);
    assert.equal(await stage('classic', fresh.entryId, 'game_landing'), 204);
  });

  await t('db: campus and Grow entries are supported and inherit acquisition metadata', async () => {
    const campus = await click('campus');
    assert.equal(await stage('campus', campus.entryId, 'game_landing'), 204);
    assert.equal((await stages('entry_id = $1', [campus.entryId]))[0].target, 'campus');
    const grow = await click('induck-grow', { acquisition_source: 'everytime', campaign: 'induck_grow_v1_launch_20260925' });
    assert.equal(await stage('induck-grow', grow.entryId, 'game_landing'), 204);
    assert.equal(await stage('induck-grow', grow.entryId, 'game_play_start'), 204);
    const stored = await stages('entry_id = $1', [grow.entryId]);
    assert.deepEqual(stored.map((r) => r.event_type), ['game_landing', 'game_play_start']);
    for (const row of stored) {
      assert.equal(row.acquisition_source, 'everytime');
      assert.equal(row.campaign, 'induck_grow_v1_launch_20260925');
    }
  });

  await t('db: ranked start is classic-only and needs a landing', async () => {
    const { entryId } = await click('classic');
    assert.equal(await stage('classic', entryId, 'classic_ranked_start'), 409);
    assert.equal(await stage('classic', entryId, 'game_landing'), 204);
    assert.equal(await stage('classic', entryId, 'classic_ranked_start'), 204);
    const other = await click('induckup');
    assert.equal(await stage('induckup', other.entryId, 'game_landing'), 204);
    assert.equal(await stage('induckup', other.entryId, 'classic_ranked_start'), 409);
  });

  await t('db: hub events the context check refuses are 400 and store nothing', async () => {
    const session = randomUUID();
    sessions.push(session);
    const send = (overrides) => post('/api/hub-event', hubHeaders,
      eventBody({ event_id: randomUUID(), session_id: session, visitor_id: randomUUID(), ...overrides }));
    assert.equal(await send({ event_type: 'hub_game_click', surface: 'home', target: 'campus' }), 400);
    assert.equal(await send({ event_type: 'hub_game_click', surface: 'home', target: 'tetris' }), 400);
    assert.equal(await send({ event_type: 'hub_visit', surface: 'lobby', target: null }), 400);
    assert.equal(await send({ event_type: 'first_reward', surface: 'campus', target: null }), 400);
    assert.equal(await send({ event_type: 'asset_canary_active', surface: 'campus', target: 'some-user-or-secret' }), 400);
    assert.equal(await send({ event_type: 'asset_canary_active', surface: 'campus', target: 'induck_v3' }), 204);
    const { rows } = await admin.query('select count(*)::int as n from public.hub_events where session_id = $1', [session]);
    assert.equal(rows[0].n, 1);
  });

  await t('db: the 121st event of a session within an hour is 400', async () => {
    const session = randomUUID();
    sessions.push(session);
    await admin.query(`insert into public.hub_events(event_id, session_id, visitor_id, event_type, surface)
      select gen_random_uuid(), $1, gen_random_uuid(), 'hub_visit', 'home' from generate_series(1, 119)`, [session]);
    const send = () => post('/api/hub-event', hubHeaders, eventBody({
      event_id: randomUUID(), session_id: session, event_type: 'hub_visit', surface: 'home', target: null }));
    assert.equal(await send(), 204, '120th');
    assert.equal(await send(), 400, '121st');
  });

  await t('db: a value Postgres cannot cast is a database error -> 502', async () => {
    // UUID.test() coerces, so a one-element array passes the guard, as in the original.
    const status = await post('/api/hub-entry', { origin: GAME_ORIGIN.classic }, entryBody({ event_id: [ID.event] }));
    assert.equal(status, 502);
  });

  await t('db: the canary flag is read live, defaults to the stored value, and follows an operator update', async () => {
    const before = (await admin.query(`select enabled from public.runtime_flags where flag = 'asset_glb_canary_v1'`)).rows[0].enabled;
    try {
      for (const enabled of [false, true, false]) {
        await admin.query(`update public.runtime_flags set enabled = $1, updated_at = now() where flag = 'asset_glb_canary_v1'`, [enabled]);
        const res = await flag();
        assert.equal(res.status, 200);
        assert.deepEqual(await res.json(), { enabled });
      }
    } finally {
      await admin.query(`update public.runtime_flags set enabled = $1 where flag = 'asset_glb_canary_v1'`, [before]);
    }
  });

  await t('db: the Worker role cannot read the event tables or change the flag', async () => {
    for (const statement of [
      'select 1 from public.hub_events limit 1',
      'select 1 from public.game_entries limit 1',
      `update public.runtime_flags set enabled = true where flag = 'asset_glb_canary_v1'`,
    ]) {
      await assert.rejects(app.query(statement), { code: '42501' }, statement);
    }
  });

  // leave the database as it was found
  await admin.query('delete from public.game_entries where session_id = any($1::uuid[])', [sessions]);
  await admin.query('delete from public.hub_events where session_id = any($1::uuid[])', [sessions]);
  await app.end();
  if (!member) await admin.query('revoke inha_world_tier2_app from current_user');
  await admin.end();
}

// ---- report ----
for (const failure of failures) console.log(failure);
console.log(`database integration: ${integration}`);
console.log(`${passed}/${total} passed`);
process.exit(failures.length === 0 ? 0 : 1);

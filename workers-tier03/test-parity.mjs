// Parity test for the Tier 3 Worker against the original handlers
// (aldol2678/inhagame: apps/world/api/world-collection-book.js, world-fishing.js and
// their server/*.mjs services; supabase/functions/ranked-run-start, ranked-run-finish,
// world-duck-observe, verify-inha-mail) and their contract tests
// (apps/world/tests/collection-book.test.mjs, fishing-service.test.mjs,
// supabase/tests/edge/*.test.mjs).
//
//   npm install && node test-parity.mjs
//
// The unmodified worker.js runs with the real @neondatabase/serverless driver; only
// the driver's HTTP transport is replaced (neonConfig.fetchFunction). No network, no
// database.
//
// Optional end-to-end pass against a real Postgres that has schema.sql applied (a
// disposable local database or an ISOLATED Neon branch — never the live one):
//
//   TEST_PG_URL=postgresql://... node test-parity.mjs
//
// A non-loopback TEST_PG_URL is refused unless TEST_PG_ALLOW_REMOTE=1 is also set.
// The URL is read from the environment only and is never printed.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { neonConfig } from '@neondatabase/serverless';
import worker from './worker.js';
import { createPositionReporter, classifyPositionState, createRevisionCounter } from './client/fishing-position-reporter.js';

// ---- mini runner ----
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
const ENV = { DATABASE_URL: 'postgresql://parity:parity@db.invalid/parity', WORLD_FISHING_API_ENABLED: '1' };
const SID = '2b3c4d5e-6f70-4b8c-ad9e-1f2a3b4c5d6e'; // the caller's session id
const ID = {
  attempt: '0b1c2d3e-4f50-4a61-8b72-938495a6b7c8',
  key: '1a2b3c4d-5e6f-4a7b-9c8d-0e1f2a3b4c5d',
  nonce: '3c4d5e6f-7081-4c9d-be0f-2a3b4c5d6e7f',
  run: '4d5e6f70-8192-4dae-8f10-3b4c5d6e7f80',
  record: '5e6f7081-92a3-4ebf-9021-4c5d6e7f8091',
};
const OID = { bool: 16, int4: 23, text: 25, json: 114, uuid: 2950, jsonb: 3802 };

/** A successful Neon HTTP reply: one column, one value per row (objects are sent as JSON text). */
const rows = (column, type, values) => () => new Response(JSON.stringify({
  fields: [{ name: column, dataTypeID: OID[type] }],
  rows: values.map((v) => [v === null ? null : typeof v === 'object' ? JSON.stringify(v) : v === true ? 't' : v === false ? 'f' : String(v)]),
  command: 'SELECT', rowCount: values.length, rowAsArray: true,
}), { status: 200 });
/** Postgres answered with an error (a raised exception, a failed cast). */
const dbError = (message, code = 'P0001') => () => new Response(JSON.stringify({ message, code }), { status: 400 });
const unreachable = () => { throw new TypeError('fetch failed'); };
const timedOut = () => { throw new DOMException('The operation timed out.', 'TimeoutError'); };
const unreadable = () => new Response('not json', { status: 200 });

const SESSION = /from public\.sessions where id = \$1/;
const sessionFound = [SESSION, (p) => rows('id', 'text', [p[0]])()];
const sessionMissing = [SESSION, rows('id', 'text', [])];

let calls;
/** routes: [regex, reply(params, query)] in priority order; an unmatched query fails the test. */
function stubDb(...routes) {
  calls = [];
  neonConfig.fetchFunction = async (url, init) => {
    const sent = JSON.parse(init.body);
    calls.push({ query: sent.query, params: sent.params, init });
    for (const [re, reply] of routes) if (re.test(sent.query)) return reply(sent.params, sent.query);
    throw new Error(`unexpected query: ${sent.query}`);
  };
}
const callsTo = (re) => calls.filter((c) => re.test(c.query));
// The Neon HTTP driver sends every non-null scalar parameter as text; the SQL casts it back.
const wire = (values) => values.map((v) => (v === null ? null : String(v)));

async function call(path, { method = 'POST', headers = {}, body, env = ENV, session = SID } = {}) {
  const h = { ...headers };
  if (session) h['x-session-id'] = session;
  const init = { method, headers: h };
  if (body !== undefined && method !== 'GET' && method !== 'HEAD') init.body = typeof body === 'string' ? body : JSON.stringify(body);
  const res = await worker.fetch(new Request(`https://inhagame.app${path}`, init), env);
  const text = await res.text();
  let parsed;
  try { parsed = text ? JSON.parse(text) : undefined; } catch { parsed = undefined; }
  return { status: res.status, headers: res.headers, text, json: parsed };
}
const leaks = (needles) => {
  const sent = JSON.stringify(calls.map((c) => [c.query, c.params, [...new Headers(c.init.headers).entries()]]));
  return needles.filter((n) => sent.includes(n));
};

// =====================================================================
// session verification (replaces verifyNpcAiUser / auth.getUser)
// =====================================================================
const BOOK = '/api/world-collection-book';
const BOOK_RPC = /world_collection_list_v1/;
const HOST = { host: 'inhagame.app' };
const rawBook = (overrides = {}) => ({ userId: SID, entries: [
  { entryId: 'collection.artifact.campus_fragment_01', category: 'ARTIFACT', persistenceMode: 'SERVER_PERSISTED', ownerDomain: null, ownerRef: null,
    catalogStatus: 'COMING_SOON', definitionVersion: 1, discoveryState: 'UNKNOWN', discovered: false, firstDiscoveredAt: null, lastDiscoveredAt: null, discoveryCount: 0, version: 0 },
  { entryId: 'collection.fish.carp', category: 'FISH', persistenceMode: 'SERVER_PERSISTED', ownerDomain: null, ownerRef: null,
    catalogStatus: 'ACTIVE', definitionVersion: 1, discoveryState: 'DISCOVERED', discovered: true,
    firstDiscoveredAt: '2026-11-11T10:00:00+00:00', lastDiscoveredAt: '2026-11-11T11:00:00+00:00', discoveryCount: 2, version: 2 },
  { entryId: 'collection.place.biryong_tower', category: 'PLACE', persistenceMode: 'DERIVED_FROM_OWNER', ownerDomain: 'BIRYONG', ownerRef: 'BR01',
    catalogStatus: 'ACTIVE', definitionVersion: 1, discoveryState: 'OWNER_DERIVED', discovered: null, firstDiscoveredAt: null, lastDiscoveredAt: null, discoveryCount: null, version: null },
  { entryId: 'collection.plant.campus_leaf', category: 'PLANT', persistenceMode: 'SERVER_PERSISTED', ownerDomain: null, ownerRef: null,
    catalogStatus: 'COMING_SOON', definitionVersion: 1, discoveryState: 'UNKNOWN', discovered: false, firstDiscoveredAt: null, lastDiscoveredAt: null, discoveryCount: 0, version: 0 },
], ...overrides });
const bookOk = [BOOK_RPC, rows('result', 'jsonb', [rawBook()])];
const book = (options = {}) => call(BOOK, { method: 'GET', headers: HOST, ...options });

await t('session: an existing session id is the actor, looked up by exact id', async () => {
  stubDb(sessionFound, bookOk);
  const res = await book();
  assert.equal(res.status, 200);
  assert.equal(calls[0].query, 'select id from public.sessions where id = $1 limit 1');
  assert.deepEqual(calls[0].params, [SID]);
  assert.deepEqual(callsTo(BOOK_RPC)[0].params, [SID]);
  assert.ok(calls[0].init.signal instanceof AbortSignal);
});
await t('session: the id is lower-cased before the lookup (sessions.id is lower-case text)', async () => {
  stubDb(sessionFound, [BOOK_RPC, rows('result', 'jsonb', [rawBook()])]);
  const res = await book({ session: SID.toUpperCase() });
  assert.equal(res.status, 200);
  assert.deepEqual(calls[0].params, [SID]);
});
for (const [name, session] of [['missing', null], ['empty', ''], ['not a uuid', 'guest-session'], ['nil uuid', '00000000-0000-0000-0000-000000000000'],
  ['uuid with a suffix', `${SID}0`], ['uuid with a prefix', `x${SID}`], ['sql-ish', "' or 1=1 --"]]) {
  await t(`session: ${name} X-Session-Id is 401 and never reaches the database`, async () => {
    stubDb(sessionFound, bookOk);
    const res = await call(BOOK, { method: 'GET', headers: session === null ? HOST : { ...HOST, 'x-session-id': session }, session: null });
    assert.equal(res.status, 401);
    assert.deepEqual(res.json, { error: 'AUTH_REQUIRED' });
    assert.equal(calls.length, 0);
  });
}
await t('session: a well-formed id that is not in sessions is 401, the RPC is not called', async () => {
  stubDb(sessionMissing, bookOk);
  const res = await book();
  assert.equal(res.status, 401);
  assert.equal(callsTo(BOOK_RPC).length, 0);
});
await t('session: a Supabase bearer token is not a credential any more', async () => {
  stubDb(sessionFound, bookOk);
  const res = await call(BOOK, { method: 'GET', headers: { ...HOST, authorization: `Bearer ${'x'.repeat(40)}` }, session: null });
  assert.equal(res.status, 401);
  assert.equal(calls.length, 0);
});
await t('session: the lookup must return that very id', async () => {
  stubDb([SESSION, rows('id', 'text', ['some-other-id'])], bookOk);
  assert.equal((await book()).status, 401);
  stubDb([SESSION, rows('id', 'text', [SID, SID])], bookOk);
  assert.equal((await book()).status, 401);
});

// =====================================================================
// world-collection-book
// =====================================================================
await t('collection-book: projects the self-only read (hidden entries omitted, provenance never inferred)', async () => {
  stubDb(sessionFound, bookOk);
  const res = await book();
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'private, no-store');
  assert.equal(res.headers.get('vary'), 'X-Session-Id');
  assert.equal(res.headers.get('content-type'), 'application/json; charset=utf-8');
  assert.equal(callsTo(BOOK_RPC)[0].query, 'select public.world_collection_list_v1($1::uuid) as result');
  assert.deepEqual(res.json, { version: 1, discoveredCount: 1, trackableCount: 1, entries: [
    { key: 'collection.fish.carp', title: '붕어', state: 'DISCOVERED', firstDiscoveredAt: '2026-11-11T10:00:00+00:00',
      discoveryCount: 2, sourceLabel: null, hint: null },
    { key: 'collection.place.biryong_tower', title: '비룡탑', state: 'OWNER_DERIVED', firstDiscoveredAt: null,
      discoveryCount: null, sourceLabel: null, hint: '이 항목의 발견 여부는 해당 콘텐츠의 기록에서 확인해요' },
  ] });
});
await t('collection-book: an undiscovered silhouette exposes neither id nor title', async () => {
  const raw = rawBook();
  Object.assign(raw.entries[1], { discoveryState: 'UNKNOWN', discovered: false, firstDiscoveredAt: null, lastDiscoveredAt: null, discoveryCount: 0, version: 0 });
  stubDb(sessionFound, [BOOK_RPC, rows('result', 'jsonb', [raw])]);
  const res = await book();
  assert.equal(res.status, 200);
  assert.deepEqual(res.json.entries[0], { key: 'unrevealed:0', title: '아직 발견하지 못한 기록', state: 'UNKNOWN', firstDiscoveredAt: null,
    discoveryCount: 0, sourceLabel: null, hint: '월드에서 기록을 발견하면 자세한 내용이 표시돼요' });
  assert.ok(!res.text.includes('collection.fish.carp') && !res.text.includes('붕어'));
  assert.equal(res.json.discoveredCount, 0);
});
await t('collection-book: registry / catalog disagreement hides the entry instead of failing', async () => {
  for (const patch of [{ catalogStatus: 'DISABLED' }, { category: 'PLANT' }, { definitionVersion: 2 }, { persistenceMode: 'SESSION_ONLY' }]) {
    const raw = rawBook();
    Object.assign(raw.entries[1], patch);
    stubDb(sessionFound, [BOOK_RPC, rows('result', 'jsonb', [raw])]);
    const res = await book();
    assert.equal(res.status, 200, JSON.stringify(patch));
    assert.deepEqual(res.json.entries.map((e) => e.key), ['collection.place.biryong_tower'], JSON.stringify(patch));
  }
});
for (const [name, mutate] of [
  ['the row is for another session (raw.userId must equal the actor)', (r) => { r.userId = ID.key; }],
  ['userId is missing', (r) => { delete r.userId; }],
  ['entries is not an array', (r) => { r.entries = {}; }],
  ['a duplicate entry id', (r) => { r.entries.push(r.entries[1]); }],
  ['an entry without an id', (r) => { r.entries[0] = { category: 'FISH' }; }],
  ['a discovered row without a first time', (r) => { r.entries[1].firstDiscoveredAt = null; }],
  ['last discovery before the first', (r) => { r.entries[1].lastDiscoveredAt = '2026-11-10T00:00:00+00:00'; }],
  ['a discovered row with a zero count', (r) => { r.entries[1].discoveryCount = 0; }],
  ['a persisted row that claims an owner', (r) => { r.entries[1].ownerDomain = 'BIRYONG'; }],
  ['an owner-derived row that claims a discovery', (r) => { r.entries[2].discovered = true; }],
  ['an owner-derived row with the wrong owner ref', (r) => { r.entries[2].ownerRef = 'BR02'; }],
  ['an unknown discovery state', (r) => { r.entries[1].discoveryState = 'MAYBE'; }],
]) {
  await t(`collection-book: ${name} -> 503`, async () => {
    const raw = rawBook();
    mutate(raw);
    stubDb(sessionFound, [BOOK_RPC, rows('result', 'jsonb', [raw])]);
    const res = await book();
    assert.equal(res.status, 503);
    assert.deepEqual(res.json, { error: 'COLLECTION_BOOK_UNAVAILABLE' });
  });
}
for (const [name, reply, status, error] of [
  ['RPC says ACCOUNT_UNAVAILABLE (the session row vanished after the lookup)', dbError('ACCOUNT_UNAVAILABLE', '22023'), 403, 'ACCOUNT_UNAVAILABLE'],
  ['any other database error', dbError('boom', 'XX000'), 503, 'COLLECTION_BOOK_UNAVAILABLE'],
  ['database unreachable', unreachable, 503, 'COLLECTION_BOOK_UNAVAILABLE'],
  ['database timeout', timedOut, 503, 'COLLECTION_BOOK_UNAVAILABLE'],
  ['unreadable reply', unreadable, 503, 'COLLECTION_BOOK_UNAVAILABLE'],
  ['null result', rows('result', 'jsonb', [null]), 503, 'COLLECTION_BOOK_UNAVAILABLE'],
  ['no row', rows('result', 'jsonb', []), 503, 'COLLECTION_BOOK_UNAVAILABLE'],
]) {
  await t(`collection-book: ${name} -> ${status} ${error}`, async () => {
    stubDb(sessionFound, [BOOK_RPC, reply]);
    const res = await book();
    assert.equal(res.status, status);
    assert.deepEqual(res.json, { error });
    assert.equal(res.headers.get('cache-control'), 'private, no-store');
  });
}
await t('collection-book: a failed session lookup is 503, not 401', async () => {
  for (const reply of [unreachable, dbError('relation "sessions" does not exist', '42P01'), unreadable]) {
    stubDb([SESSION, reply], bookOk);
    const res = await book();
    assert.equal(res.status, 503);
    assert.deepEqual(res.json, { error: 'COLLECTION_BOOK_UNAVAILABLE' });
    assert.equal(callsTo(BOOK_RPC).length, 0);
  }
});
await t('collection-book: DATABASE_URL unset -> 503 after every guard, no request is made', async () => {
  stubDb(sessionFound, bookOk);
  const env = {};
  assert.equal((await book({ env })).status, 503);
  assert.equal((await call(BOOK, { method: 'POST', headers: HOST, env })).status, 405);
  assert.equal((await call(`${BOOK}?x=1`, { method: 'GET', headers: HOST, env })).status, 400);
  assert.equal((await call(BOOK, { method: 'GET', headers: { origin: 'https://evil.example', host: 'inhagame.app' }, env })).status, 403);
  assert.equal((await call(BOOK, { method: 'GET', headers: HOST, env, session: null })).status, 401);
  assert.equal(calls.length, 0);
});
for (const method of ['POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS']) {
  await t(`collection-book: ${method} is 405 with Allow: GET`, async () => {
    stubDb(sessionFound, bookOk);
    const res = await call(BOOK, { method, headers: HOST, body: method === 'OPTIONS' ? undefined : '{}' });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('allow'), 'GET');
    assert.equal(res.headers.get('cache-control'), 'private, no-store');
    assert.equal(calls.length, 0);
  });
}
await t('collection-book guard order: method (405) -> query (400) -> Origin (403) -> session (401)', async () => {
  stubDb(sessionFound, bookOk);
  const evil = { origin: 'https://evil.example', host: 'inhagame.app' };
  assert.equal((await call(`${BOOK}?x=1`, { method: 'POST', headers: evil, session: null })).status, 405);
  assert.equal((await call(`${BOOK}?x=1`, { method: 'GET', headers: evil, session: null })).status, 400);
  assert.equal((await call(`${BOOK}?`, { method: 'GET', headers: HOST })).status, 400);
  assert.equal((await call(BOOK, { method: 'GET', headers: evil, session: null })).status, 403);
  assert.equal((await call(BOOK, { method: 'GET', headers: HOST, session: null })).status, 401);
  assert.equal(calls.length, 0);
});
for (const headers of [{ origin: 'https://evil.example', host: 'inhagame.app' }, { origin: 'not a url', host: 'inhagame.app' },
  { origin: 'https://inhagame.app' }, { origin: 'null', host: 'inhagame.app' }]) {
  await t(`collection-book: cross-site ${JSON.stringify(headers)} is 403`, async () => {
    stubDb(sessionFound, bookOk);
    assert.equal((await call(BOOK, { method: 'GET', headers })).status, 403);
    assert.equal(calls.length, 0);
  });
}

// =====================================================================
// world-fishing
// =====================================================================
const FISH = '/api/world-fishing';
const FH = { ...HOST, 'content-type': 'application/json' };
const N1 = 'fishing.inkyung.north_01';
const startBody = (o = {}) => ({ op: 'start', activityId: 'activity.fishing.inkyung', sourceRef: N1, clientAttemptKey: ID.key, ...o });
const inputBody = (o = {}) => ({ op: 'input', attemptId: ID.attempt, sourceRef: N1, nonce: ID.nonce, action: 'HOOK', ...o });
const FISH_RPC = /world_fishing_(start|input|settle|read)_v1/;
const fishOk = (payload = { status: 'STARTED', attempt: { attemptId: ID.attempt } }) => [FISH_RPC, rows('result', 'jsonb', [payload])];
const fish = (body, options = {}) => call(FISH, { headers: FH, body, ...options });

for (const [name, body, query, params] of [
  ['start', startBody(), 'select public.world_fishing_start_v1($1::uuid, $2::text, $3::uuid) as result', [SID, N1, ID.key]],
  ['input', inputBody(), 'select public.world_fishing_input_v1($1::uuid, $2::uuid, $3::text, $4::uuid, $5::text) as result', [SID, ID.attempt, N1, ID.nonce, 'HOOK']],
  ['input CANCEL', inputBody({ action: 'CANCEL' }), 'select public.world_fishing_input_v1($1::uuid, $2::uuid, $3::text, $4::uuid, $5::text) as result', [SID, ID.attempt, N1, ID.nonce, 'CANCEL']],
  ['settle', { op: 'settle', attemptId: ID.attempt }, 'select public.world_fishing_settle_v1($1::uuid, $2::uuid) as result', [SID, ID.attempt]],
  ['read by id', { op: 'read', attemptId: ID.attempt.toUpperCase() }, 'select public.world_fishing_read_v1($1::uuid, $2::uuid) as result', [SID, ID.attempt]],
  ['read latest', { op: 'read' }, 'select public.world_fishing_read_v1($1::uuid, $2::uuid) as result', [SID, null]],
]) {
  await t(`fishing: ${name} calls its RPC with the session id as p_user and returns the payload`, async () => {
    const payload = { status: 'OK', attempt: { attemptId: ID.attempt, biteAtMs: 1794377592699 }, nested: [1, { a: null }] };
    stubDb(sessionFound, fishOk(payload));
    const res = await fish(body);
    assert.equal(res.status, 200);
    assert.deepEqual(res.json, payload);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(res.headers.get('content-type'), 'application/json; charset=utf-8');
    const [rpc] = callsTo(FISH_RPC);
    assert.equal(rpc.query, query);
    assert.deepEqual(rpc.params, params);
    assert.equal(callsTo(FISH_RPC).length, 1, 'mutations are never retried');
  });
}
await t('fishing: the caller cannot supply the actor, clock, policy, roll, quantity, discovery or XP', async () => {
  for (const extra of [{ userId: ID.key }, { p_user: ID.key }, { policy: {} }, { nowMs: 1 }, { quantity: 99 }, { lifeXp: 9999 }, { actorUserId: ID.key }]) {
    stubDb(sessionFound, fishOk());
    for (const body of [startBody(extra), inputBody(extra), { op: 'settle', attemptId: ID.attempt, ...extra }, { op: 'read', ...extra }]) {
      const res = await fish(body);
      assert.equal(res.status, 400, JSON.stringify(body));
      assert.deepEqual(res.json, { error: 'INVALID_REQUEST' });
    }
    assert.equal(calls.length, 0);
  }
});
for (const [name, body] of [
  ['unknown op', { op: 'observe' }], ['missing op', { activityId: 'activity.fishing.inkyung' }], ['op not a string', { op: 5 }],
  ['start: wrong activity', startBody({ activityId: 'activity.gathering.leaf' })], ['start: unknown spot', startBody({ sourceRef: 'fishing.inkyung.west_01' })],
  ['start: key not a uuid', startBody({ clientAttemptKey: 'abc' })], ['start: nil key', startBody({ clientAttemptKey: '00000000-0000-0000-0000-000000000000' })],
  ['start: missing key', startBody({ clientAttemptKey: undefined })], ['start: key as array', startBody({ clientAttemptKey: [ID.key] })],
  ['input: unknown action', inputBody({ action: 'REEL' })], ['input: lower-case action', inputBody({ action: 'hook' })],
  ['input: missing nonce', inputBody({ nonce: undefined })], ['input: bad attempt id', inputBody({ attemptId: `${ID.attempt}0` })],
  ['input: unknown spot', inputBody({ sourceRef: 'x' })],
  ['settle: missing attempt id', { op: 'settle' }], ['settle: bad attempt id', { op: 'settle', attemptId: 7 }],
  ['read: bad attempt id', { op: 'read', attemptId: 'latest' }], ['read: null attempt id', { op: 'read', attemptId: null }],
  ['JSON array', []], ['JSON null', null], ['JSON number', 7], ['JSON string', 'start'],
]) {
  await t(`fishing: ${name} -> 400 INVALID_REQUEST before the session is even looked up`, async () => {
    stubDb(sessionFound, fishOk());
    const res = await fish(body);
    assert.equal(res.status, 400);
    assert.deepEqual(res.json, { error: 'INVALID_REQUEST' });
    assert.equal(calls.length, 0);
  });
}
await t('fishing: request shape (400) is decided before the session (401)', async () => {
  stubDb(sessionMissing, fishOk());
  assert.equal((await fish({ op: 'nope' }, { session: null })).status, 400);
  const res = await fish(startBody(), { session: null });
  assert.equal(res.status, 401);
  assert.deepEqual(res.json, { error: 'AUTH_REQUIRED' });
  assert.equal((await fish(startBody())).status, 401, 'well-formed but unknown session');
  assert.equal(callsTo(FISH_RPC).length, 0);
});
await t('fishing: a failed session lookup is 503 AUTH_UNAVAILABLE', async () => {
  for (const reply of [unreachable, timedOut, dbError('boom', 'XX000')]) {
    stubDb([SESSION, reply], fishOk());
    const res = await fish(startBody());
    assert.equal(res.status, 503);
    assert.deepEqual(res.json, { error: 'AUTH_UNAVAILABLE' });
    assert.equal(callsTo(FISH_RPC).length, 0);
  }
});
for (const [code, status] of [
  ['FISHING_POSITION_UNAVAILABLE', 409], ['FISHING_POSITION_STALE', 409], ['FISHING_POSITION_INELIGIBLE', 409], ['FISHING_OUT_OF_RANGE', 409],
  ['FISHING_SPOT_OCCUPIED', 409], ['FISHING_LEASE_LOST', 409], ['FISHING_SESSION_CHANGED', 409], ['ACCOUNT_UNAVAILABLE', 403],
  ['FISHING_UNAVAILABLE', 409], ['FISHING_RATE_LIMITED', 429], ['ATTEMPT_NOT_FOUND', 404], ['ATTEMPT_ALREADY_ACTIVE', 409],
  ['IDEMPOTENCY_CONFLICT', 409], ['TERMINAL_COMMAND_CONFLICT', 409], ['ACTIVITY_OUTCOME_CONFLICT', 409], ['FISHING_NOT_SUCCEEDED', 409],
  ['FISHING_IDENTITY_MISMATCH', 400], ['OUTPUT_UNAVAILABLE', 409], ['MAX_STACK_EXCEEDED', 409], ['COLLECTION_ENTRY_INACTIVE', 409],
  ['LIFE_SKILL_INACTIVE', 409], ['SETTLEMENT_PLAN_CONFLICT', 409],
]) {
  await t(`fishing: RPC exception ${code} -> ${status}`, async () => {
    stubDb(sessionFound, [FISH_RPC, dbError(code)]);
    const res = await fish(startBody());
    assert.equal(res.status, status);
    assert.deepEqual(res.json, { error: code });
  });
}
for (const [name, reply] of [
  ['an unmapped exception (FISHING_POLICY_INVALID)', dbError('FISHING_POLICY_INVALID', '22023')],
  ['INVALID_FISHING_IDENTITY', dbError('INVALID_FISHING_IDENTITY', '22023')],
  ['a permission error', dbError('permission denied for function world_fishing_start_v1', '42501')],
  ['database unreachable', unreachable], ['database timeout', timedOut], ['unreadable reply', unreadable],
  ['no row', rows('result', 'jsonb', [])],
]) {
  await t(`fishing: ${name} -> 503 FISHING_UNAVAILABLE`, async () => {
    stubDb(sessionFound, [FISH_RPC, reply]);
    const res = await fish(startBody());
    assert.equal(res.status, 503);
    assert.deepEqual(res.json, { error: 'FISHING_UNAVAILABLE' });
  });
}
await t('fishing: a mapped code only counts when the database raised it (not a transport error text)', async () => {
  stubDb(sessionFound, [FISH_RPC, () => { throw new TypeError('ATTEMPT_NOT_FOUND'); }]);
  assert.equal((await fish(startBody())).status, 503);
});
await t('fishing: WORLD_FISHING_API_ENABLED unset -> 404 before anything else', async () => {
  stubDb(sessionFound, fishOk());
  for (const env of [{ DATABASE_URL: ENV.DATABASE_URL }, { ...ENV, WORLD_FISHING_API_ENABLED: '0' }, { ...ENV, WORLD_FISHING_API_ENABLED: 'true' }]) {
    for (const init of [{ method: 'GET' }, { method: 'POST', body: '{' }, { method: 'POST', body: startBody(), headers: FH },
      { method: 'POST', headers: { origin: 'https://evil.example', host: 'inhagame.app' } }]) {
      const res = await call(FISH, { ...init, env });
      assert.equal(res.status, 404);
      assert.equal(res.text, '');
      assert.equal(res.headers.get('cache-control'), 'no-store');
    }
  }
  assert.equal(calls.length, 0);
});
for (const method of ['GET', 'PUT', 'DELETE', 'PATCH', 'OPTIONS']) {
  await t(`fishing: ${method} is 405 with Allow: POST`, async () => {
    stubDb(sessionFound, fishOk());
    const res = await call(FISH, { method, headers: FH });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('allow'), 'POST');
    assert.equal(calls.length, 0);
  });
}
for (const type of [undefined, 'text/plain', 'application/jsonx', 'application/x-www-form-urlencoded', 'multipart/form-data']) {
  await t(`fishing: content-type ${type} is 415`, async () => {
    stubDb(sessionFound, fishOk());
    const headers = { ...HOST };
    if (type) headers['content-type'] = type;
    assert.equal((await call(FISH, { headers, body: JSON.stringify(startBody()) })).status, 415);
    assert.equal(calls.length, 0);
  });
}
await t('fishing: application/json is matched case-insensitively and with parameters', async () => {
  for (const type of ['application/json; charset=utf-8', 'APPLICATION/JSON', ' application/json ', 'application/json;']) {
    stubDb(sessionFound, fishOk());
    assert.equal((await call(FISH, { headers: { ...HOST, 'content-type': type }, body: startBody() })).status, 200, type);
  }
});
await t('fishing guard order: flag (404) -> method (405) -> content-type (415) -> Origin (403) -> body (413 / 400) -> shape (400) -> session (401)', async () => {
  stubDb(sessionMissing, fishOk());
  const evil = { origin: 'https://evil.example', host: 'inhagame.app' };
  assert.equal((await call(FISH, { method: 'GET', headers: { ...evil, 'content-type': 'text/plain' } })).status, 405);
  assert.equal((await call(FISH, { headers: { ...evil, 'content-type': 'text/plain' }, body: '{' })).status, 415);
  assert.equal((await call(FISH, { headers: { ...evil, 'content-type': 'application/json' }, body: 'x'.repeat(9000) })).status, 403);
  assert.equal((await fish('x'.repeat(8193))).status, 413);
  assert.equal((await fish('x'.repeat(8192))).status, 400);
  assert.equal((await fish({ op: 'nope' })).status, 400);
  assert.equal((await fish(startBody())).status, 401);
});
await t('fishing: the 8192-byte limit counts bytes of the parsed value, not characters or padding', async () => {
  stubDb(sessionFound, fishOk());
  assert.equal((await fish(JSON.stringify({ op: 'read', pad: 'x'.repeat(8192) }))).status, 413);
  assert.equal((await fish(`{"op":"read","attemptId":"${'가'.repeat(2800)}"}`)).status, 413, '2800 Hangul characters are 8400 bytes');
  assert.equal((await fish(`{"op":"read","attemptId":"${'가'.repeat(2000)}"}`)).status, 400, 'under the limit: refused for its shape');
  assert.equal((await fish(JSON.stringify({ op: 'read' }) + ' '.repeat(9000))).status, 200, 'insignificant whitespace is not counted');
  assert.equal((await fish('{'.repeat(8193))).status, 413, 'unparseable and over the limit: 413 before 400');
});
for (const headers of [{ origin: 'https://evil.example', host: 'inhagame.app' }, { origin: 'not a url', host: 'inhagame.app' },
  { origin: 'https://inhagame.app' }, { origin: 'https://inhagame.app:8443', host: 'inhagame.app' }]) {
  await t(`fishing: cross-site ${JSON.stringify(headers)} is 403`, async () => {
    stubDb(sessionFound, fishOk());
    assert.equal((await call(FISH, { headers: { ...headers, 'content-type': 'application/json' }, body: startBody() })).status, 403);
    assert.equal(calls.length, 0);
  });
}
await t('fishing: DATABASE_URL unset -> 503 AUTH_UNAVAILABLE after every guard, no request is made', async () => {
  stubDb(sessionFound, fishOk());
  const env = { WORLD_FISHING_API_ENABLED: '1' };
  const res = await fish(startBody(), { env });
  assert.equal(res.status, 503);
  assert.deepEqual(res.json, { error: 'AUTH_UNAVAILABLE' });
  assert.equal((await fish({ op: 'nope' }, { env })).status, 400);
  assert.equal((await fish(startBody(), { env, session: null })).status, 401);
  assert.equal(calls.length, 0);
});

// =====================================================================
// ranked-run-start
// =====================================================================
const START = '/api/ranked-run-start';
const EXPIRE = /expire_ranked_sessions_v1/;
const PROFILE = /from public\.profiles where user_id/;
const COUNT = /count\(\*\)::int as count from public\.ranked_sessions/;
const INSERT_SESSION = /insert into public\.ranked_sessions/;
const sessionRow = (o = {}) => ({ run_id: ID.run, nonce: ID.nonce, started_at: '2026-11-11T17:00:00.123456+00:00',
  expires_at: '2026-11-11T17:05:00.123456+00:00', run_type: 'ranked', ruleset_version: 'secret-2.1-r1', ...o });
const profileRow = (banned = false) => [PROFILE, () => new Response(JSON.stringify({
  fields: [{ name: 'user_id', dataTypeID: OID.uuid }, { name: 'is_banned', dataTypeID: OID.bool }], rows: [[SID, banned ? 't' : 'f']],
  command: 'SELECT', rowCount: 1, rowAsArray: true }))];
const noProfile = [PROFILE, () => new Response(JSON.stringify({
  fields: [{ name: 'user_id', dataTypeID: OID.uuid }, { name: 'is_banned', dataTypeID: OID.bool }], rows: [], command: 'SELECT', rowCount: 0, rowAsArray: true }))];
const startRoutes = (o = {}) => [sessionFound, [EXPIRE, o.expire ?? rows('expired', 'int4', [0])], o.profile ?? profileRow(),
  [COUNT, o.count ?? rows('count', 'int4', [0])], [INSERT_SESSION, o.insert ?? rows('session', 'json', [sessionRow(o.session)])]];
const CORS_HEADERS = 'authorization, x-client-info, apikey, content-type, x-session-id';
const assertCors = (res) => {
  assert.equal(res.headers.get('access-control-allow-origin'), '*');
  assert.equal(res.headers.get('access-control-allow-headers'), CORS_HEADERS);
  assert.equal(res.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
};

await t('ranked-run-start: starts a ranked session for the session owner', async () => {
  stubDb(...startRoutes());
  const res = await call(START, { body: { clientVersion: 'classic-2.2.0' } });
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { runId: ID.run, nonce: ID.nonce, startedAt: '2026-11-11T17:00:00.123456+00:00',
    expiresAt: '2026-11-11T17:05:00.123456+00:00', runType: 'ranked', rulesetVersion: 'secret-2.1-r1' });
  assertCors(res);
  assert.equal(res.headers.get('content-type'), 'application/json');
  assert.equal(res.headers.get('cache-control'), 'no-store');
  const [insert] = callsTo(INSERT_SESSION);
  assert.deepEqual(insert.params, [SID, 'classic-2.2.0', 'ranked', 'secret-2.1-r1']);
  assert.deepEqual(callsTo(PROFILE)[0].params, [SID]);
  assert.equal(callsTo(COUNT)[0].params[0], SID);
  assert.ok(Math.abs(Date.parse(callsTo(COUNT)[0].params[1]) - (Date.now() - 600000)) < 5000, 'ten-minute window');
  assert.equal(callsTo(EXPIRE).length, 1, 'lifecycle cleanup runs on every start');
});
for (const [name, body, expected] of [
  ['defaults', {}, [null, 'ranked', 'secret-2.1-r1']],
  ['qa run', { runType: 'qa' }, [null, 'qa', 'secret-2.1-r1']],
  ['unknown run type falls back to ranked', { runType: 'QA' }, [null, 'ranked', 'secret-2.1-r1']],
  ['next ruleset', { rulesetVersion: 'secret-2.2-r1' }, [null, 'ranked', 'secret-2.2-r1']],
  ['unknown ruleset falls back to the default', { rulesetVersion: 'secret-9.9' }, [null, 'ranked', 'secret-2.1-r1']],
  ['client version is truncated to 40 characters', { clientVersion: 'v'.repeat(100) }, ['v'.repeat(40), 'ranked', 'secret-2.1-r1']],
  ['client version is stringified', { clientVersion: 12345 }, ['12345', 'ranked', 'secret-2.1-r1']],
  ['a malformed body starts a default ranked session', 'not json', [null, 'ranked', 'secret-2.1-r1']],
  ['an empty body starts a default ranked session', '', [null, 'ranked', 'secret-2.1-r1']],
  ['JSON null', 'null', [null, 'ranked', 'secret-2.1-r1']],
]) {
  await t(`ranked-run-start: ${name}`, async () => {
    stubDb(...startRoutes());
    const res = await call(START, { body });
    assert.equal(res.status, 200);
    assert.deepEqual(callsTo(INSERT_SESSION)[0].params, [SID, ...expected]);
  });
}
await t('ranked-run-start: CORS preflight and wrong methods', async () => {
  stubDb(...startRoutes());
  const pre = await call(START, { method: 'OPTIONS', session: null });
  assert.equal(pre.status, 200);
  assert.equal(pre.text, 'ok');
  assertCors(pre);
  for (const method of ['GET', 'PUT', 'DELETE']) {
    const res = await call(START, { method });
    assert.equal(res.status, 405);
    assert.equal(res.text, 'Method Not Allowed');
    assertCors(res);
  }
  assert.equal(calls.length, 0);
});
await t('ranked-run-start: missing or unknown sessions are unauthenticated and write nothing', async () => {
  for (const [routes, session] of [[startRoutes(), null], [[sessionMissing, ...startRoutes().slice(1)], SID], [startRoutes(), 'garbage']]) {
    stubDb(...routes);
    const res = await call(START, { body: {}, session: null, headers: session ? { 'x-session-id': session } : {} });
    assert.equal(res.status, 401);
    assert.deepEqual(res.json, { error: 'UNAUTHENTICATED' });
    assertCors(res);
    assert.equal(callsTo(INSERT_SESSION).length + callsTo(EXPIRE).length, 0);
  }
});
await t('ranked-run-start: a failed session lookup is also UNAUTHENTICATED (the original treats an auth error as no user)', async () => {
  stubDb([SESSION, unreachable], ...startRoutes().slice(1));
  const res = await call(START, { body: {} });
  assert.equal(res.status, 401);
  assert.equal(callsTo(INSERT_SESSION).length, 0);
});
await t('ranked-run-start: ranked runs need a profile row; QA runs do not', async () => {
  stubDb(...startRoutes({ profile: noProfile }));
  const ranked = await call(START, { body: {} });
  assert.equal(ranked.status, 409);
  assert.deepEqual(ranked.json, { error: 'PROFILE_REQUIRED' });
  assert.equal(callsTo(INSERT_SESSION).length, 0);
  stubDb(...startRoutes({ profile: noProfile, session: { run_type: 'qa' } }));
  const qa = await call(START, { body: { runType: 'qa' } });
  assert.equal(qa.status, 200);
  assert.equal(qa.json.runType, 'qa');
});
await t('ranked-run-start: banned profiles are blocked, for QA runs too', async () => {
  for (const body of [{}, { runType: 'qa' }]) {
    stubDb(...startRoutes({ profile: profileRow(true) }));
    const res = await call(START, { body });
    assert.equal(res.status, 403);
    assert.deepEqual(res.json, { error: 'RANKING_BLOCKED' });
    assert.equal(callsTo(INSERT_SESSION).length, 0);
  }
});
await t('ranked-run-start: at most 30 sessions per session id in 10 minutes', async () => {
  stubDb(...startRoutes({ count: rows('count', 'int4', [29]) }));
  assert.equal((await call(START, { body: {} })).status, 200);
  stubDb(...startRoutes({ count: rows('count', 'int4', [30]) }));
  const res = await call(START, { body: {} });
  assert.equal(res.status, 429);
  assert.deepEqual(res.json, { error: 'RATE_LIMITED' });
  assert.equal(callsTo(INSERT_SESSION).length, 0);
});
await t('ranked-run-start: lifecycle cleanup failure never blocks a start', async () => {
  for (const expire of [dbError('boom'), unreachable]) {
    stubDb(...startRoutes({ expire }));
    assert.equal((await call(START, { body: {} })).status, 200);
  }
});
await t('ranked-run-start: a failed profile / count read is ignored exactly as the original ignores it', async () => {
  stubDb(...startRoutes({ profile: [PROFILE, dbError('boom')] }));
  assert.equal((await call(START, { body: {} })).status, 409, 'unreadable profile = no profile -> PROFILE_REQUIRED');
  stubDb(...startRoutes({ profile: [PROFILE, dbError('boom')], session: { run_type: 'qa' } }));
  assert.equal((await call(START, { body: { runType: 'qa' } })).status, 200);
  stubDb(...startRoutes({ count: dbError('boom') }));
  assert.equal((await call(START, { body: {} })).status, 200, 'unreadable count = 0');
});
await t('ranked-run-start: storage errors surface as START_FAILED with the database message', async () => {
  stubDb(...startRoutes({ insert: dbError('user_id is not a session', '23503') }));
  const res = await call(START, { body: {} });
  assert.equal(res.status, 500);
  assert.deepEqual(res.json, { error: 'START_FAILED', detail: 'user_id is not a session' });
  assertCors(res);
  stubDb(...startRoutes({ insert: unreachable }));
  assert.equal((await call(START, { body: {} })).json.error, 'START_FAILED');
});
await t('ranked-run-start: DATABASE_URL unset -> 401 (no session can be resolved), no request is made', async () => {
  stubDb(...startRoutes());
  assert.equal((await call(START, { body: {}, env: {} })).status, 401);
  assert.equal(calls.length, 0);
});

// =====================================================================
// ranked-run-finish
// =====================================================================
const FINISH = '/api/ranked-run-finish';
const SELECT_SESSION = /select row_to_json\(s\) as session from/;
const SUBMIT = /set status = 'submitted'/;
const EXPIRE_ONE = /set status = 'expired'/;
const REJECT = /set status = 'rejected'/;
const INSERT_RUN = /insert into public\.ranked_runs/;
const V4 = /record_ranked_result_v4/;
const V5 = /record_ranked_result_v5/;
const RANK = /get_my_rank_v3/;
const openSession = (o = {}) => ({ run_id: ID.run, user_id: SID, nonce: ID.nonce,
  started_at: new Date(Date.now() - (o.elapsedMs ?? 30000)).toISOString(), expires_at: new Date(Date.now() - (o.elapsedMs ?? 30000) + 300000).toISOString(),
  status: 'started', run_type: 'ranked', ruleset_version: 'secret-2.1-r1', ...o.row });
const finishRoutes = (o = {}) => [sessionFound,
  [SELECT_SESSION, o.select ?? rows('session', 'json', o.session === null ? [] : [openSession(o)])],
  [EXPIRE_ONE, rows('x', 'int4', [])], [SUBMIT, o.submit ?? rows('run_id', 'uuid', [ID.run])],
  [REJECT, o.reject ?? rows('x', 'int4', [])], [INSERT_RUN, o.insertRun ?? rows('x', 'int4', [])],
  [V5, o.v5 ?? rows('record_id', 'uuid', [ID.record])], [V4, o.v4 ?? rows('record_id', 'uuid', [ID.record])],
  [RANK, o.rank ?? rows('rank', 'json', [{ best_score: 321, overall_rank: 4, department_rank: 2, department_id: 10, ranked_grade: 'B+', general_badge: 'bronze' }])]];
// 20 normal + 5 speedy + 2 gold + 1 indeoki = 28 good hits, base 41 points
const run21 = (o = {}) => ({ runId: ID.run, nonce: ID.nonce, score: 60, maxCombo: 12, annyongiHits: 2, indeokiHits: 1, goldHits: 2,
  normalHits: 20, speedyHits: 5, totalHits: 30, dragonCalls: 1, completedCalls: 1, moonBonusHits: 2, flightHits: 3, durationMs: 30000,
  clientVersion: 'classic-2.2.0', inputCount: 50, reactionSampleCount: 10, ultraFastReactionCount: 1, ...o });
// raw 41 + 2*2 + 9 = 54, combo 6, tier1 award 10 -> ascension 2, score 62
const run22 = (o = {}) => ({ ...run21(), flightBasePoints: 9, comboBonus: 6, tier1Hits: 2, tier2Hits: 0, tier1GroundAward: 10, tier2GroundAward: 0,
  ascensionBonus: 2, score: 62, ...o });
const finish = (body, options = {}) => call(FINISH, { body, ...options });

await t('ranked-run-finish: an accepted 2.1 run is recorded with v4 and answered with the caller rank', async () => {
  stubDb(...finishRoutes());
  const res = await finish(run21());
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { accepted: true, runId: ID.run, recordId: ID.record, runType: 'ranked', rulesetVersion: 'secret-2.1-r1',
    rankEligible: true, shadowSuspicious: false, suspicionReasons: [], bestScore: 321, overallRank: 4, departmentRank: 2, rankedGrade: 'B+', generalBadge: 'bronze' });
  assertCors(res);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(callsTo(V5).length, 0);
  assert.deepEqual(callsTo(V4)[0].params, wire([ID.run, SID, 60, 12, 2, 1, 2, 20, 5, 30, 1, 1, 2, 3, 30000, 'classic-2.2.0', 50, 10, 1, false, '{}']));
  assert.deepEqual(callsTo(SELECT_SESSION)[0].params, [ID.run, SID]);
  assert.deepEqual(callsTo(SUBMIT)[0].params.slice(1), [ID.run, SID]);
  assert.deepEqual(callsTo(RANK)[0].params, [SID], 'get_my_rank_v3 receives the session id as a parameter');
  assert.equal(callsTo(REJECT).length + callsTo(INSERT_RUN).length, 0);
});
await t('ranked-run-finish: a 2.2 run is recorded with v5 (chosen by the session ruleset, not by trying v5 first)', async () => {
  stubDb(...finishRoutes({ row: { ruleset_version: 'secret-2.2-r1' } }));
  const res = await finish(run22());
  assert.equal(res.status, 200);
  assert.equal(res.json.rulesetVersion, 'secret-2.2-r1');
  assert.equal(callsTo(V4).length, 0);
  assert.deepEqual(callsTo(V5)[0].params, wire([ID.run, SID, 62, 12, 2, 1, 2, 20, 5, 30, 1, 1, 2, 3, 30000, 'classic-2.2.0', 6, 9, 2, 0, 10, 0, 2, 50, 10, 1, false, '{}']));
});
await t('ranked-run-finish: a failing recorder is FINISH_FAILED; the other version is never tried', async () => {
  stubDb(...finishRoutes({ row: { ruleset_version: 'secret-2.2-r1' }, v5: dbError('ranked session not submitted') }));
  const res = await finish(run22());
  assert.equal(res.status, 500);
  assert.deepEqual(res.json, { error: 'FINISH_FAILED', detail: 'ranked session not submitted' });
  assert.equal(callsTo(V4).length, 0);
  stubDb(...finishRoutes({ v4: unreachable }));
  assert.equal((await finish(run21())).status, 500);
  assert.equal(callsTo(V5).length, 0);
});
await t('ranked-run-finish: a QA run is accepted without a rank lookup', async () => {
  stubDb(...finishRoutes({ row: { run_type: 'qa' } }));
  const res = await finish(run21());
  assert.equal(res.status, 200);
  assert.deepEqual([res.json.rankEligible, res.json.bestScore, res.json.overallRank, res.json.departmentRank, res.json.rankedGrade, res.json.generalBadge],
    [false, null, null, null, null, null]);
  assert.equal(callsTo(RANK).length, 0);
});
await t('ranked-run-finish: a missing or failing rank read falls back to the submitted score', async () => {
  for (const rank of [rows('rank', 'json', []), dbError('boom'), unreachable]) {
    stubDb(...finishRoutes({ rank }));
    const res = await finish(run21());
    assert.equal(res.status, 200);
    assert.deepEqual([res.json.bestScore, res.json.overallRank, res.json.rankedGrade], [60, null, null]);
  }
});
await t('ranked-run-finish: suspicion is recorded but does not reject (shadow mode)', async () => {
  stubDb(...finishRoutes());
  const res = await finish(run21({ inputCount: 400, reactionSampleCount: 10, ultraFastReactionCount: 7 }));
  assert.equal(res.status, 200);
  assert.equal(res.json.shadowSuspicious, true);
  assert.deepEqual(res.json.suspicionReasons, ['HIGH_INPUT_RATE', 'ULTRA_FAST_REACTION_RATIO']);
  assert.deepEqual(callsTo(V4)[0].params.slice(-2), wire([true, '{"HIGH_INPUT_RATE","ULTRA_FAST_REACTION_RATIO"}']));
});
await t('ranked-run-finish: CORS preflight, wrong methods, sessions', async () => {
  stubDb(...finishRoutes());
  const pre = await call(FINISH, { method: 'OPTIONS', session: null });
  assert.deepEqual([pre.status, pre.text], [200, 'ok']);
  const get = await call(FINISH, { method: 'GET' });
  assert.deepEqual([get.status, get.text], [405, 'Method Not Allowed']);
  assert.equal(calls.length, 0);
  const anon = await finish(run21(), { session: null });
  assert.equal(anon.status, 401);
  assert.deepEqual(anon.json, { error: 'UNAUTHENTICATED' });
  stubDb(sessionMissing, ...finishRoutes().slice(1));
  assert.equal((await finish(run21())).status, 401);
  assert.equal(callsTo(SELECT_SESSION).length, 0);
});
await t('ranked-run-finish: an unparseable body is FINISH_FAILED (500), after the session check', async () => {
  stubDb(...finishRoutes());
  for (const body of ['not json', '', '{"runId":']) {
    const res = await finish(body);
    assert.equal(res.status, 500);
    assert.equal(res.json.error, 'FINISH_FAILED');
  }
  assert.equal((await finish('not json', { session: null })).status, 401);
  assert.equal(callsTo(SELECT_SESSION).length, 0);
});
await t('ranked-run-finish: unknown run -> 404; a malformed run id fails the uuid cast -> 500', async () => {
  stubDb(...finishRoutes({ session: null }));
  const res = await finish(run21());
  assert.equal(res.status, 404);
  assert.deepEqual(res.json, { error: 'RUN_NOT_FOUND' });
  assert.equal(callsTo(SUBMIT).length, 0);
  stubDb(...finishRoutes({ select: dbError('invalid input syntax for type uuid: "abc"', '22P02') }));
  const bad = await finish(run21({ runId: 'abc' }));
  assert.equal(bad.status, 500);
  assert.deepEqual(bad.json, { error: 'FINISH_FAILED', detail: 'invalid input syntax for type uuid: "abc"' });
});
for (const status of ['submitted', 'accepted', 'rejected', 'expired', 'abandoned']) {
  await t(`ranked-run-finish: a session that is already ${status} -> 409 with its status`, async () => {
    stubDb(...finishRoutes({ row: { status } }));
    const res = await finish(run21());
    assert.equal(res.status, 409);
    assert.deepEqual(res.json, { error: 'RUN_ALREADY_PROCESSED', status });
    assert.equal(callsTo(SUBMIT).length, 0);
  });
}
await t('ranked-run-finish: an overdue run is marked expired and answered 410', async () => {
  for (const o of [{ elapsedMs: 301000 }, { elapsedMs: 361000, row: { expires_at: new Date(Date.now() + 600000).toISOString() } }]) {
    stubDb(...finishRoutes(o));
    const res = await finish(run21());
    assert.equal(res.status, 410);
    assert.deepEqual(res.json, { error: 'RUN_EXPIRED' });
    assert.equal(callsTo(EXPIRE_ONE).length, 1);
    assert.deepEqual(callsTo(EXPIRE_ONE)[0].params.slice(2), [ID.run, SID]);
    assert.equal(callsTo(SUBMIT).length, 0);
  }
});
await t('ranked-run-finish: losing the started -> submitted race is 409', async () => {
  stubDb(...finishRoutes({ submit: rows('run_id', 'uuid', []) }));
  const res = await finish(run21());
  assert.equal(res.status, 409);
  assert.deepEqual(res.json, { error: 'RUN_ALREADY_PROCESSED' });
  assert.equal(callsTo(V4).length, 0);
});
for (const [reason, status, ruleset, body] of [
  ['NONCE_MISMATCH', 403, '2.1', run21({ nonce: ID.key })],
  ['RUN_TYPE_MISMATCH', 422, '2.1', run21({ runType: 'qa' })],
  ['RULESET_MISMATCH', 422, '2.1', run21({ rulesetVersion: 'secret-2.2-r1' })],
  ['INVALID_NUMERIC', 422, '2.1', run21({ score: -1 })],
  ['INVALID_NUMERIC', 422, '2.1', run21({ maxCombo: 'many' })],
  ['INVALID_NUMERIC', 422, '2.1', run21({ durationMs: undefined })],
  ['DURATION_OUT_OF_RANGE', 422, '2.1', run21({ durationMs: 6999 })],
  ['DURATION_OUT_OF_RANGE', 422, '2.1', run21({ durationMs: 65001 })],
  ['CLOCK_MISMATCH', 422, '2.1', run21({ durationMs: 50000 })],
  ['TOO_MANY_HITS', 422, '2.1', run21({ totalHits: 181 })],
  ['DRAGON_CALLS_INVALID', 422, '2.1', run21({ dragonCalls: 3 })],
  ['COMPLETED_CALLS_INVALID', 422, '2.1', run21({ completedCalls: 2 })],
  ['TELEMETRY_INVALID', 422, '2.1', run21({ ultraFastReactionCount: 11 })],
  ['HIT_COUNTS_INVALID', 422, '2.1', run21({ totalHits: 31 })],
  ['HIT_COUNTS_INVALID', 422, '2.1', run21({ normalHits: undefined, speedyHits: undefined, annyongiHits: 40 })],
  ['COMBO_IMPOSSIBLE', 422, '2.1', run21({ maxCombo: 29 })],
  ['PHASE_HITS_INVALID', 422, '2.1', run21({ moonBonusHits: 29 })],
  ['PHASE_WITHOUT_CALL', 422, '2.1', run21({ dragonCalls: 0, completedCalls: 0 })],
  ['SCORE_BELOW_THEORETICAL_MIN', 422, '2.1', run21({ score: 47 })],
  ['SCORE_ABOVE_THEORETICAL_MAX', 422, '2.1', run21({ score: 121 })],
  ['SCORE_ABOVE_CAP', 422, '2.1', run21({ normalHits: undefined, speedyHits: undefined, flightHits: undefined, moonBonusHits: 0, score: 1801 })],
  ['SCORE_HIT_MISMATCH', 422, '2.1', run21({ normalHits: undefined, speedyHits: undefined, flightHits: undefined, moonBonusHits: 0, score: 421 })],
  ['LEDGER_REQUIRED', 422, '2.2', run21()],
  ['LEDGER_REQUIRED', 422, '2.2', run22({ comboBonus: undefined })],
  ['FLIGHT_LEDGER_INVALID', 422, '2.2', run22({ flightBasePoints: 16 })],
  ['FLIGHT_LEDGER_INVALID', 422, '2.2', run22({ flightHits: 0, flightBasePoints: 1 })],
  ['COMBO_LEDGER_INVALID', 422, '2.2', run22({ comboBonus: 55 })],
  ['ASCENSION_HITS_INVALID', 422, '2.2', run22({ tier1Hits: 24 })],
  ['TIER1_BEFORE_ASCENSION', 422, '2.2', run22({ completedCalls: 0 })],
  ['TIER2_BEFORE_ASCENSION', 422, '2.2', run22({ tier2Hits: 1, tier2GroundAward: 1 })],
  ['TIER1_LEDGER_INVALID', 422, '2.2', run22({ tier1GroundAward: 21 })],
  ['TIER2_LEDGER_INVALID', 422, '2.2', run22({ dragonCalls: 2, completedCalls: 2, tier2Hits: 0, tier2GroundAward: 3 })],
  ['ASCENSION_AWARD_INVALID', 422, '2.2', run22({ tier1Hits: 5, tier1GroundAward: 48 })],
  ['ASCENSION_BONUS_INVALID', 422, '2.2', run22({ ascensionBonus: 3 })],
  ['SCORE_LEDGER_MISMATCH', 422, '2.2', run22({ score: 63 })],
]) {
  await t(`ranked-run-finish: ${reason} -> ${status} RUN_REJECTED (${ruleset}: ${JSON.stringify(body).length} bytes)`, async () => {
    stubDb(...finishRoutes({ row: { ruleset_version: ruleset === '2.2' ? 'secret-2.2-r1' : 'secret-2.1-r1' } }));
    const res = await finish(body);
    assert.deepEqual(res.json, { error: 'RUN_REJECTED', reason });
    assert.equal(res.status, status);
    assert.equal(callsTo(REJECT).length, 1, 'the session is closed as rejected');
    assert.equal(callsTo(INSERT_RUN).length, 1, 'the rejected run is stored');
    assert.ok(callsTo(INSERT_RUN)[0].params.includes(reason));
    assert.equal(callsTo(V4).length + callsTo(V5).length + callsTo(RANK).length, 0);
  });
}
await t('ranked-run-finish: a rejected run is stored with clamped, non-negative numbers', async () => {
  stubDb(...finishRoutes());
  const res = await finish(run21({ score: -5, dragonCalls: 9, completedCalls: 9, ultraFastReactionCount: 99, comboBonus: -3 }));
  assert.equal(res.json.reason, 'INVALID_NUMERIC');
  const p = callsTo(INSERT_RUN)[0].params;
  assert.deepEqual(p.slice(0, 3), wire([ID.run, SID, 0]), 'run, session id, score clamped to 0');
  assert.deepEqual([p[10], p[11]], wire([2, 2]), 'dragon / completed calls clamped to 2');
  assert.equal(p[21], '10', 'ultra-fast reactions clamped to the sample count');
  assert.equal(p[22], '0', 'missing ledger values are stored as 0');
});
await t('ranked-run-finish: a failing reject write does not change the answer', async () => {
  stubDb(...finishRoutes({ reject: dbError('boom'), insertRun: unreachable }));
  const res = await finish(run21({ nonce: ID.key }));
  assert.equal(res.status, 403);
  assert.deepEqual(res.json, { error: 'RUN_REJECTED', reason: 'NONCE_MISMATCH' });
});

// =====================================================================
// world-duck-observe
// =====================================================================
const DUCK = '/api/world-duck-observe';
const DUCK_RPC = /world_inkyung_duck_observe_v1/;
const duckData = { status: 'SUCCESS', duckId: 'inkyung_duck_white_01', companion: { state: 'SIGHTED', observationCount: 1, requiredObservationCount: 3 } };
const duckRoutes = (reply = rows('result', 'jsonb', [duckData])) => [sessionFound, [DUCK_RPC, reply]];

await t('duck-observe: an existing session records the observation; provenance is derived server-side', async () => {
  stubDb(...duckRoutes());
  const res = await call(DUCK, { body: { duckId: 'inkyung_duck_white_01', userId: ID.key, resultRef: 'forged', idempotencyKey: 'forged' } });
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, duckData);
  assertCors(res);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('content-type'), 'application/json');
  const [rpc] = callsTo(DUCK_RPC);
  assert.equal(rpc.query, 'select public.world_inkyung_duck_observe_v1($1::uuid, $2::text, $3::text, $4::text) as result');
  assert.deepEqual(rpc.params, [SID, 'inkyung_duck_white_01', `duck-observation:${SID}:inkyung_duck_white_01`, `duck-observe:${SID}:inkyung_duck_white_01`]);
  assert.deepEqual(leaks(['forged', ID.key]), []);
});
for (const duckId of ['inkyung_duck_white_01', 'inkyung_duck_white_02', 'inkyung_duck_white_03', 'inkyung_duck_mallard_01']) {
  await t(`duck-observe: ${duckId} is observable`, async () => {
    stubDb(...duckRoutes());
    assert.equal((await call(DUCK, { body: { duckId } })).status, 200);
    assert.equal(callsTo(DUCK_RPC)[0].params[1], duckId);
  });
}
for (const body of [{ duckId: 'inkyung_duck_mechanical_01' }, { duckId: 'not_a_duck' }, { duckId: '' }, {}, { duckId: null }, { duckId: 7 },
  { duckId: 'INKYUNG_DUCK_WHITE_01' }, 'not json', '', 'null']) {
  await t(`duck-observe: ${JSON.stringify(body)} never reaches the RPC -> 400 INVALID_DUCK_ID`, async () => {
    stubDb(...duckRoutes());
    const res = await call(DUCK, { body });
    assert.equal(res.status, 400);
    assert.deepEqual(res.json, { error: 'INVALID_DUCK_ID' });
    assert.equal(callsTo(DUCK_RPC).length, 0);
  });
}
await t('duck-observe: no session -> 401, checked before the duck id; there is no anonymous-account 403 any more', async () => {
  stubDb(...duckRoutes());
  const res = await call(DUCK, { body: { duckId: 'not_a_duck' }, session: null });
  assert.equal(res.status, 401);
  assert.deepEqual(res.json, { error: 'UNAUTHENTICATED' });
  stubDb(sessionMissing, [DUCK_RPC, rows('result', 'jsonb', [duckData])]);
  assert.equal((await call(DUCK, { body: { duckId: 'inkyung_duck_white_01' } })).status, 401);
  assert.equal(callsTo(DUCK_RPC).length, 0);
  stubDb([SESSION, unreachable], [DUCK_RPC, rows('result', 'jsonb', [duckData])]);
  assert.equal((await call(DUCK, { body: { duckId: 'inkyung_duck_white_01' } })).status, 401, 'failed lookup = no session');
});
for (const [name, reply, status, error] of [
  ['SQLSTATE 22023 (the session row vanished after the lookup)', dbError('ACCOUNT_UNAVAILABLE', '22023'), 403, 'ACCOUNT_UNAVAILABLE'],
  ['SQLSTATE P0001 (subject not observable)', dbError('INKYUNG_DUCK_NOT_OBSERVABLE', 'P0001'), 409, 'OBSERVATION_REJECTED'],
  ['any other database error', dbError('boom', '23505'), 500, 'OBSERVATION_FAILED'],
  ['database unreachable', unreachable, 500, 'OBSERVATION_FAILED'],
  ['database timeout', timedOut, 500, 'OBSERVATION_FAILED'],
]) {
  await t(`duck-observe: ${name} -> ${status} ${error}`, async () => {
    stubDb(...duckRoutes(reply));
    const res = await call(DUCK, { body: { duckId: 'inkyung_duck_white_01' } });
    assert.equal(res.status, status);
    assert.deepEqual(res.json, { error });
    assertCors(res);
  });
}
await t('duck-observe: an empty RPC result falls back to a plain success', async () => {
  stubDb(...duckRoutes(rows('result', 'jsonb', [null])));
  const res = await call(DUCK, { body: { duckId: 'inkyung_duck_white_02' } });
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { status: 'SUCCESS', duckId: 'inkyung_duck_white_02' });
});
await t('duck-observe: CORS preflight and wrong methods', async () => {
  stubDb(...duckRoutes());
  const pre = await call(DUCK, { method: 'OPTIONS', session: null });
  assert.deepEqual([pre.status, pre.text], [200, 'ok']);
  assertCors(pre);
  for (const method of ['GET', 'PUT', 'DELETE']) {
    const res = await call(DUCK, { method });
    assert.equal(res.status, 405);
    assert.deepEqual(res.json, { error: 'METHOD_NOT_ALLOWED' });
  }
  assert.equal(calls.length, 0);
});

// =====================================================================
// verify-inha-mail: 501 NOT_IMPLEMENTED (identity verification is not ported)
// Replaces supabase/tests/edge/verify-inha-mail.test.mjs: every case that used to
// reach a verdict (200 / 400 / 401 / 403 / 409 / 500) is now the same 501, and no
// case can reach the database.
// =====================================================================
const MAIL = '/api/verify-inha-mail';
for (const [name, options] of [
  ['both tokens present (was: 200 verified)', { headers: { authorization: `Bearer ${'p'.repeat(40)}` }, body: { school_access_token: 's'.repeat(40) } }],
  ['a guest session and a school token', { body: { school_access_token: 's'.repeat(40) } }],
  ['no credentials at all (was: 400 MISSING_TOKENS)', { session: null, body: {} }],
  ['a missing school token (was: 400 MISSING_TOKENS)', { headers: { authorization: `Bearer ${'p'.repeat(40)}` }, body: {} }],
  ['an oversized school token (was: 400 MISSING_TOKENS)', { body: { school_access_token: 's'.repeat(9000) } }],
  ['an unparseable body (was: 400 BAD_REQUEST)', { body: 'not json' }],
  ['an empty body', { body: '' }],
  ['the same token twice (was: 403 PRIMARY_ACCOUNT_REQUIRED)', { headers: { authorization: 'Bearer same-token-same-token-same' }, body: { school_access_token: 'same-token-same-token-same' } }],
  ['a claimed inha.edu address in the body', { body: { school_access_token: 'x'.repeat(40), email: 'duck@inha.edu', verified: true } }],
]) {
  await t(`verify-inha-mail: ${name} -> 501 NOT_IMPLEMENTED, nothing is verified, nothing is written`, async () => {
    stubDb();
    const res = await call(MAIL, options);
    assert.equal(res.status, 501);
    assert.deepEqual(res.json, { error: 'NOT_IMPLEMENTED' });
    assert.ok(!('verified' in res.json));
    assertCors(res);
    assert.equal(res.headers.get('content-type'), 'application/json');
    assert.equal(calls.length, 0);
  });
}
await t('verify-inha-mail: 501 even with no database configured', async () => {
  stubDb();
  assert.equal((await call(MAIL, { body: {}, env: {} })).status, 501);
});
await t('verify-inha-mail: CORS preflight and wrong methods keep the original answers', async () => {
  stubDb();
  const pre = await call(MAIL, { method: 'OPTIONS', session: null });
  assert.deepEqual([pre.status, pre.text], [200, '']);
  assertCors(pre);
  for (const method of ['GET', 'PUT', 'DELETE']) {
    const res = await call(MAIL, { method });
    assert.equal(res.status, 405);
    assert.deepEqual(res.json, { error: 'METHOD_NOT_ALLOWED' });
  }
  assert.equal(calls.length, 0);
});

// =====================================================================
// fishing-position: browser-reported position feed (no original counterpart)
// =====================================================================
const POS = '/api/fishing-position';
const POS_RPC = /world_fishing_observe_position_v1/;
const PH = { ...HOST, 'content-type': 'application/json' };
const report = (o = {}) => ({ revision: 3, x: 1.5, y: 0, z: -2.25, space: 'CAMPUS', mode: 'ON_FOOT', ...o });
const posOk = (result = { status: 'OBSERVED', revision: 3 }) => [POS_RPC, rows('result', 'jsonb', [result])];
// The feed rate-limits per session, in memory: every test uses its own session id.
const fresh = () => randomUUID();
const position = (body, options = {}) => call(POS, { headers: PH, body, session: options.session ?? fresh(), ...options });
const POS_SQL = 'select public.world_fishing_observe_position_v1(\n      $1::uuid, $2::uuid, $3::bigint,\n      $4::float8, $5::float8, $6::float8,\n      $7::text, $8::text, $9::timestamptz) as result';

await t('fishing-position: a valid report is relayed with the session id as account and presence session, stamped with the Worker time', async () => {
  stubDb(sessionFound, posOk());
  const session = fresh();
  const before = Date.now();
  const res = await position(report(), { session });
  const after = Date.now();
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { status: 'OBSERVED', revision: 3 });
  assertCors(res);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('content-type'), 'application/json; charset=utf-8');
  const [rpc] = callsTo(POS_RPC);
  assert.equal(rpc.query, POS_SQL);
  assert.deepEqual(rpc.params.slice(0, 8), [session, session, '3', '1.5', '0', '-2.25', 'CAMPUS', 'ON_FOOT']);
  const stamped = Date.parse(rpc.params[8]);
  assert.ok(stamped >= before && stamped <= after, 'observed_at is the time the Worker received the request');
  assert.ok(rpc.init.signal instanceof AbortSignal);
});
for (const [status, revision] of [['ALREADY_PROCESSED', 3], ['STALE', 41]]) {
  await t(`fishing-position: RPC status ${status} is passed through as 200 with the stored revision`, async () => {
    stubDb(sessionFound, posOk({ status, revision }));
    const res = await position(report());
    assert.equal(res.status, 200);
    assert.deepEqual(res.json, { status, revision });
  });
}
await t('fishing-position: only status and revision are returned', async () => {
  stubDb(sessionFound, posOk({ status: 'OBSERVED', revision: 3, x: 1, internal: 'x' }));
  assert.deepEqual((await position(report())).json, { status: 'OBSERVED', revision: 3 });
});
for (const [name, reply, status, error] of [
  ['FISHING_POSITION_INVALID (bad value, or an observed_at ahead of the DB clock)', dbError('FISHING_POSITION_INVALID', '22023'), 400, 'FISHING_POSITION_INVALID'],
  ['FISHING_POSITION_CONFLICT (same revision, different payload)', dbError('FISHING_POSITION_CONFLICT', '23505'), 409, 'FISHING_POSITION_CONFLICT'],
  ['FISHING_POSITION_STALE (the request took 5 s or more to reach the DB)', dbError('FISHING_POSITION_STALE', '22023'), 503, 'FISHING_UNAVAILABLE'],
  ['ACCOUNT_UNAVAILABLE (the session vanished after the lookup)', dbError('ACCOUNT_UNAVAILABLE', '22023'), 503, 'FISHING_UNAVAILABLE'],
  ['a permission error', dbError('permission denied for function world_fishing_observe_position_v1', '42501'), 503, 'FISHING_UNAVAILABLE'],
  ['database unreachable', unreachable, 503, 'FISHING_UNAVAILABLE'],
  ['database timeout', timedOut, 503, 'FISHING_UNAVAILABLE'],
  ['unreadable reply', unreadable, 503, 'FISHING_UNAVAILABLE'],
  ['no row', rows('result', 'jsonb', []), 503, 'FISHING_UNAVAILABLE'],
  ['an unknown status', rows('result', 'jsonb', [{ status: 'MAYBE', revision: 3 }]), 503, 'FISHING_UNAVAILABLE'],
  ['a non-integer revision', rows('result', 'jsonb', [{ status: 'OBSERVED', revision: '3' }]), 503, 'FISHING_UNAVAILABLE'],
]) {
  await t(`fishing-position: ${name} -> ${status} ${error}`, async () => {
    stubDb(sessionFound, [POS_RPC, reply]);
    const res = await position(report());
    assert.equal(res.status, status);
    assert.deepEqual(res.json, { error });
    assertCors(res);
  });
}
await t('fishing-position: a mapped code only counts when the database raised it', async () => {
  stubDb(sessionFound, [POS_RPC, () => { throw new TypeError('FISHING_POSITION_INVALID'); }]);
  assert.equal((await position(report())).status, 503);
});
await t('fishing-position: WORLD_FISHING_API_ENABLED unset -> 404 for every request, nothing is touched', async () => {
  stubDb(sessionFound, posOk());
  for (const env of [{ DATABASE_URL: ENV.DATABASE_URL }, { ...ENV, WORLD_FISHING_API_ENABLED: '0' }]) {
    for (const init of [{ method: 'OPTIONS' }, { method: 'GET' }, { method: 'POST', headers: PH, body: report() }, { method: 'POST', body: '{' }]) {
      const res = await call(POS, { ...init, env });
      assert.equal(res.status, 404);
      assert.equal(res.text, '');
    }
  }
  assert.equal(calls.length, 0);
});
await t('fishing-position: CORS preflight answers like the ranked / duck handlers', async () => {
  stubDb(sessionFound, posOk());
  const pre = await call(POS, { method: 'OPTIONS', session: null });
  assert.deepEqual([pre.status, pre.text], [200, 'ok']);
  assertCors(pre);
  assert.equal(calls.length, 0);
});
for (const method of ['GET', 'PUT', 'DELETE', 'PATCH']) {
  await t(`fishing-position: ${method} is 405 with Allow: POST`, async () => {
    stubDb(sessionFound, posOk());
    const res = await call(POS, { method, headers: PH });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('allow'), 'POST');
    assertCors(res);
    assert.equal(calls.length, 0);
  });
}
for (const type of [undefined, 'text/plain', 'application/jsonx', 'application/x-www-form-urlencoded']) {
  await t(`fishing-position: content-type ${type} is 415`, async () => {
    stubDb(sessionFound, posOk());
    const headers = { ...HOST };
    if (type) headers['content-type'] = type;
    assert.equal((await call(POS, { headers, body: JSON.stringify(report()), session: fresh() })).status, 415);
    assert.equal(calls.length, 0);
  });
}
await t('fishing-position: application/json is matched case-insensitively and with parameters', async () => {
  for (const type of ['application/json; charset=utf-8', 'APPLICATION/JSON', ' application/json ']) {
    stubDb(sessionFound, posOk());
    assert.equal((await call(POS, { headers: { ...HOST, 'content-type': type }, body: report(), session: fresh() })).status, 200, type);
  }
});
for (const headers of [{ origin: 'https://evil.example', host: 'inhagame.app' }, { origin: 'not a url', host: 'inhagame.app' },
  { origin: 'https://inhagame.app' }, { origin: 'https://inhagame.app:8443', host: 'inhagame.app' }]) {
  await t(`fishing-position: cross-site ${JSON.stringify(headers)} is 403`, async () => {
    stubDb(sessionFound, posOk());
    assert.equal((await position(report(), { headers: { ...headers, 'content-type': 'application/json' } })).status, 403);
    assert.equal(calls.length, 0);
  });
}
await t('fishing-position: same-origin and Origin-less requests pass', async () => {
  for (const headers of [{ ...PH, origin: 'https://inhagame.app' }, PH]) {
    stubDb(sessionFound, posOk());
    assert.equal((await position(report(), { headers })).status, 200);
  }
});
await t('fishing-position: the body limit is 1024 bytes', async () => {
  stubDb(sessionFound, posOk());
  const base = JSON.stringify(report());
  const at = base + ' '.repeat(1024 - base.length);
  assert.equal((await position(at)).status, 200, 'exactly 1024 bytes');
  assert.equal((await position(at + ' ')).status, 413);
  assert.equal((await position('{'.repeat(2000))).status, 413, '413 before 400');
  assert.equal((await position('가'.repeat(342))).status, 413, '1026 bytes in 342 characters');
});
for (const [name, body] of [
  ['non-JSON body', '{"revision":'], ['empty body', ''], ['JSON null', 'null'], ['JSON array', '[]'], ['JSON number', '7'],
  ...['revision', 'x', 'y', 'z', 'space', 'mode'].map((k) => [`missing ${k}`, report({ [k]: undefined })]),
  ['a client observed_at is refused, not ignored', report({ observed_at: new Date().toISOString() })],
  ['a client observedAt is refused', report({ observedAt: Date.now() })],
  ['a client session id is refused', report({ sessionId: randomUUID() })],
  ['a client user id is refused', report({ userId: randomUUID() })],
  ['revision 0', report({ revision: 0 })], ['negative revision', report({ revision: -1 })],
  ['fractional revision', report({ revision: 1.5 })], ['revision as a string', report({ revision: '3' })],
  ['revision above 2^53', report({ revision: 2 ** 53 })], ['null revision', report({ revision: null })],
  ['x above 10000', report({ x: 10000.5 })], ['y below -10000', report({ y: -10001 })], ['z as a string', report({ z: '1' })],
  ['x null', report({ x: null })], ['y boolean', report({ y: true })], ['z as an array', report({ z: [1] })],
  ['huge exponent', '{"revision":3,"x":1e400,"y":0,"z":0,"space":"CAMPUS","mode":"ON_FOOT"}'],
  ['lower-case space', report({ space: 'campus' })], ['unknown space', report({ space: 'ROOM' })],
  ['unknown mode', report({ mode: 'FLYING' })], ['mode null', report({ mode: null })],
]) {
  await t(`fishing-position: ${name} -> 400 INVALID_REQUEST before the session is looked up`, async () => {
    stubDb(sessionFound, posOk());
    const res = await position(body);
    assert.equal(res.status, 400);
    assert.deepEqual(res.json, { error: 'INVALID_REQUEST' });
    assert.equal(calls.length, 0);
  });
}
await t('fishing-position: coordinate bounds ±10000 and both eligibility values are accepted', async () => {
  for (const o of [{ x: 10000, y: -10000, z: 0 }, { x: -10000, y: 10000, z: 10000 }, { space: 'OTHER', mode: 'INELIGIBLE' },
    { space: 'CAMPUS', mode: 'INELIGIBLE' }, { revision: Number.MAX_SAFE_INTEGER }]) {
    stubDb(sessionFound, posOk());
    assert.equal((await position(report(o))).status, 200, JSON.stringify(o));
  }
});
await t('fishing-position: no session -> 401 AUTH_REQUIRED; a failed lookup -> 503 AUTH_UNAVAILABLE', async () => {
  stubDb(sessionMissing, posOk());
  assert.deepEqual((await position(report())).json, { error: 'AUTH_REQUIRED' });
  stubDb(sessionFound, posOk());
  const missing = await call(POS, { headers: PH, body: report(), session: null });
  assert.deepEqual([missing.status, missing.json], [401, { error: 'AUTH_REQUIRED' }]);
  assert.equal((await call(POS, { headers: { ...PH, 'x-session-id': 'guest' }, body: report(), session: null })).status, 401);
  for (const reply of [unreachable, dbError('boom', 'XX000')]) {
    stubDb([SESSION, reply], posOk());
    assert.deepEqual((await position(report())).json, { error: 'AUTH_UNAVAILABLE' });
  }
  stubDb(sessionFound, posOk());
  assert.equal((await position(report(), { env: { WORLD_FISHING_API_ENABLED: '1' } })).status, 503, 'DATABASE_URL unset');
  assert.equal(callsTo(POS_RPC).length, 0);
});
await t('fishing-position guard order: flag (404) -> method (405) -> content-type (415) -> Origin (403) -> size (413) -> JSON / shape (400) -> session (401) -> rate (429)', async () => {
  stubDb(sessionMissing, posOk());
  const evil = { origin: 'https://evil.example', host: 'inhagame.app' };
  const session = fresh();
  assert.equal((await call(POS, { method: 'GET', headers: { ...evil, 'content-type': 'text/plain' }, session, env: { DATABASE_URL: 'x' } })).status, 404);
  assert.equal((await call(POS, { method: 'GET', headers: { ...evil, 'content-type': 'text/plain' }, session })).status, 405);
  assert.equal((await call(POS, { headers: { ...evil, 'content-type': 'text/plain' }, body: 'x'.repeat(2000), session })).status, 415);
  assert.equal((await call(POS, { headers: { ...evil, 'content-type': 'application/json' }, body: 'x'.repeat(2000), session })).status, 403);
  assert.equal((await call(POS, { headers: PH, body: 'x'.repeat(2000), session })).status, 413);
  assert.equal((await call(POS, { headers: PH, body: report({ x: 'far' }), session })).status, 400);
  assert.equal((await call(POS, { headers: PH, body: report(), session })).status, 401);
  assert.equal(callsTo(POS_RPC).length, 0);
});
await t('fishing-position: at most one request per second per session; others are not affected', async () => {
  stubDb(sessionFound, posOk());
  const a = fresh(), b = fresh();
  assert.equal((await position(report(), { session: a })).status, 200);
  const limited = await position(report({ revision: 4 }), { session: a });
  assert.deepEqual([limited.status, limited.json], [429, { error: 'RATE_LIMITED' }]);
  assertCors(limited);
  assert.equal((await position(report(), { session: b })).status, 200, 'another session has its own budget');
  assert.equal(callsTo(POS_RPC).length, 2, 'a limited request never reaches the RPC');
  await new Promise((r) => setTimeout(r, 1050));
  assert.equal((await position(report({ revision: 5 }), { session: a })).status, 200, 'the window has passed');
});
await t('fishing-position: requests refused before the rate check do not use up the budget', async () => {
  stubDb(sessionFound, posOk());
  const a = fresh();
  assert.equal((await position(report({ x: 'far' }), { session: a })).status, 400);
  assert.equal((await position(report(), { session: a, headers: { ...PH, origin: 'https://evil.example' } })).status, 403);
  assert.equal((await position(report(), { session: a })).status, 200);
  stubDb(sessionMissing, posOk());
  const b = fresh();
  assert.equal((await position(report(), { session: b })).status, 401);
  stubDb(sessionFound, posOk());
  assert.equal((await position(report(), { session: b })).status, 200, 'an unknown-session request did not record a slot');
});
await t('fishing-position: the player fishing API still cannot publish or carry a position (original F3 test)', async () => {
  stubDb(sessionFound, fishOk(), posOk());
  const responses = [await fish({ op: 'observe_position' })];
  for (const field of ['position', 'x', 'y', 'z', 'sessionId', 'revision', 'observedAt', 'mode', 'space']) {
    responses.push(await fish(startBody({ [field]: 0 })));
  }
  for (const res of responses) assert.deepEqual([res.status, res.json], [400, { error: 'INVALID_REQUEST' }]);
  assert.equal(calls.length, 0);
});

// =====================================================================
// client/fishing-position-reporter.js (reference module, not wired)
// =====================================================================
const memoryStorage = () => {
  const data = new Map();
  return { getItem: (k) => (data.has(k) ? data.get(k) : null), setItem: (k, v) => data.set(k, String(v)), data };
};
function reporterHarness(o = {}) {
  const sent = [];
  const timers = [];
  const warnings = [];
  const replies = [...(o.replies ?? [])];
  const reporter = createPositionReporter({
    getSessionId: () => o.sessionId ?? SID,
    getPose: o.getPose ?? (() => ({ x: 10, y: 0.5, z: -3 })),
    getState: o.getState ?? (() => ({ indoor: false, mounted: false, seated: false, combat: false, airborne: false, disconnected: false })),
    fetch: async (url, init) => {
      sent.push({ url, init, body: JSON.parse(init.body) });
      const next = replies.shift() ?? { status: 200, json: { status: 'OBSERVED', revision: 0 } };
      if (next instanceof Error) throw next;
      if (next.wait) await next.wait;
      return new Response(next.json === undefined ? null : JSON.stringify(next.json), { status: next.status });
    },
    storage: o.storage ?? memoryStorage(),
    setInterval: (fn, ms) => { timers.push({ fn, ms, cleared: false }); return timers.length - 1; },
    clearInterval: (id) => { timers[id].cleared = true; },
    logger: { warn: (m) => warnings.push(m) },
  });
  return { reporter, sent, timers, warnings };
}
const settle = () => new Promise((r) => setTimeout(r, 0));

await t('reporter: only outdoor walking is CAMPUS / ON_FOOT; every other or unknown state is OTHER / INELIGIBLE', async () => {
  const walking = { indoor: false, mounted: false, seated: false, combat: false, airborne: false, disconnected: false };
  assert.deepEqual(classifyPositionState(walking), { space: 'CAMPUS', mode: 'ON_FOOT' });
  for (const key of Object.keys(walking)) {
    assert.deepEqual(classifyPositionState({ ...walking, [key]: true }), { space: 'OTHER', mode: 'INELIGIBLE' }, key);
    const partial = { ...walking };
    delete partial[key];
    assert.deepEqual(classifyPositionState(partial), { space: 'OTHER', mode: 'INELIGIBLE' }, `missing ${key} fails closed`);
  }
  assert.deepEqual(classifyPositionState(undefined), { space: 'OTHER', mode: 'INELIGIBLE' });
});
await t('reporter: start sends at once, then every 2 s, to the feed with the session header and no client clock', async () => {
  const { reporter, sent, timers } = reporterHarness();
  reporter.start();
  await settle();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].url, '/api/fishing-position');
  assert.equal(sent[0].init.method, 'POST');
  assert.deepEqual(sent[0].init.headers, { 'Content-Type': 'application/json', 'X-Session-Id': SID });
  assert.deepEqual(sent[0].body, { revision: 1, x: 10, y: 0.5, z: -3, space: 'CAMPUS', mode: 'ON_FOOT' });
  assert.deepEqual(timers.map((x) => x.ms), [2000]);
  await timers[0].fn();
  assert.deepEqual(sent.map((x) => x.body.revision), [1, 2]);
  reporter.start();
  assert.equal(timers.length, 1, 'start is idempotent');
  reporter.stop();
  assert.equal(timers[0].cleared, true);
  assert.equal(await reporter.tick(), 'skipped', 'nothing is sent after stop');
  assert.equal(sent.length, 2);
});
await t('reporter: the revision survives a reload through sessionStorage and is per session', async () => {
  const storage = memoryStorage();
  const first = reporterHarness({ storage });
  first.reporter.start(); await settle(); await first.timers[0].fn(); first.reporter.stop();
  const reloaded = reporterHarness({ storage });
  reloaded.reporter.start(); await settle();
  assert.equal(reloaded.sent[0].body.revision, 3);
  const other = reporterHarness({ storage, sessionId: ID.key });
  other.reporter.start(); await settle();
  assert.equal(other.sent[0].body.revision, 1);
  const counter = createRevisionCounter({ storage, sessionId: SID });
  assert.equal(counter.current(), 3);
  counter.advanceTo(2);
  assert.equal(counter.current(), 3, 'never moves backwards');
});
await t('reporter: a STALE answer moves the counter past the stored revision', async () => {
  const { reporter, sent, timers } = reporterHarness({ replies: [{ status: 200, json: { status: 'STALE', revision: 57 } }] });
  reporter.start(); await settle();
  await timers[0].fn();
  assert.deepEqual(sent.map((x) => x.body.revision), [1, 58]);
});
await t('reporter: 429, 409, other errors and network failures keep it running with a fresh revision', async () => {
  const { reporter, sent, timers } = reporterHarness({ replies: [{ status: 429, json: { error: 'RATE_LIMITED' } },
    { status: 409, json: { error: 'FISHING_POSITION_CONFLICT' } }, { status: 503, json: { error: 'FISHING_UNAVAILABLE' } }, new TypeError('offline')] });
  reporter.start(); await settle();
  for (let i = 0; i < 4; i++) await timers[0].fn();
  assert.equal(reporter.isRunning(), true);
  assert.deepEqual(sent.map((x) => x.body.revision), [1, 2, 3, 4, 5]);
});
await t('reporter: 401 stops it and leaves a console warning', async () => {
  const { reporter, sent, timers, warnings } = reporterHarness({ replies: [{ status: 401, json: { error: 'AUTH_REQUIRED' } }] });
  reporter.start(); await settle();
  assert.equal(reporter.isRunning(), false);
  assert.equal(timers[0].cleared, true);
  assert.equal(warnings.length, 1);
  await timers[0].fn();
  assert.equal(sent.length, 1);
});
await t('reporter: requests never overlap, and a tick without a pose or session sends nothing', async () => {
  let release;
  const { reporter, sent, timers } = reporterHarness({ replies: [{ status: 200, json: { status: 'OBSERVED', revision: 1 }, wait: new Promise((r) => { release = r; }) }] });
  reporter.start();
  assert.equal(await timers[0].fn(), 'skipped', 'previous request still in flight');
  release(); await settle(); await settle();
  assert.equal(sent.length, 1);
  for (const getPose of [() => null, () => ({ x: Number.NaN, y: 0, z: 0 })]) {
    const h = reporterHarness({ getPose });
    h.reporter.start(); await settle();
    assert.equal(h.sent.length, 0);
  }
  const none = reporterHarness({ sessionId: '' });
  none.reporter.start(); await settle();
  assert.equal(none.sent.length, 0);
});
await t('reporter: an ineligible state is still reported, as OTHER / INELIGIBLE', async () => {
  const { reporter, sent } = reporterHarness({ getState: () => ({ indoor: false, mounted: true, seated: false, combat: false, airborne: false, disconnected: false }) });
  reporter.start(); await settle();
  assert.deepEqual([sent[0].body.space, sent[0].body.mode], ['OTHER', 'INELIGIBLE']);
});

// =====================================================================
// router and credentials
// =====================================================================
for (const path of ['/', '/api', '/api/nope', '/api/world-fishing/', '/api/ranked-run-start/x', '/API/world-fishing', '/functions/v1/ranked-run-start',
  '/api/hub-event', '/api/world-time']) {
  await t(`router: ${path} is 404 and touches nothing`, async () => {
    stubDb();
    const res = await call(path, { method: 'GET' });
    assert.equal(res.status, 404);
    assert.equal(res.text, 'Not found');
    assert.equal(calls.length, 0);
  });
}
await t('no client credential or account field is ever forwarded to the database', async () => {
  const secrets = { authorization: 'Bearer user-jwt-user-jwt-user-jwt', cookie: 'sb-access-token=secret-cookie' };
  const forged = '9f8e7d6c-5b4a-4c3d-9e2f-1a0b9c8d7e6f';
  stubDb(sessionFound, bookOk, fishOk(), ...startRoutes().slice(1), ...finishRoutes().slice(1), [DUCK_RPC, rows('result', 'jsonb', [duckData])]);
  await call(BOOK, { method: 'GET', headers: { ...HOST, ...secrets } });
  await call(FISH, { headers: { ...FH, ...secrets }, body: startBody() });
  await call(START, { headers: secrets, body: { clientVersion: 'c', email: 'duck@inha.edu', userId: forged } });
  await call(FINISH, { headers: secrets, body: run21({ email: 'duck@inha.edu', userId: forged }) });
  await call(DUCK, { headers: secrets, body: { duckId: 'inkyung_duck_white_01', email: 'duck@inha.edu', userId: forged } });
  assert.ok(calls.length >= 12);
  assert.deepEqual(leaks(['user-jwt', 'secret-cookie', 'duck@inha.edu', forged]), []);
});

// =====================================================================
// Optional: end to end against a real Postgres with schema.sql applied.
// The driver's HTTP transport is bridged to node-postgres, so the Worker's exact
// SQL text and parameters run against the real functions and tables, as the
// least-privilege Worker role.
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
  const { rows: [{ member }] } = await admin.query(`select pg_has_role(current_user, 'inha_world_tier3_app', 'SET') as member`);
  if (!member) await admin.query('grant inha_world_tier3_app to current_user');
  await app.query('set role inha_world_tier3_app');
  integration = 'ran as role inha_world_tier3_app';
  neonConfig.fetchFunction = async (url, init) => {
    const { query, params } = JSON.parse(init.body);
    try {
      const r = await app.query({ text: query, values: params, rowMode: 'array', types: raw });
      return new Response(JSON.stringify({ fields: r.fields.map((f) => ({ name: f.name, dataTypeID: f.dataTypeID })),
        rows: r.rows, command: r.command, rowCount: r.rowCount, rowAsArray: true }), { status: 200 });
    } catch (error) {
      return new Response(JSON.stringify({ message: error.message, code: error.code }), { status: 400 });
    }
  };
  // Everything this pass writes happens inside one transaction on the admin
  // connection's fixtures plus rows keyed by these session ids; all of it is
  // removed at the end. The fishing runtime row is restored.
  const guest = randomUUID(), player = randomUUID(), rival = randomUUID(), bannedId = randomUUID();
  const all = [guest, player, rival, bannedId];
  const nick = (id) => `t${id.replace(/-/g, '').slice(0, 10)}`;
  await admin.query(`insert into public.sessions (id, nickname) select x, 'parity' from unnest($1::text[]) x`, [all]);
  await admin.query(`insert into public.profiles (user_id, nickname, is_banned) values ($1, $2, false), ($3, $4, false), ($5, $6, true)`,
    [player, nick(player), rival, nick(rival), bannedId, nick(bannedId)]);
  const { rows: [runtime] } = await admin.query('select enabled, policy, minimum_start_interval_ms, presence_required from private.world_fishing_runtime');
  await admin.query(`update private.world_fishing_runtime set enabled = true, presence_required = false, minimum_start_interval_ms = 1,
    policy = '{"policyVersion":"fishing.parity.v1","minWaitMs":1,"maxWaitMs":1,"responseWindowMs":20000,"attemptTtlMs":30000,"lifeXp":20}'`);
  const as = (session) => ({ session });

  try {
    await t('db: guest-open — a session without a profile row reads its book, fishes and observes ducks; a ranked run still needs a profile', async () => {
      const bookRes = await book(as(guest));
      assert.equal(bookRes.status, 200);
      assert.equal(bookRes.json.discoveredCount, 0);
      const read = await fish({ op: 'read' }, as(guest));
      assert.equal(read.status, 200);
      assert.equal(read.json.attempt, null);
      const duck = await call(DUCK, { body: { duckId: 'inkyung_duck_white_01' }, ...as(guest) });
      assert.deepEqual([duck.status, duck.json.status], [200, 'SUCCESS']);
      assert.deepEqual((await call(START, { body: {}, ...as(guest) })).json, { error: 'PROFILE_REQUIRED' }, 'ranked keeps PROFILE_REQUIRED');
      assert.equal((await call(START, { body: { runType: 'qa' }, ...as(guest) })).status, 200, 'QA runs pass without a profile');
    });
    await t('db: an id that is not a session is 401 everywhere', async () => {
      const ghost = as(randomUUID());
      assert.equal((await book(ghost)).status, 401);
      assert.equal((await fish({ op: 'read' }, ghost)).status, 401);
      assert.equal((await call(START, { body: {}, ...ghost })).status, 401);
      assert.equal((await call(FINISH, { body: run21(), ...ghost })).status, 401);
      assert.equal((await call(DUCK, { body: { duckId: 'inkyung_duck_white_01' }, ...ghost })).status, 401);
    });
    await t('db: the ban flag no longer gates the guest-open paths; ranked start still refuses a banned profile', async () => {
      assert.equal((await book(as(bannedId))).status, 200);
      assert.equal((await fish({ op: 'read' }, as(bannedId))).status, 200);
      assert.equal((await call(DUCK, { body: { duckId: 'inkyung_duck_white_02' }, ...as(bannedId) })).status, 200);
      assert.deepEqual((await call(START, { body: {}, ...as(bannedId) })).json, { error: 'RANKING_BLOCKED' });
      assert.equal((await call(START, { body: { runType: 'qa' }, ...as(bannedId) })).status, 403, 'QA runs are blocked for a banned profile too');
    });
    await t('db: fishing start -> HOOK -> settle -> read, and the collection book shows the carp', async () => {
      const before = await book(as(player));
      assert.equal(before.status, 200);
      assert.equal(before.json.discoveredCount, 0);
      const key = randomUUID();
      const started = await fish(startBody({ clientAttemptKey: key }), as(player));
      assert.equal(started.status, 200);
      assert.equal(started.json.status, 'STARTED');
      const attempt = started.json.attempt;
      assert.equal((await fish(startBody({ clientAttemptKey: key }), as(player))).json.status, 'ALREADY_PROCESSED');
      assert.deepEqual((await fish(startBody({ clientAttemptKey: randomUUID() }), as(player))).json, { error: 'ATTEMPT_ALREADY_ACTIVE' });
      assert.equal((await fish({ op: 'settle', attemptId: attempt.attemptId }, as(player))).status, 409);
      assert.equal((await fish(inputBody({ attemptId: attempt.attemptId, nonce: attempt.nonce }), as(rival))).status, 404, "another session's attempt");
      assert.equal((await fish(inputBody({ attemptId: attempt.attemptId, nonce: randomUUID() }), as(player))).status, 400);
      await new Promise((r) => setTimeout(r, 15));
      const hooked = await fish(inputBody({ attemptId: attempt.attemptId, nonce: attempt.nonce }), as(player));
      assert.equal(hooked.json.attempt.status, 'SUCCEEDED');
      assert.equal((await fish(inputBody({ attemptId: attempt.attemptId, nonce: attempt.nonce, action: 'CANCEL' }), as(player))).status, 409);
      assert.equal((await fish({ op: 'read' }, as(player))).json.settlement, 'PENDING');
      assert.equal((await fish({ op: 'settle', attemptId: attempt.attemptId }, as(player))).json.status, 'SETTLED');
      assert.equal((await fish({ op: 'settle', attemptId: attempt.attemptId }, as(player))).json.status, 'ALREADY_PROCESSED');
      const read = await fish({ op: 'read', attemptId: attempt.attemptId }, as(player));
      assert.deepEqual([read.json.settlement, read.json.inventory.quantity, read.json.lifeSkill.totalXp, read.json.discovery.discoveryState],
        ['SETTLED', 1, 20, 'DISCOVERED']);
      const after = await book(as(player));
      assert.equal(after.json.discoveredCount, 1);
      assert.equal(after.json.entries.find((e) => e.key === 'collection.fish.carp').discoveryCount, 1);
      assert.equal((await book(as(rival))).json.discoveredCount, 0, 'another session does not inherit it');
    });
    await t('db: ranked start -> finish stores the run and ranks it; a second finish is 409', async () => {
      const started = await call(START, { body: { clientVersion: 'parity' }, ...as(player) });
      assert.equal(started.status, 200);
      const { runId, nonce } = started.json;
      assert.match(started.json.startedAt, /^\d{4}-\d\d-\d\dT[\d:.]+\+00:00$/, 'PostgREST timestamp format is kept');
      await admin.query(`update public.ranked_sessions set started_at = now() - interval '30 seconds' where run_id = $1`, [runId]);
      assert.equal((await call(FINISH, { body: run21({ runId, nonce }), ...as(rival) })).status, 404, "another session's run");
      const done = await call(FINISH, { body: run21({ runId, nonce }), ...as(player) });
      assert.equal(done.status, 200);
      assert.deepEqual([done.json.accepted, done.json.bestScore, done.json.overallRank, done.json.runType], [true, 60, 1, 'ranked']);
      assert.deepEqual((await call(FINISH, { body: run21({ runId, nonce }), ...as(player) })).json, { error: 'RUN_ALREADY_PROCESSED', status: 'accepted' });
      const { rows: [stored] } = await admin.query('select validation_status, score, run_type from public.ranked_runs where run_id = $1', [runId]);
      assert.deepEqual(stored, { validation_status: 'accepted', score: 60, run_type: 'ranked' });
    });
    await t('db: a rejected finish closes the session and stores the rejected run', async () => {
      const { runId, nonce } = (await call(START, { body: { rulesetVersion: 'secret-2.2-r1' }, ...as(rival) })).json;
      await admin.query(`update public.ranked_sessions set started_at = now() - interval '30 seconds' where run_id = $1`, [runId]);
      const res = await call(FINISH, { body: run22({ runId, nonce, score: 63 }), ...as(rival) });
      assert.equal(res.status, 422);
      assert.deepEqual(res.json, { error: 'RUN_REJECTED', reason: 'SCORE_LEDGER_MISMATCH' });
      const { rows: [s] } = await admin.query(`select s.status, r.validation_status, r.reject_reason from public.ranked_sessions s join public.ranked_runs r using (run_id) where s.run_id = $1`, [runId]);
      assert.deepEqual(s, { status: 'rejected', validation_status: 'rejected', reject_reason: 'SCORE_LEDGER_MISMATCH' });
      assert.equal((await call(FINISH, { body: run21({ runId: 'abc' }), ...as(rival) })).status, 500, 'malformed run id');
    });
    await t('db: duck observation is idempotent per duck', async () => {
      const first = await call(DUCK, { body: { duckId: 'inkyung_duck_mallard_01' }, ...as(player) });
      assert.deepEqual([first.status, first.json.status, first.json.duckId], [200, 'SUCCESS', 'inkyung_duck_mallard_01']);
      assert.equal((await call(DUCK, { body: { duckId: 'inkyung_duck_mallard_01' }, ...as(player) })).json.status, 'ALREADY_PROCESSED');
      assert.equal((await call(DUCK, { body: { duckId: 'inkyung_duck_white_03' }, ...as(player) })).json.status, 'SUCCESS');
      const { rows: [{ n }] } = await admin.query('select count(*)::int as n from private.world_creature_observation_events where user_id = $1', [player]);
      assert.equal(n, 2);
    });
    await t('db: the Worker role cannot bypass the handlers', async () => {
      for (const statement of ['select 1 from public.ranked_runs limit 1', 'select 1 from public.inha_mail_badges limit 1',
        'select nickname from public.sessions limit 1', `update public.profiles set is_banned = false`,
        `select public.claim_inha_mail_badge('${player}', '${rival}')`, 'select 1 from private.world_player_items limit 1']) {
        await assert.rejects(app.query(statement), { code: '42501' }, statement);
      }
    });
    // ---- fishing-position feed, with the F3 gate on (presence_required = true, the default) ----
    const newGuest = async () => {
      const id = randomUUID();
      all.push(id);
      await admin.query(`insert into public.sessions (id, nickname) values ($1, 'guest')`, [id]);
      return id;
    };
    const spot = (await admin.query(`select x, z from private.world_fishing_spots where source_ref = 'fishing.inkyung.north_01'`)).rows[0];
    const at = (o = {}) => ({ revision: 1, x: Number(spot.x), y: 0, z: Number(spot.z), space: 'CAMPUS', mode: 'ON_FOOT', ...o });
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    await admin.query('update private.world_fishing_runtime set presence_required = true');

    await t('db: feed -> cast -> HOOK -> settle for a guest with no profile row, F3 gate on', async () => {
      const g = await newGuest();
      assert.equal((await fish(startBody({ clientAttemptKey: randomUUID() }), as(g))).json.error, 'FISHING_POSITION_UNAVAILABLE', 'no evidence yet');
      const fed = await position(at(), { session: g });
      assert.deepEqual([fed.status, fed.json], [200, { status: 'OBSERVED', revision: 1 }]);
      const { rows: [stored] } = await admin.query('select session_id::text, revision, space, mode, observed_at <= clock_timestamp() as past from private.world_fishing_positions where user_id = $1', [g]);
      assert.deepEqual(stored, { session_id: g, revision: '1', space: 'CAMPUS', mode: 'ON_FOOT', past: true });
      const started = await fish(startBody({ clientAttemptKey: randomUUID() }), as(g));
      assert.equal(started.json.status, 'STARTED');
      const { rows: [lease] } = await admin.query('select session_id::text from private.world_fishing_spot_leases where user_id = $1', [g]);
      assert.equal(lease.session_id, g, 'the spot lease binds the session id');
      await wait(15);
      const hooked = await fish(inputBody({ attemptId: started.json.attempt.attemptId, nonce: started.json.attempt.nonce }), as(g));
      assert.equal(hooked.json.attempt.status, 'SUCCEEDED');
      assert.equal((await fish({ op: 'settle', attemptId: started.json.attempt.attemptId }, as(g))).json.status, 'SETTLED');
    });
    await t('db: a second guest cannot take a spot another guest holds', async () => {
      const a = await newGuest(), b = await newGuest();
      await position(at(), { session: a });
      await position(at(), { session: b });
      assert.equal((await fish(startBody({ clientAttemptKey: randomUUID() }), as(a))).json.status, 'STARTED');
      assert.deepEqual((await fish(startBody({ clientAttemptKey: randomUUID() }), as(b))).json, { error: 'FISHING_SPOT_OCCUPIED' });
    });
    await t('db: rate limit, resent revision (409: the Worker restamps it), older revision (STALE, not overwritten)', async () => {
      const g = await newGuest();
      assert.equal((await position(at({ revision: 5 }), { session: g })).json.status, 'OBSERVED');
      assert.equal((await position(at({ revision: 6 }), { session: g })).status, 429);
      await wait(1050);
      const resent = await position(at({ revision: 5 }), { session: g });
      assert.deepEqual([resent.status, resent.json], [409, { error: 'FISHING_POSITION_CONFLICT' }],
        'an identical body is a new observed_at, so the RPC sees a different payload');
      await wait(1050);
      const older = await position(at({ revision: 4, x: Number(spot.x) + 500 }), { session: g });
      assert.deepEqual([older.status, older.json], [200, { status: 'STALE', revision: 5 }]);
      const { rows: [kept] } = await admin.query('select revision, x from private.world_fishing_positions where user_id = $1', [g]);
      assert.deepEqual([kept.revision, Number(kept.x)], ['5', Number(spot.x)]);
    });
    await t('db: out-of-range, too-high and ineligible reports are stored but cannot cast', async () => {
      const g = await newGuest();
      const cast = async () => (await fish(startBody({ clientAttemptKey: randomUUID() }), as(g))).json;
      assert.equal((await position(at({ x: Number(spot.x) + 3.5 }), { session: g })).json.status, 'OBSERVED');
      assert.deepEqual(await cast(), { error: 'FISHING_OUT_OF_RANGE' });
      await wait(1050);
      assert.equal((await position(at({ revision: 2, y: 4.5 }), { session: g })).json.status, 'OBSERVED');
      assert.deepEqual(await cast(), { error: 'FISHING_OUT_OF_RANGE' });
      await wait(1050);
      assert.equal((await position(at({ revision: 3, space: 'OTHER', mode: 'INELIGIBLE' }), { session: g })).json.status, 'OBSERVED');
      assert.deepEqual(await cast(), { error: 'FISHING_POSITION_INELIGIBLE' });
    });
    await t('db: a report older than 5 s no longer lets a guest cast', async () => {
      const g = await newGuest();
      await position(at(), { session: g });
      await wait(5100);
      assert.deepEqual((await fish(startBody({ clientAttemptKey: randomUUID() }), as(g))).json, { error: 'FISHING_POSITION_STALE' });
    });
    await t('db: the feed cannot tell a spoofed position from a real one (documented limitation)', async () => {
      // Nothing about this guest is near the pond except its own claim, and the claim is enough.
      // (The south bank: the north one is still leased by the occupancy test above.)
      const g = await newGuest();
      const south = (await admin.query(`select x, z from private.world_fishing_spots where source_ref = 'fishing.inkyung.south_01'`)).rows[0];
      await position(at({ x: Number(south.x), z: Number(south.z) }), { session: g });
      const started = await fish(startBody({ sourceRef: 'fishing.inkyung.south_01', clientAttemptKey: randomUUID() }), as(g));
      assert.equal(started.json.status, 'STARTED');
    });
    await t('db: an id that is not a session cannot feed positions', async () => {
      assert.equal((await position(at(), { session: randomUUID() })).status, 401);
    });

    await t('db: verify-inha-mail stays 501 and writes no badge', async () => {
      assert.equal((await call(MAIL, { body: { school_access_token: 'x'.repeat(40) }, ...as(player) })).status, 501);
      const { rows: [{ n }] } = await admin.query('select count(*)::int as n from public.inha_mail_badges where user_id = any($1::uuid[])', [all]);
      assert.equal(n, 0);
    });
  } finally {
    // Leave the database as it was found. Ledgers are append-only while their
    // session exists, so the sessions go first.
    await admin.query('update private.world_fishing_runtime set enabled = $1, policy = $2, minimum_start_interval_ms = $3, presence_required = $4',
      [runtime.enabled, runtime.policy, runtime.minimum_start_interval_ms, runtime.presence_required]);
    await admin.query('delete from public.sessions where id = any($1::text[])', [all]);
    const { rows: owned } = await admin.query(`select format('%I.%I', n.nspname, c.relname) as rel from pg_class c join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'user_id' and not a.attisdropped
      where n.nspname in ('public', 'private') and c.relkind = 'r'`);
    let left = owned.map((r) => r.rel);
    for (let pass = 0; pass < 6 && left.length; pass++) {
      const next = [];
      for (const rel of left) {
        try { await admin.query(`delete from ${rel} where user_id = any($1::uuid[])`, [all]); } catch { next.push(rel); }
      }
      left = next;
    }
    if (left.length) integration += ` (could not clean: ${left.join(', ')})`;
    await app.end();
    if (!member) await admin.query('revoke inha_world_tier3_app from current_user');
    await admin.end();
  }
}

// ---- report ----
for (const failure of failures) console.log(failure);
console.log(`database integration: ${integration}`);
console.log(`${passed}/${total} passed`);
process.exit(failures.length === 0 ? 0 : 1);

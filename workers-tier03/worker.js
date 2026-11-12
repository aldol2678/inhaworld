// INHA WORLD — Tier 3 data-layer Cloudflare Worker (isolated test).
// Port of (aldol2678/inhagame HEAD 0b72d259, read-only):
//   apps/world/api/world-collection-book.js + server/collection-book-service.mjs
//   apps/world/api/world-fishing.js         + server/fishing-service.mjs
//   supabase/functions/ranked-run-start, ranked-run-finish, world-duck-observe
//   supabase/functions/verify-inha-mail     (handler NOT ported: 501, see below)
// plus POST /api/fishing-position, a browser-reported position feed with no
// original counterpart (guest-open decision 2026-11-12, see below and README).
// from Vercel / Supabase Edge Functions + Supabase to the Workers Fetch API + Neon.
// Status codes, guard order, error bodies and headers follow the originals; the
// RPCs live in schema.sql.
//
// Identity (decision A, 2026-11-12): the caller is a v0.1 guest session. The
// server-issued session id arrives in `X-Session-Id` and must exist in
// public.sessions. It replaces the Supabase access token (`Authorization: Bearer`)
// everywhere, and the originals' "anonymous accounts are refused" checks with it.
//
// DATABASE_URL comes from `wrangler secret put DATABASE_URL` only — never from a
// file, [vars], or a log line.
import { neon } from '@neondatabase/serverless';

// One HTTP query per call, each with its own upstream timeout.
function connect(env, timeoutMs) {
  return neon(env.DATABASE_URL, {
    fetchOptions: { signal: AbortSignal.timeout(timeoutMs) },
  });
}

// "The database answered with an error" (a raised exception, a failed cast) as
// opposed to "the database could not be reached" (no connection string, network
// failure, timeout, unreadable reply). The originals make the same split between
// a non-2xx PostgREST reply and a failed fetch.
const isDbAnswer = (error) => error?.name === 'NeonDbError' && !error.sourceError;

const json = (status, body, headers) => {
  const out = new Headers(headers);
  if (!out.has('Content-Type')) out.set('Content-Type', 'application/json; charset=utf-8');
  return new Response(JSON.stringify(body), { status, headers: out });
};

// ---- session verification (replaces verifyNpcAiUser / auth.getUser) ----
// crypto.randomUUID() ids: UUID-shaped TEXT. Returns the session id (lower case)
// when the row exists, null when the header is missing / malformed / unknown.
// Throws when the lookup itself fails.
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

async function verifySession(request, env) {
  const header = request.headers.get('x-session-id') ?? '';
  if (!SESSION_ID.test(header)) return null;
  const id = header.toLowerCase();
  const sql = connect(env, 5000);
  const rows = await sql`select id from public.sessions where id = ${id} limit 1`;
  return rows.length === 1 && rows[0]?.id === id ? id : null;
}

function sameHostOrigin(request) {
  const origin = request.headers.get('origin');
  if (!origin) return true;
  try {
    return new URL(origin).host === request.headers.get('host');
  } catch {
    return false;
  }
}

// =====================================================================
// world-collection-book: fixed self-only read
// =====================================================================
// Code registry mirror of src/collection/collection-discovery-contract.mjs (only
// the fields the projection reads). Registry / DB agreement is required for an
// entry to be visible at all.
const COLLECTION_ENTRY_REGISTRY = new Map([
  ['collection.fish.carp', {
    entryId: 'collection.fish.carp', category: 'FISH', title: '붕어',
    persistenceMode: 'SERVER_PERSISTED', ownerDomain: null, ownerRef: null,
    visibilityPolicy: 'SILHOUETTE', status: 'ACTIVE', definitionVersion: 1,
  }],
  ['collection.plant.campus_leaf', {
    entryId: 'collection.plant.campus_leaf', category: 'PLANT', title: '캠퍼스 낙엽',
    persistenceMode: 'SERVER_PERSISTED', ownerDomain: null, ownerRef: null,
    visibilityPolicy: 'SILHOUETTE', status: 'COMING_SOON', definitionVersion: 1,
  }],
  ['collection.artifact.campus_fragment_01', {
    entryId: 'collection.artifact.campus_fragment_01', category: 'ARTIFACT', title: '캠퍼스 유물 조각 I',
    persistenceMode: 'SERVER_PERSISTED', ownerDomain: null, ownerRef: null,
    visibilityPolicy: 'SECRET', status: 'COMING_SOON', definitionVersion: 1,
  }],
  ['collection.place.biryong_tower', {
    entryId: 'collection.place.biryong_tower', category: 'PLACE', title: '비룡탑',
    persistenceMode: 'DERIVED_FROM_OWNER', ownerDomain: 'BIRYONG', ownerRef: 'BR01',
    visibilityPolicy: 'PUBLIC', status: 'ACTIVE', definitionVersion: 1,
  }],
]);

const BOOK_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const isTime = (value) => typeof value === 'string' && value.length <= 64 && Number.isFinite(Date.parse(value));
const positive = (value) => Number.isSafeInteger(value) && value > 0;

class CollectionBookError extends Error {
  constructor(message = 'COLLECTION_BOOK_UNAVAILABLE', status = 503) {
    super(message);
    this.status = status;
  }
}

// The raw RPC row stays server-side. SECRET / HIDDEN and not-yet-active entries are
// omitted even from totals; unrevealed silhouettes expose neither id nor title.
// raw.userId must equal the actor: the id the client presents is the session id.
function projectCollectionBook(raw, actor) {
  if (!raw || !BOOK_UUID.test(actor ?? '') || raw.userId?.toLowerCase() !== actor.toLowerCase() ||
      !Array.isArray(raw.entries)) {
    throw new CollectionBookError();
  }
  const entries = [];
  const seen = new Set();
  for (const row of raw.entries) {
    if (!row || typeof row.entryId !== 'string' || seen.has(row.entryId)) throw new CollectionBookError();
    seen.add(row.entryId);
    const def = COLLECTION_ENTRY_REGISTRY.get(row.entryId) ?? null;
    if (!def || def.status !== 'ACTIVE' || row.catalogStatus !== 'ACTIVE' ||
        row.category !== def.category || row.persistenceMode !== def.persistenceMode ||
        row.definitionVersion !== def.definitionVersion ||
        !['PUBLIC', 'SILHOUETTE'].includes(def.visibilityPolicy)) continue;
    if (def.persistenceMode === 'DERIVED_FROM_OWNER') {
      if (row.discoveryState !== 'OWNER_DERIVED' || row.discovered !== null || row.firstDiscoveredAt !== null ||
          row.lastDiscoveredAt !== null || row.discoveryCount !== null || row.version !== null ||
          row.ownerDomain !== def.ownerDomain || row.ownerRef !== def.ownerRef) throw new CollectionBookError();
      entries.push({ key: def.entryId, title: def.title, state: 'OWNER_DERIVED', firstDiscoveredAt: null,
        discoveryCount: null, sourceLabel: null, hint: '이 항목의 발견 여부는 해당 콘텐츠의 기록에서 확인해요' });
      continue;
    }
    if (def.persistenceMode !== 'SERVER_PERSISTED') continue;
    const found = row.discoveryState === 'DISCOVERED' && row.discovered === true;
    const unknown = row.discoveryState === 'UNKNOWN' && row.discovered === false;
    if (row.ownerDomain !== null || row.ownerRef !== null || (!found && !unknown) ||
        (found && (!isTime(row.firstDiscoveredAt) || !isTime(row.lastDiscoveredAt) ||
          Date.parse(row.lastDiscoveredAt) < Date.parse(row.firstDiscoveredAt) ||
          !positive(row.discoveryCount) || !positive(row.version))) ||
        (unknown && (row.firstDiscoveredAt !== null || row.lastDiscoveredAt !== null ||
          row.discoveryCount !== 0 || row.version !== 0))) {
      throw new CollectionBookError();
    }
    const redacted = !found && def.visibilityPolicy === 'SILHOUETTE';
    entries.push({ key: redacted ? `unrevealed:${entries.length}` : def.entryId,
      title: redacted ? '아직 발견하지 못한 기록' : def.title,
      state: found ? 'DISCOVERED' : 'UNKNOWN', firstDiscoveredAt: found ? row.firstDiscoveredAt : null,
      discoveryCount: found ? row.discoveryCount : 0,
      sourceLabel: null, hint: found ? null : '월드에서 기록을 발견하면 자세한 내용이 표시돼요' });
  }
  return { version: 1, entries, discoveredCount: entries.filter((e) => e.state === 'DISCOVERED').length,
    trackableCount: entries.filter((e) => e.state !== 'OWNER_DERIVED').length };
}

async function collectionBook(request, env) {
  let actor;
  try {
    actor = await verifySession(request, env);
  } catch {
    throw new CollectionBookError();
  }
  if (typeof actor !== 'string' || !BOOK_UUID.test(actor)) throw new CollectionBookError('AUTH_REQUIRED', 401);
  let raw;
  try {
    const sql = connect(env, 10000);
    const rows = await sql`select public.world_collection_list_v1(${actor}::uuid) as result`;
    raw = rows[0]?.result;
  } catch (error) {
    const unavailable = isDbAnswer(error) && error.message === 'ACCOUNT_UNAVAILABLE';
    throw new CollectionBookError(unavailable ? 'ACCOUNT_UNAVAILABLE' : 'COLLECTION_BOOK_UNAVAILABLE',
      unavailable ? 403 : 503);
  }
  return projectCollectionBook(raw, actor);
}

async function handleCollectionBook(request, env) {
  // `Vary` names the credential header; it was `Authorization` in the original.
  const headers = new Headers({ 'Cache-Control': 'private, no-store', Vary: 'X-Session-Id' });
  if (request.method !== 'GET') {
    headers.set('Allow', 'GET');
    return new Response(null, { status: 405, headers });
  }
  if (request.url.includes('?') || (await request.text()) !== '') {
    return new Response(null, { status: 400, headers });
  }
  if (!sameHostOrigin(request)) return new Response(null, { status: 403, headers });
  try {
    return json(200, await collectionBook(request, env), headers);
  } catch (error) {
    const known = error instanceof CollectionBookError;
    return json(known ? error.status : 503,
      { error: known ? error.message : 'COLLECTION_BOOK_UNAVAILABLE' }, headers);
  }
}

// =====================================================================
// world-fishing: start / input / settle / read
// =====================================================================
const ATTEMPT_KEY = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const FISHING_ACTIVITY_ID = 'activity.fishing.inkyung';
const FISHING_SOURCES = ['fishing.inkyung.north_01', 'fishing.inkyung.south_01'];
const FISHING_ERRORS = new Map([
  ...['FISHING_POSITION_UNAVAILABLE', 'FISHING_POSITION_STALE', 'FISHING_POSITION_INELIGIBLE',
    'FISHING_OUT_OF_RANGE', 'FISHING_SPOT_OCCUPIED', 'FISHING_LEASE_LOST', 'FISHING_SESSION_CHANGED']
    .map((code) => [code, 409]),
  ['ACCOUNT_UNAVAILABLE', 403], ['FISHING_UNAVAILABLE', 409], ['FISHING_RATE_LIMITED', 429],
  ['ATTEMPT_NOT_FOUND', 404], ['ATTEMPT_ALREADY_ACTIVE', 409], ['IDEMPOTENCY_CONFLICT', 409],
  ['TERMINAL_COMMAND_CONFLICT', 409], ['ACTIVITY_OUTCOME_CONFLICT', 409],
  ['FISHING_NOT_SUCCEEDED', 409], ['FISHING_IDENTITY_MISMATCH', 400],
  ['OUTPUT_UNAVAILABLE', 409], ['MAX_STACK_EXCEEDED', 409],
  ['COLLECTION_ENTRY_INACTIVE', 409], ['LIFE_SKILL_INACTIVE', 409], ['SETTLEMENT_PLAN_CONFLICT', 409],
]);

class FishingError extends Error {
  constructor(code, status) {
    super(code);
    this.status = status;
  }
}

function exactFields(raw, fields, label) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new TypeError(`${label} must be an object`);
  for (const key of Object.keys(raw)) {
    if (!fields.includes(key)) throw new TypeError(`Unrecognized ${label} field: ${key}`);
  }
}
function fishingUuid(value, label) {
  if (typeof value !== 'string' || !ATTEMPT_KEY.test(value)) throw new TypeError(`Invalid ${label}`);
  return value.toLowerCase();
}
function fishingSource(value) {
  if (!FISHING_SOURCES.includes(value)) throw new TypeError('Unknown fishing source');
  return value;
}
function validateFishingStartRequest(raw) {
  exactFields(raw, ['activityId', 'sourceRef', 'clientAttemptKey'], 'fishing start');
  if (raw.activityId !== FISHING_ACTIVITY_ID) throw new TypeError('Invalid fishing activity');
  return { sourceRef: fishingSource(raw.sourceRef), clientAttemptKey: fishingUuid(raw.clientAttemptKey, 'clientAttemptKey') };
}
function validateFishingInputRequest(raw) {
  exactFields(raw, ['attemptId', 'sourceRef', 'nonce', 'action'], 'fishing input');
  if (!['HOOK', 'CANCEL'].includes(raw.action)) throw new TypeError('Invalid fishing action');
  return { attemptId: fishingUuid(raw.attemptId, 'attemptId'), sourceRef: fishingSource(raw.sourceRef),
    nonce: fishingUuid(raw.nonce, 'nonce'), action: raw.action };
}
function fishingAttemptIdentity(body, optional = false) {
  if (Object.keys(body).some((key) => key !== 'attemptId') ||
      (!optional || body.attemptId !== undefined) &&
      (typeof body.attemptId !== 'string' || !ATTEMPT_KEY.test(body.attemptId))) {
    throw new TypeError('Invalid fishing attempt');
  }
  return body.attemptId?.toLowerCase() ?? null;
}

// The caller cannot supply actor, clock, policy, roll, quantity, discovery or XP.
// The request is validated BEFORE the session, as in the original.
async function fishing(request, env, body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new FishingError('INVALID_REQUEST', 400);
  const { op, ...input } = body;
  let run;
  try {
    if (op === 'start') {
      const r = validateFishingStartRequest(input);
      run = (sql, actor) => sql`select public.world_fishing_start_v1(${actor}::uuid, ${r.sourceRef}::text, ${r.clientAttemptKey}::uuid) as result`;
    } else if (op === 'input') {
      const r = validateFishingInputRequest(input);
      run = (sql, actor) => sql`select public.world_fishing_input_v1(${actor}::uuid, ${r.attemptId}::uuid, ${r.sourceRef}::text, ${r.nonce}::uuid, ${r.action}::text) as result`;
    } else if (op === 'settle') {
      const attemptId = fishingAttemptIdentity(input, false);
      run = (sql, actor) => sql`select public.world_fishing_settle_v1(${actor}::uuid, ${attemptId}::uuid) as result`;
    } else if (op === 'read') {
      const attemptId = fishingAttemptIdentity(input, true);
      run = (sql, actor) => sql`select public.world_fishing_read_v1(${actor}::uuid, ${attemptId}::uuid) as result`;
    } else throw new TypeError('Unknown operation');
  } catch {
    throw new FishingError('INVALID_REQUEST', 400);
  }
  let actor;
  try {
    actor = await verifySession(request, env);
  } catch {
    throw new FishingError('AUTH_UNAVAILABLE', 503);
  }
  if (typeof actor !== 'string' || !ATTEMPT_KEY.test(actor)) throw new FishingError('AUTH_REQUIRED', 401);
  // Never retried automatically: these are mutations.
  try {
    const rows = await run(connect(env, 10000), actor);
    return rows[0].result;
  } catch (error) {
    if (isDbAnswer(error) && FISHING_ERRORS.has(error.message)) {
      throw new FishingError(error.message, FISHING_ERRORS.get(error.message));
    }
    throw new FishingError('FISHING_UNAVAILABLE', 503);
  }
}

async function handleFishing(request, env) {
  const headers = new Headers({ 'Cache-Control': 'no-store' });
  if (env.WORLD_FISHING_API_ENABLED !== '1') return new Response(null, { status: 404, headers });
  if (request.method !== 'POST') {
    headers.set('Allow', 'POST');
    return new Response(null, { status: 405, headers });
  }
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') {
    return new Response(null, { status: 415, headers });
  }
  if (!sameHostOrigin(request)) return new Response(null, { status: 403, headers });
  // Vercel hands the original an already-parsed object for application/json, so its
  // 8192-byte limit applies to the re-serialised value; the raw text is only measured
  // when it is not valid JSON (413 before 400).
  const bytes = (text) => new TextEncoder().encode(text).length;
  const raw = await request.text();
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    if (bytes(raw) > 8192) return new Response(null, { status: 413, headers });
    return json(400, { error: 'INVALID_REQUEST' }, headers);
  }
  if (bytes(JSON.stringify(body) ?? '') > 8192) return new Response(null, { status: 413, headers });
  try {
    return json(200, await fishing(request, env, body), headers);
  } catch (error) {
    const known = error instanceof FishingError;
    return json(known ? error.status : 503, { error: known ? error.message : 'FISHING_UNAVAILABLE' }, headers);
  }
}

// =====================================================================
// Edge Function ports: shared CORS (x-session-id added to the allowed headers)
// =====================================================================
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-session-id',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const CORS_JSON = { ...CORS, 'Content-Type': 'application/json' };

// The originals treat every failure to resolve the caller — including an
// unreachable auth backend — as "no user" (supabase-js returns it as an error
// instead of throwing), so a failed session lookup is also "no session" here.
async function sessionOrNull(request, env) {
  try {
    return await verifySession(request, env);
  } catch {
    return null;
  }
}

// ---- ranked-run-start ----
const DEFAULT_RULESET_VERSION = 'secret-2.1-r1';
const NEXT_RULESET_VERSION = 'secret-2.2-r1';

async function handleRankedRunStart(request, env) {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'POST') return new Response('Method Not Allowed', { status: 405, headers: CORS });
  try {
    const userId = await sessionOrNull(request, env);
    if (!userId) return json(401, { error: 'UNAUTHENTICATED' }, CORS_JSON);

    // Opportunistic lifecycle cleanup: best effort, never blocks a start.
    try {
      await connect(env, 10000)`select public.expire_ranked_sessions_v1() as expired`;
    } catch { /* ignored, as in the original */ }

    const body = await request.json().catch(() => ({}));
    const clientVersion = String(body?.clientVersion ?? '').slice(0, 40);
    const requestedRuleset = String(body?.rulesetVersion ?? '');
    const rulesetVersion = requestedRuleset === NEXT_RULESET_VERSION ? NEXT_RULESET_VERSION : DEFAULT_RULESET_VERSION;
    const runType = body?.runType === 'qa' ? 'qa' : 'ranked';

    // The original ignores a failed profile read (the profile is then "missing").
    // Tier 3 has no profile-creation flow: a session without a profiles row gets
    // PROFILE_REQUIRED for a ranked run, exactly like an account without one did.
    let profile = null;
    try {
      const rows = await connect(env, 10000)`select user_id, is_banned from public.profiles where user_id = ${userId}::uuid limit 1`;
      profile = rows[0] ?? null;
    } catch { /* ignored, as in the original */ }

    if (runType === 'ranked' && !profile) return json(409, { error: 'PROFILE_REQUIRED' }, CORS_JSON);
    if (profile?.is_banned) return json(403, { error: 'RANKING_BLOCKED' }, CORS_JSON);

    const tenMinutesAgo = new Date(Date.now() - 10 * 60 * 1000).toISOString();
    let count = null;
    try {
      const rows = await connect(env, 10000)`select count(*)::int as count from public.ranked_sessions where user_id = ${userId}::uuid and started_at >= ${tenMinutesAgo}::timestamptz`;
      count = rows[0]?.count ?? null;
    } catch { /* ignored, as in the original */ }
    if ((count ?? 0) >= 30) return json(429, { error: 'RATE_LIMITED' }, CORS_JSON);

    // row_to_json keeps PostgREST's wire format for uuid / timestamptz values.
    const rows = await connect(env, 10000)`with s as (
      insert into public.ranked_sessions (user_id, stage_key, client_version, run_type, ruleset_version)
      values (${userId}::uuid, 'secret', ${clientVersion || null}::text, ${runType}::text, ${rulesetVersion}::text)
      returning run_id, nonce, started_at, expires_at, run_type, ruleset_version
    ) select row_to_json(s) as session from s`;
    const session = rows[0].session;

    return json(200, {
      runId: session.run_id,
      nonce: session.nonce,
      startedAt: session.started_at,
      expiresAt: session.expires_at,
      runType: session.run_type,
      rulesetVersion: session.ruleset_version,
    }, { ...CORS_JSON, 'Cache-Control': 'no-store' });
  } catch (e) {
    return json(500, { error: 'START_FAILED', detail: String(e?.message ?? e) }, CORS_JSON);
  }
}

// ---- ranked-run-finish ----
const int = (v, fallback = -1) => (Number.isFinite(Number(v)) ? Math.trunc(Number(v)) : fallback);

async function handleRankedRunFinish(request, env) {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'POST') return new Response('Method Not Allowed', { status: 405, headers: CORS });
  const db = () => connect(env, 10000);
  try {
    const userId = await sessionOrNull(request, env);
    if (!userId) return json(401, { error: 'UNAUTHENTICATED' }, CORS_JSON);

    const body = await request.json();

    const runId = String(body?.runId ?? '');
    const nonce = String(body?.nonce ?? '');
    const score = int(body?.score);
    const maxCombo = int(body?.maxCombo);
    const annyongiHits = int(body?.annyongiHits);
    const indeokiHits = int(body?.indeokiHits);
    const goldHits = int(body?.goldHits);
    const totalHits = int(body?.totalHits);
    const durationMs = int(body?.durationMs);
    const clientVersion = String(body?.clientVersion ?? '').slice(0, 40);

    const hasHitBreakdown = body?.normalHits !== undefined && body?.speedyHits !== undefined;
    const normalHits = int(body?.normalHits, 0);
    const speedyHits = int(body?.speedyHits, 0);
    const dragonCalls = int(body?.dragonCalls, body?.dragonBursts !== undefined ? int(body?.dragonBursts, 0) : 0);
    const moonBonusHits = int(body?.moonBonusHits, 0);
    const hasFlightHits = body?.flightHits !== undefined;
    const flightHits = int(body?.flightHits, 0);
    const completedCalls = int(body?.completedCalls,
      body?.completedCalls === undefined ? Math.min(dragonCalls, flightHits > 0 ? 1 : 0) : 0);

    const comboBonus = int(body?.comboBonus, -1);
    const flightBasePoints = int(body?.flightBasePoints, -1);
    const tier1Hits = int(body?.tier1Hits, -1);
    const tier2Hits = int(body?.tier2Hits, -1);
    const tier1GroundAward = int(body?.tier1GroundAward, -1);
    const tier2GroundAward = int(body?.tier2GroundAward, -1);
    const ascensionBonus = int(body?.ascensionBonus, -1);

    const inputCount = int(body?.inputCount, 0);
    const reactionSampleCount = int(body?.reactionSampleCount, 0);
    const ultraFastReactionCount = int(body?.ultraFastReactionCount, 0);

    // A malformed runId fails the uuid cast -> thrown -> 500, as PostgREST's did.
    const sessionRows = await db()`select row_to_json(s) as session from (
      select run_id, user_id, nonce, started_at, expires_at, status, run_type, ruleset_version
      from public.ranked_sessions where run_id = ${runId}::uuid and user_id = ${userId}::uuid limit 1
    ) s`;
    const session = sessionRows[0]?.session ?? null;

    if (!session) return json(404, { error: 'RUN_NOT_FOUND' }, CORS_JSON);
    if (session.status !== 'started') {
      return json(409, { error: 'RUN_ALREADY_PROCESSED', status: session.status }, CORS_JSON);
    }

    const now = Date.now();
    const started = Date.parse(session.started_at);
    const expires = Date.parse(session.expires_at);
    const actualElapsed = now - started;

    if (now > expires || actualElapsed > 6 * 60 * 1000) {
      try {
        await db()`update public.ranked_sessions
          set status = 'expired', expired_at = ${session.expires_at}::timestamptz, finished_at = ${session.expires_at}::timestamptz
          where run_id = ${runId}::uuid and user_id = ${userId}::uuid and status = 'started'`;
      } catch { /* result ignored, as in the original */ }
      return json(410, { error: 'RUN_EXPIRED' }, CORS_JSON);
    }

    // Payload has arrived. Validation resolves submitted -> accepted / rejected.
    const submittedAt = new Date().toISOString();
    const submitted = await db()`update public.ranked_sessions
      set status = 'submitted', submitted_at = ${submittedAt}::timestamptz
      where run_id = ${runId}::uuid and user_id = ${userId}::uuid and status = 'started'
      returning run_id`;
    if (!submitted[0]) return json(409, { error: 'RUN_ALREADY_PROCESSED' }, CORS_JSON);

    const reject = async (reason, status = 422) => {
      try {
        await db()`update public.ranked_sessions set status = 'rejected', finished_at = ${new Date().toISOString()}::timestamptz
          where run_id = ${runId}::uuid and user_id = ${userId}::uuid and status = 'submitted'`;
      } catch { /* result ignored, as in the original */ }
      try {
        await db()`insert into public.ranked_runs (
            run_id, user_id, stage_key, score, max_combo, annyongi_hits, indeoki_hits, gold_hits,
            normal_hits, speedy_hits, total_hits, dragon_bursts, dragon_calls, completed_calls,
            moon_bonus_hits, flight_hits, duration_ms, client_version, validation_status, reject_reason,
            run_type, ruleset_version, input_count, reaction_sample_count, ultra_fast_reaction_count,
            suspicious_flag, suspicion_reasons, combo_bonus, flight_base_points, tier1_hits, tier2_hits,
            tier1_ground_award, tier2_ground_award, ascension_bonus
          ) values (
            ${runId}::uuid, ${userId}::uuid, 'secret', ${Math.max(0, score)}::int, ${Math.max(0, maxCombo)}::int,
            ${Math.max(0, annyongiHits)}::int, ${Math.max(0, indeokiHits)}::int, ${Math.max(0, goldHits)}::int,
            ${Math.max(0, normalHits)}::int, ${Math.max(0, speedyHits)}::int, ${Math.max(0, totalHits)}::int, 0,
            ${Math.max(0, Math.min(2, dragonCalls))}::int, ${Math.max(0, Math.min(2, completedCalls))}::int,
            ${Math.max(0, moonBonusHits)}::int, ${Math.max(0, flightHits)}::int, ${Math.max(0, durationMs)}::int,
            ${clientVersion || null}::text, 'rejected', ${reason}::text,
            ${session.run_type}::text, ${session.ruleset_version}::text,
            ${Math.max(0, inputCount)}::int, ${Math.max(0, reactionSampleCount)}::int,
            ${Math.max(0, Math.min(reactionSampleCount, ultraFastReactionCount))}::int,
            false, '{}'::text[], ${Math.max(0, comboBonus)}::int, ${Math.max(0, flightBasePoints)}::int,
            ${Math.max(0, tier1Hits)}::int, ${Math.max(0, tier2Hits)}::int,
            ${Math.max(0, tier1GroundAward)}::int, ${Math.max(0, tier2GroundAward)}::int, ${Math.max(0, ascensionBonus)}::int
          )`;
      } catch { /* result ignored, as in the original */ }
      return json(status, { error: 'RUN_REJECTED', reason }, CORS_JSON);
    };

    if (nonce !== session.nonce) return await reject('NONCE_MISMATCH', 403);
    if (body?.runType !== undefined && String(body.runType) !== session.run_type) return await reject('RUN_TYPE_MISMATCH');
    if (body?.rulesetVersion !== undefined && String(body.rulesetVersion) !== session.ruleset_version) return await reject('RULESET_MISMATCH');

    const coreNumbers = [score, maxCombo, annyongiHits, indeokiHits, goldHits, totalHits, durationMs];
    const detailedNumbers = [normalHits, speedyHits, dragonCalls, completedCalls, moonBonusHits, flightHits,
      inputCount, reactionSampleCount, ultraFastReactionCount];
    if (coreNumbers.some((v) => v < 0) || detailedNumbers.some((v) => v < 0)) return await reject('INVALID_NUMERIC');

    if (durationMs < 7000 || durationMs > 65000) return await reject('DURATION_OUT_OF_RANGE');
    if (Math.abs(actualElapsed - durationMs) > 12000) return await reject('CLOCK_MISMATCH');
    if (totalHits > 180) return await reject('TOO_MANY_HITS');
    if (dragonCalls > 2) return await reject('DRAGON_CALLS_INVALID');
    if (completedCalls > dragonCalls) return await reject('COMPLETED_CALLS_INVALID');
    if (ultraFastReactionCount > reactionSampleCount) return await reject('TELEMETRY_INVALID');

    let goodHits = totalHits - annyongiHits;
    if (hasHitBreakdown) {
      goodHits = normalHits + speedyHits + goldHits + indeokiHits;
      if (totalHits !== goodHits + annyongiHits) return await reject('HIT_COUNTS_INVALID');
    } else {
      if (annyongiHits > totalHits || indeokiHits > goodHits || goldHits > goodHits) return await reject('HIT_COUNTS_INVALID');
    }

    if (maxCombo > goodHits) return await reject('COMBO_IMPOSSIBLE');
    if (moonBonusHits > goodHits || flightHits > goodHits || moonBonusHits + flightHits > goodHits) return await reject('PHASE_HITS_INVALID');
    if (dragonCalls === 0 && (moonBonusHits > 0 || flightHits > 0)) return await reject('PHASE_WITHOUT_CALL');

    if (session.ruleset_version === 'secret-2.2-r1') {
      const ledger = [comboBonus, flightBasePoints, tier1Hits, tier2Hits, tier1GroundAward, tier2GroundAward, ascensionBonus];
      if (!hasHitBreakdown || !hasFlightHits || ledger.some((v) => v < 0)) return await reject('LEDGER_REQUIRED');

      const basePoints = normalHits + speedyHits * 2 + goldHits * 3 + indeokiHits * 5;
      const groundHits = goodHits - moonBonusHits - flightHits;
      if (groundHits < 0) return await reject('GROUND_HITS_INVALID');

      if (flightHits === 0 && flightBasePoints !== 0) return await reject('FLIGHT_LEDGER_INVALID');
      if (flightHits > 0 && (flightBasePoints < flightHits || flightBasePoints > flightHits * 5)) return await reject('FLIGHT_LEDGER_INVALID');

      const rawBeforeCombo = basePoints + moonBonusHits * 2 + flightBasePoints;
      if (comboBonus > rawBeforeCombo) return await reject('COMBO_LEDGER_INVALID');

      if (tier1Hits + tier2Hits > groundHits) return await reject('ASCENSION_HITS_INVALID');
      if (completedCalls < 1 && (tier1Hits || tier1GroundAward)) return await reject('TIER1_BEFORE_ASCENSION');
      if (completedCalls < 2 && (tier2Hits || tier2GroundAward)) return await reject('TIER2_BEFORE_ASCENSION');

      if ((tier1Hits === 0 && tier1GroundAward !== 0) || (tier1Hits > 0 && (tier1GroundAward < tier1Hits || tier1GroundAward > tier1Hits * 10))) {
        return await reject('TIER1_LEDGER_INVALID');
      }
      if ((tier2Hits === 0 && tier2GroundAward !== 0) || (tier2Hits > 0 && (tier2GroundAward < tier2Hits || tier2GroundAward > tier2Hits * 10))) {
        return await reject('TIER2_LEDGER_INVALID');
      }
      if (tier1GroundAward + tier2GroundAward > basePoints + comboBonus) return await reject('ASCENSION_AWARD_INVALID');

      const expectedAscensionBonus = Math.floor(tier1GroundAward * 0.2) + Math.floor(tier2GroundAward * 0.5);
      if (ascensionBonus !== expectedAscensionBonus) return await reject('ASCENSION_BONUS_INVALID');

      const expectedScore = rawBeforeCombo + comboBonus + ascensionBonus;
      if (score !== expectedScore) return await reject('SCORE_LEDGER_MISMATCH');
      if (score > 4000) return await reject('SCORE_ABOVE_CAP');
    } else {
      if (hasHitBreakdown && hasFlightHits) {
        const basePoints = normalHits + speedyHits * 2 + goldHits * 3 + indeokiHits * 5;
        const minimumScore = basePoints + moonBonusHits * 2 + flightHits;
        const maximumScore = 2 * (basePoints + moonBonusHits * 2 + flightHits * 5);
        if (score < minimumScore) return await reject('SCORE_BELOW_THEORETICAL_MIN');
        if (score > maximumScore) return await reject('SCORE_ABOVE_THEORETICAL_MAX');
      } else {
        if (score > 1800) return await reject('SCORE_ABOVE_CAP');
        if (score > Math.max(0, goodHits) * 15) return await reject('SCORE_HIT_MISMATCH');
      }
    }

    const suspicionReasons = [];
    const durationSeconds = Math.max(0.001, durationMs / 1000);
    const inputRate = inputCount / durationSeconds;
    if (inputCount >= 60 && inputRate > 10) suspicionReasons.push('HIGH_INPUT_RATE');
    if (reactionSampleCount >= 8 && ultraFastReactionCount / reactionSampleCount >= 0.65) suspicionReasons.push('ULTRA_FAST_REACTION_RATIO');
    const suspiciousFlag = suspicionReasons.length > 0;

    // The recorder is chosen by the session's ruleset (2.2 -> v5, otherwise v4),
    // exactly as in the original. A failure is thrown -> 500; it is not retried
    // with the other version.
    let acceptedRunId = null;
    if (session.ruleset_version === 'secret-2.2-r1') {
      const rows = await db()`select public.record_ranked_result_v5(
        ${runId}::uuid, ${userId}::uuid, ${score}::int, ${maxCombo}::int,
        ${annyongiHits}::int, ${indeokiHits}::int, ${goldHits}::int,
        ${normalHits}::int, ${speedyHits}::int, ${totalHits}::int,
        ${dragonCalls}::int, ${completedCalls}::int, ${moonBonusHits}::int,
        ${flightHits}::int, ${durationMs}::int, ${clientVersion || null}::text,
        ${comboBonus}::int, ${flightBasePoints}::int, ${tier1Hits}::int, ${tier2Hits}::int,
        ${tier1GroundAward}::int, ${tier2GroundAward}::int, ${ascensionBonus}::int,
        ${inputCount}::int, ${reactionSampleCount}::int, ${ultraFastReactionCount}::int,
        ${suspiciousFlag}::boolean, ${suspicionReasons}::text[]) as record_id`;
      acceptedRunId = rows[0].record_id;
    } else {
      const rows = await db()`select public.record_ranked_result_v4(
        ${runId}::uuid, ${userId}::uuid, ${score}::int, ${maxCombo}::int,
        ${annyongiHits}::int, ${indeokiHits}::int, ${goldHits}::int,
        ${normalHits}::int, ${speedyHits}::int, ${totalHits}::int,
        ${dragonCalls}::int, ${completedCalls}::int, ${moonBonusHits}::int,
        ${flightHits}::int, ${durationMs}::int, ${clientVersion || null}::text,
        ${inputCount}::int, ${reactionSampleCount}::int, ${ultraFastReactionCount}::int,
        ${suspiciousFlag}::boolean, ${suspicionReasons}::text[]) as record_id`;
      acceptedRunId = rows[0].record_id;
    }

    // get_my_rank_v3 takes the session id as a parameter here (was auth.uid()).
    // A failed rank read is ignored, as in the original.
    let rank = null;
    if (session.run_type === 'ranked') {
      try {
        const rows = await db()`select row_to_json(r) as rank from public.get_my_rank_v3(${userId}::uuid) r`;
        rank = rows[0]?.rank ?? null;
      } catch { /* ignored, as in the original */ }
    }

    return json(200, {
      accepted: true,
      runId,
      recordId: acceptedRunId,
      runType: session.run_type,
      rulesetVersion: session.ruleset_version,
      rankEligible: session.run_type === 'ranked',
      shadowSuspicious: suspiciousFlag,
      suspicionReasons,
      bestScore: session.run_type === 'ranked' ? (rank?.best_score ?? score) : null,
      overallRank: session.run_type === 'ranked' ? (rank?.overall_rank ?? null) : null,
      departmentRank: session.run_type === 'ranked' ? (rank?.department_rank ?? null) : null,
      rankedGrade: session.run_type === 'ranked' ? (rank?.ranked_grade ?? null) : null,
      generalBadge: session.run_type === 'ranked' ? (rank?.general_badge ?? null) : null,
    }, { ...CORS_JSON, 'Cache-Control': 'no-store' });
  } catch (e) {
    return json(500, { error: 'FINISH_FAILED', detail: String(e?.message ?? e) }, CORS_JSON);
  }
}

// ---- world-duck-observe ----
const DUCK_HEADERS = { ...CORS_JSON, 'Cache-Control': 'no-store' };
const ALLOWED_DUCK_IDS = new Set([
  'inkyung_duck_white_01',
  'inkyung_duck_white_02',
  'inkyung_duck_white_03',
  'inkyung_duck_mallard_01',
]);

async function handleDuckObserve(request, env) {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: DUCK_HEADERS });
  if (request.method !== 'POST') return json(405, { error: 'METHOD_NOT_ALLOWED' }, DUCK_HEADERS);
  try {
    // The original also refused anonymous accounts (403 PERMANENT_ACCOUNT_REQUIRED).
    // With guest sessions that check is gone: an existing session is enough.
    const userId = await sessionOrNull(request, env);
    if (!userId) return json(401, { error: 'UNAUTHENTICATED' }, DUCK_HEADERS);

    const body = await request.json().catch(() => ({}));
    const duckId = String(body?.duckId ?? '');
    if (!ALLOWED_DUCK_IDS.has(duckId)) return json(400, { error: 'INVALID_DUCK_ID' }, DUCK_HEADERS);

    // Provenance is derived server-side. The browser never controls the user id,
    // result ref, idempotency key, creature id, observation count, or party state.
    const resultRef = `duck-observation:${userId}:${duckId}`;
    const idempotencyKey = `duck-observe:${userId}:${duckId}`;

    let data;
    try {
      const rows = await connect(env, 10000)`select public.world_inkyung_duck_observe_v1(${userId}::uuid, ${duckId}::text, ${resultRef}::text, ${idempotencyKey}::text) as result`;
      data = rows[0]?.result;
    } catch (error) {
      const code = String(error?.code ?? '');
      if (code === '22023') return json(403, { error: 'ACCOUNT_UNAVAILABLE' }, DUCK_HEADERS);
      if (code === 'P0001') return json(409, { error: 'OBSERVATION_REJECTED' }, DUCK_HEADERS);
      return json(500, { error: 'OBSERVATION_FAILED' }, DUCK_HEADERS);
    }
    return json(200, data ?? { status: 'SUCCESS', duckId }, DUCK_HEADERS);
  } catch {
    return json(500, { error: 'OBSERVATION_FAILED' }, DUCK_HEADERS);
  }
}

// ---- verify-inha-mail: NOT IMPLEMENTED ----
// 신원 검증 미이식 — 별도 결정 대기.
// The original verifies TWO Supabase Auth tokens (the primary account and the
// Inha mailbox account) before it calls claim_inha_mail_badge. A guest session
// cannot reproduce that, and how the school token is issued is not established.
// Nothing here verifies anything and nothing can succeed: every POST is 501.
// The table and claim_inha_mail_badge are in schema.sql; the Worker role cannot
// call the function.
function handleVerifyInhaMail(request) {
  if (request.method === 'OPTIONS') return new Response(null, { headers: CORS_JSON });
  if (request.method !== 'POST') return json(405, { error: 'METHOD_NOT_ALLOWED' }, CORS_JSON);
  return json(501, { error: 'NOT_IMPLEMENTED' }, CORS_JSON);
}

// =====================================================================
// fishing-position: browser-reported position feed for the F3 cast/HOOK gate
// =====================================================================
// NOT a trusted feed. The original F3 design accepts position evidence only from
// an authoritative world server and states that browser poses are not evidence;
// no such server exists. This endpoint relays what the browser says, so a client
// can claim to stand on a fishing spot. It is a deliberate, guest-friendly
// trade-off (decision 2026-11-12). What still holds is everything inside
// world_fishing_observe_position_v1 and the cast/HOOK gates: one strictly
// increasing revision per session, evidence older than 5 s is refused, bounded
// coordinates, a 3-unit radius and y between -1 and 4 at the spot, one lease per
// bank. Replays, stale and out-of-range positions are still filtered out.
//
// The fishing op list in /api/world-fishing is unchanged: the player fishing API
// still cannot carry position (the original's own test forbids it). This is a
// separate path.
const POSITION_FIELDS = ['revision', 'x', 'y', 'z', 'space', 'mode'];
const POSITION_LIMIT = 10000;
const POSITION_MAX_BODY_BYTES = 1024;
const POSITION_MIN_INTERVAL_MS = 1000;
const POSITION_STATUSES = new Set(['OBSERVED', 'ALREADY_PROCESSED', 'STALE']);

// Per-session rate limit, 1 request per second. In-memory per Worker isolate:
// best effort only. Two isolates (or colos) do not share it, so a client that
// lands on several isolates can exceed it. The RPC's own revision / freshness
// checks are what actually bound the effect of extra requests.
const lastPositionAt = new Map();
function positionRateLimited(sessionId, nowMs) {
  const last = lastPositionAt.get(sessionId);
  if (last !== undefined && nowMs - last < POSITION_MIN_INTERVAL_MS) return true;
  if (lastPositionAt.size > 10000) {
    for (const [id, at] of lastPositionAt) {
      if (nowMs - at >= POSITION_MIN_INTERVAL_MS) lastPositionAt.delete(id);
    }
  }
  lastPositionAt.set(sessionId, nowMs);
  return false;
}

const finiteCoordinate = (value) =>
  typeof value === 'number' && Number.isFinite(value) && value >= -POSITION_LIMIT && value <= POSITION_LIMIT;

function validatePositionReport(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const keys = Object.keys(body);
  // Exactly these six fields. observed_at / observedAt / sessionId and anything
  // else the client sends are refused, not ignored.
  if (keys.length !== POSITION_FIELDS.length || !POSITION_FIELDS.every((k) => keys.includes(k))) return null;
  const { revision, x, y, z, space, mode } = body;
  if (!Number.isSafeInteger(revision) || revision < 1) return null;
  if (!finiteCoordinate(x) || !finiteCoordinate(y) || !finiteCoordinate(z)) return null;
  if (space !== 'CAMPUS' && space !== 'OTHER') return null;
  if (mode !== 'ON_FOOT' && mode !== 'INELIGIBLE') return null;
  return { revision, x, y, z, space, mode };
}

async function handleFishingPosition(request, env) {
  // observed_at is the time the Worker received the request, never a client
  // value: browser clocks drift and can be set freely, and the RPC refuses
  // evidence from the future and evidence 5 s old or older against the DB clock.
  const receivedAt = new Date();
  const headers = new Headers({ ...CORS, 'Cache-Control': 'no-store' });
  const reply = (status, body) => (body === undefined
    ? new Response(null, { status, headers })
    : json(status, body, headers));
  // Positions only matter for fishing: closed with the fishing endpoint.
  if (env.WORLD_FISHING_API_ENABLED !== '1') return reply(404);
  if (request.method === 'OPTIONS') return new Response('ok', { headers });
  if (request.method !== 'POST') {
    headers.set('Allow', 'POST');
    return reply(405);
  }
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') {
    return reply(415);
  }
  if (!sameHostOrigin(request)) return reply(403);
  const raw = await request.text();
  if (new TextEncoder().encode(raw).length > POSITION_MAX_BODY_BYTES) return reply(413);
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return reply(400, { error: 'INVALID_REQUEST' });
  }
  const report = validatePositionReport(body);
  if (!report) return reply(400, { error: 'INVALID_REQUEST' });
  let actor;
  try {
    actor = await verifySession(request, env);
  } catch {
    return reply(503, { error: 'AUTH_UNAVAILABLE' });
  }
  if (typeof actor !== 'string') return reply(401, { error: 'AUTH_REQUIRED' });
  if (positionRateLimited(actor, receivedAt.getTime())) return reply(429, { error: 'RATE_LIMITED' });
  try {
    // The session id is both the account (p_user) and the presence session the
    // spot lease binds to (p_session_id).
    const rows = await connect(env, 5000)`select public.world_fishing_observe_position_v1(
      ${actor}::uuid, ${actor}::uuid, ${report.revision}::bigint,
      ${report.x}::float8, ${report.y}::float8, ${report.z}::float8,
      ${report.space}::text, ${report.mode}::text, ${receivedAt.toISOString()}::timestamptz) as result`;
    const result = rows[0]?.result;
    if (!POSITION_STATUSES.has(result?.status) || !Number.isSafeInteger(result?.revision)) {
      return reply(503, { error: 'FISHING_UNAVAILABLE' });
    }
    // OBSERVED, ALREADY_PROCESSED (same revision, same payload) and STALE (an
    // older revision; the stored position is not overwritten) are all 200.
    return reply(200, { status: result.status, revision: result.revision });
  } catch (error) {
    if (isDbAnswer(error) && error.message === 'FISHING_POSITION_INVALID') {
      return reply(400, { error: 'FISHING_POSITION_INVALID' });
    }
    if (isDbAnswer(error) && error.message === 'FISHING_POSITION_CONFLICT') {
      return reply(409, { error: 'FISHING_POSITION_CONFLICT' });
    }
    return reply(503, { error: 'FISHING_UNAVAILABLE' });
  }
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === '/api/world-collection-book') return handleCollectionBook(request, env);
    if (pathname === '/api/world-fishing') return handleFishing(request, env);
    if (pathname === '/api/ranked-run-start') return handleRankedRunStart(request, env);
    if (pathname === '/api/ranked-run-finish') return handleRankedRunFinish(request, env);
    if (pathname === '/api/world-duck-observe') return handleDuckObserve(request, env);
    if (pathname === '/api/verify-inha-mail') return handleVerifyInhaMail(request);
    if (pathname === '/api/fishing-position') return handleFishingPosition(request, env);
    return new Response('Not found', { status: 404 });
  },
};
